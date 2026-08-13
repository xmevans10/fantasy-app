-- 0015 — Versus: correctness fixes + timed duels (prompts/HANDOFF-multiplayer.md Phase 0 + 1).
--
-- Applied live to nhccgufqwndtoasdbkhc. `supabase/schema.sql` carries the same statements so the
-- file never drifts from production (CLAUDE.md's rule).
--
-- What this changes, in the handoff's own numbering:
--   0.1 the duel board is picked SERVER-side from the released archive, excluding anything
--       either side already has a `game_results` row for (kills the play-then-challenge exploit
--       and unshackles a duel from "today", which timed duels want anyway)
--   0.2 a score tie is broken by elapsed time, not by who sent the challenge
--   0.3 one open duel per series — `create_versus_challenge` is idempotent while one is pending
--   0.4 `'active'` is gone; the status domain is pending | completed | forfeited
--   0.6 a series completes at first-to-4 (the 7-played cap stays as a backstop for draws)
--   0.7 `format` on both tables, and in the pair-uniqueness index
--   1.x per-side server-set `started_at` + `time_limit_seconds`, validated on submit

-- ── 0.7 format ───────────────────────────────────────────────────────────────
alter table public.versus_series
  add column if not exists format text not null default 'keep4';
alter table public.versus_challenges
  add column if not exists format text not null default 'keep4';

-- A Grid duel and a Keep4 duel between the same pair in the same sport are different series.
-- Without `format` in this index the second one silently collides with the first.
drop index if exists public.versus_series_pair_sport;
create unique index if not exists versus_series_pair_sport_format
  on public.versus_series (user_a, user_b, sport, format) where status = 'active';

-- ── 1.x the clock ────────────────────────────────────────────────────────────
alter table public.versus_challenges
  add column if not exists time_limit_seconds int not null default 120,
  -- Written server-side by `start_versus_challenge` the first time each player opens the board.
  -- Never reset, so backgrounding the app (or force-quitting it) does not buy extra time.
  add column if not exists challenger_started_at timestamptz,
  add column if not exists opponent_started_at   timestamptz;

-- ── 0.3 one open duel per series ─────────────────────────────────────────────
-- The hard guard behind `create_versus_challenge`'s find-or-return below: N pending challenges
-- against the same person is a spam vector, and a series with two live duels has no meaning.
create unique index if not exists versus_challenges_one_open_per_series
  on public.versus_challenges (series_id) where status = 'pending';

-- ── 0.4 the status domain ────────────────────────────────────────────────────
-- `'active'` was declared in the Swift model and branched on in two places but written by no
-- RPC, ever. It is also a trap: `versus-timeout` only sweeps `status='pending'`, so a row that
-- ever landed in `'active'` would never expire. Constrain the domain so it cannot come back.
alter table public.versus_challenges drop constraint if exists versus_challenges_status_domain;
alter table public.versus_challenges add constraint versus_challenges_status_domain
  check (status in ('pending', 'completed', 'forfeited'));

-- ── 0.1 server-side board pick ───────────────────────────────────────────────
-- Old signature took `p_puzzle_id` from the client; drop it so no caller can pin a board.
drop function if exists public.create_versus_challenge(uuid, text, text);

create or replace function public.create_versus_challenge(
  p_opponent uuid,
  p_sport text,
  p_format text default 'keep4',
  p_time_limit int default 120)
returns bigint language plpgsql security definer as $$
declare
  me uuid := auth.uid();
  a uuid; b uuid;
  s_id bigint; ch_id bigint; pz text;
  limit_s int := least(greatest(coalesce(p_time_limit, 120), 30), 900);
begin
  if me is null or me = p_opponent then raise exception 'invalid opponent'; end if;
  if p_format not in ('keep4', 'grid', 'whoami') then raise exception 'unsupported format'; end if;
  a := least(me, p_opponent); b := greatest(me, p_opponent);

  select id into s_id from public.versus_series
    where user_a = a and user_b = b and sport = p_sport and format = p_format and status = 'active';
  if s_id is null then
    insert into public.versus_series (user_a, user_b, sport, format) values (a, b, p_sport, p_format)
      returning id into s_id;
  end if;

  -- Idempotent while a duel is open: re-challenging returns the live one rather than stacking
  -- a second. (The partial unique index above is the guard; this is the friendly path.)
  select id into ch_id from public.versus_challenges
    where series_id = s_id and status = 'pending' limit 1;
  if ch_id is not null then return ch_id; end if;

  -- The board comes from the *released archive* (strictly before today), never today's daily:
  -- pinning today's row is what let a player finish their daily, learn the answers, then
  -- challenge and replay with perfect knowledge. Excluding every puzzle either side has a
  -- `game_results` row for closes that for both players at once.
  select p.id into pz
  from public.puzzles p
  where p.format = p_format
    and p.sport = p_sport
    and p.active_date is not null
    and p.active_date < (now() at time zone 'utc')::date
    and not exists (
      select 1 from public.game_results g
      where g.puzzle_id = p.id and g.user_id in (me, p_opponent))
  order by random()
  limit 1;
  if pz is null then raise exception 'no unplayed puzzle available'; end if;

  insert into public.versus_challenges
      (series_id, sport, format, puzzle_id, challenger_id, opponent_id, time_limit_seconds)
    values (s_id, p_sport, p_format, pz, me, p_opponent, limit_s)
    returning id into ch_id;
  return ch_id;
end;
$$;

-- ── 1.x the clock starts when *this* player opens the board ──────────────────
-- Returns seconds remaining, not a timestamp: the client never has to trust (or correct for)
-- its own clock, and a second call after a crash resumes the same countdown instead of
-- restarting it.
create or replace function public.start_versus_challenge(p_challenge_id bigint)
returns int language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  started timestamptz;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if auth.uid() not in (c.challenger_id, c.opponent_id) then raise exception 'not a participant'; end if;
  if c.status <> 'pending' then raise exception 'duel is closed'; end if;

  if auth.uid() = c.challenger_id then
    started := c.challenger_started_at;
    if started is null then
      update public.versus_challenges set challenger_started_at = now() where id = p_challenge_id
        returning challenger_started_at into started;
    end if;
  else
    started := c.opponent_started_at;
    if started is null then
      update public.versus_challenges set opponent_started_at = now() where id = p_challenge_id
        returning opponent_started_at into started;
    end if;
  end if;

  return greatest(0, ceil(c.time_limit_seconds - extract(epoch from (now() - started))))::int;
end;
$$;

-- ── submit: first-write-wins, clamped, clock-validated ───────────────────────
create or replace function public.submit_versus_result(p_challenge_id bigint, p_score double precision)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  is_challenger boolean;
  started timestamptz;
  final_score double precision;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if auth.uid() not in (c.challenger_id, c.opponent_id) then
    raise exception 'not a participant';
  end if;

  is_challenger := auth.uid() = c.challenger_id;
  started := case when is_challenger then c.challenger_started_at else c.opponent_started_at end;

  -- `p_score` is a client claim. Every mode's `performance` is 0...1, so anything outside that
  -- is either a bug or an attempt (cf. `bump_weekly_xp`'s clamp).
  final_score := least(greatest(coalesce(p_score, 0), 0), 1);
  -- The clock is server-authoritative. A run submitted past the limit (+10s of network grace)
  -- scores 0 rather than being rejected — a blown clock still has to resolve the duel, or the
  -- cheater's reward for stalling is that nobody ever wins.
  if started is not null
     and extract(epoch from (now() - started)) > c.time_limit_seconds + 10 then
    final_score := 0;
  end if;

  -- First write wins (mirrors `submit_daily_draft_score`): a replay, even a better one, can
  -- never overwrite the score already locked in.
  if is_challenger then
    update public.versus_challenges
      set challenger_score = coalesce(c.challenger_score, final_score),
          challenger_completed_at = coalesce(c.challenger_completed_at, now())
      where id = p_challenge_id;
  else
    update public.versus_challenges
      set opponent_score = coalesce(c.opponent_score, final_score),
          opponent_completed_at = coalesce(c.opponent_completed_at, now())
      where id = p_challenge_id;
  end if;

  select * into c from public.versus_challenges where id = p_challenge_id;
  if c.challenger_score is not null and c.opponent_score is not null and c.status = 'pending' then
    perform public.resolve_versus_challenge(p_challenge_id);
  end if;
end;
$$;

-- ── 0.2 / 0.6 resolution: elapsed-time tiebreak, first-to-4 series ───────────
create or replace function public.resolve_versus_challenge(p_challenge_id bigint)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  winner uuid;
  new_status text;
  ch_secs double precision;
  op_secs double precision;
  inc_a int; inc_b int;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null or c.status <> 'pending' then return; end if;

  if c.challenger_score is not null and c.opponent_score is not null then
    new_status := 'completed';
    if c.challenger_score > c.opponent_score then
      winner := c.challenger_id;
    elsif c.opponent_score > c.challenger_score then
      winner := c.opponent_id;
    else
      -- Equal scores go to the faster run. `*_completed_at` was already being written and never
      -- read; awarding the tie to the challenger stacked a second structural edge on the first.
      ch_secs := extract(epoch from
        (c.challenger_completed_at - coalesce(c.challenger_started_at, c.created_at)));
      op_secs := extract(epoch from
        (c.opponent_completed_at - coalesce(c.opponent_started_at, c.created_at)));
      if ch_secs is not null and op_secs is not null and ch_secs <> op_secs then
        winner := case when ch_secs < op_secs then c.challenger_id else c.opponent_id end;
      else
        -- A genuine dead heat is a draw: `completed` with no winner. Distinct from `forfeited`,
        -- which stays reserved for the double no-show.
        winner := null;
      end if;
    end if;
  elsif c.challenger_score is not null then
    winner := c.challenger_id; new_status := 'completed';   -- opponent forfeited
  elsif c.opponent_score is not null then
    winner := c.opponent_id;   new_status := 'completed';   -- challenger forfeited
  else
    winner := null; new_status := 'forfeited';              -- double no-show, series unaffected
  end if;

  update public.versus_challenges
    set status = new_status, winner_id = winner
    where id = p_challenge_id;

  if winner is not null then
    update public.versus_series s
      set wins_a = s.wins_a + (case when winner = s.user_a then 1 else 0 end),
          wins_b = s.wins_b + (case when winner = s.user_b then 1 else 0 end),
          -- First to 4 takes it; a 4-0 lead no longer grinds three dead rubbers. The 7-played
          -- cap survives as a backstop, because draws advance neither counter.
          status = case
            when greatest(s.wins_a + (case when winner = s.user_a then 1 else 0 end),
                          s.wins_b + (case when winner = s.user_b then 1 else 0 end)) >= 4
              or s.wins_a + s.wins_b + 1 >= 7
            then 'completed' else s.status end
      where s.id = c.series_id;
  end if;
end;
$$;

-- ── "your opponent finished" push ────────────────────────────────────────────
-- Same pg_net pattern as `versus_challenges_notify`, on UPDATE instead of INSERT. Fires only on
-- the null -> non-null score transition, so the repeated writes `resolve_versus_challenge` makes
-- to the same row can't re-push. The Edge Function re-reads the row and decides the copy.
create or replace function public.notify_versus_result_webhook()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  finisher uuid; waiting uuid;
begin
  if new.challenger_score is not null and old.challenger_score is null then
    finisher := new.challenger_id; waiting := new.opponent_id;
  elsif new.opponent_score is not null and old.opponent_score is null then
    finisher := new.opponent_id; waiting := new.challenger_id;
  else
    return new;
  end if;

  perform net.http_post(
    url := 'https://nhccgufqwndtoasdbkhc.supabase.co/functions/v1/notify-versus-result',
    body := jsonb_build_object('record', jsonb_build_object(
      'id', new.id, 'finisher_id', finisher, 'waiting_id', waiting)),
    headers := '{"Content-Type": "application/json"}'::jsonb);
  return new;
end;
$$;
drop trigger if exists versus_challenges_result_notify on public.versus_challenges;
create trigger versus_challenges_result_notify
  after update of challenger_score, opponent_score on public.versus_challenges
  for each row execute function public.notify_versus_result_webhook();
