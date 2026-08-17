-- 0016 — the bot ladder (prompts/HANDOFF-multiplayer.md Phase 2).
--
-- Applied live to nhccgufqwndtoasdbkhc; mirrored into `supabase/schema.sql`.
--
-- The bots are **skill-limited solvers, not score generators**: the client runs the real puzzle
-- through `BotSolver` with the rung's `bot_skill` and `seed`, so the bot makes real decisions on
-- real players and its run can be replayed alongside the player in real time. That is what
-- delivers the feeling of a live opponent with zero realtime infrastructure, at N=1.
-- Consequently **nothing about a bot's play lives on the server** — `ladder_rungs` carries only
-- the inputs (which board, which bot, how good, how long, what seed), and the run is reproduced
-- identically on every device from those five columns.
--
-- Two product rules, encoded here as much as they can be:
--   * bots are labelled as bots, always — hence `bots` is its own world-readable table with a
--     name/avatar/tagline, never a row in `profiles` wearing a human's clothes;
--   * the ladder pays XP and rank only, never solo rating — so there is no rating column here,
--     and `submit_ladder_attempt` touches nothing but ladder state.

create table if not exists public.bots (
  id         text primary key,
  name       text not null,
  avatar     text not null default '🤖',
  tagline    text not null default '',
  -- The bot's natural level. A rung may override it (`ladder_rungs.bot_skill`) so the same
  -- character can appear early as a warm-up and late as a boss.
  base_skill double precision not null check (base_skill >= 0 and base_skill <= 1),
  persona    text not null default ''
);

-- One row per rung. Four independent difficulty levers so the curve doesn't go flat:
-- bot skill, the clock, the puzzle's own difficulty, and which game it is.
create table if not exists public.ladder_rungs (
  rung               int primary key,
  tier               text not null,        -- 'bronze' | 'silver' | 'gold', matching Home's tiers
  mode               text not null check (mode in ('keep4', 'whoami', 'grid')),
  sport              text not null,
  puzzle_id          text not null references public.puzzles(id),
  bot_id             text not null references public.bots(id),
  bot_skill          double precision not null check (bot_skill >= 0 and bot_skill <= 1),
  time_limit_seconds int not null check (time_limit_seconds > 0),
  -- Seeds the bot's decisions AND its pacing, so a rung plays out identically for every player:
  -- comparable, leaderboard-able, speedrun-able.
  seed               bigint not null,
  is_boss            boolean not null default false
);

create table if not exists public.ladder_progress (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  highest_rung int not null default 0,
  updated_at   timestamptz not null default now()
);

-- Every attempt, won or lost. Doubles as the per-puzzle score corpus that human ghost duels
-- will need later — that is why `score`/`bot_score` are the normalized 0...1 `performance` every
-- mode already produces, not each format's own point scale. No second migration later.
create table if not exists public.ladder_attempts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  rung       int  not null,
  score      double precision not null check (score >= 0 and score <= 1),
  bot_score  double precision not null check (bot_score >= 0 and bot_score <= 1),
  won        boolean not null,
  elapsed_ms int not null check (elapsed_ms >= 0),
  created_at timestamptz not null default now()
);
create index if not exists ladder_attempts_user_idx on public.ladder_attempts (user_id, rung);
-- The corpus lookup: "what did people score on this board".
create index if not exists ladder_attempts_rung_idx on public.ladder_attempts (rung, score desc);

alter table public.bots            enable row level security;
alter table public.ladder_rungs    enable row level security;
alter table public.ladder_progress enable row level security;
alter table public.ladder_attempts enable row level security;

drop policy if exists "bots readable"            on public.bots;
drop policy if exists "ladder_rungs readable"    on public.ladder_rungs;
drop policy if exists "ladder_progress own"      on public.ladder_progress;
drop policy if exists "ladder_attempts own read" on public.ladder_attempts;

-- Ladder content is world-readable scaffolding, like `seasons`/`cohorts`. It has to be: a
-- signed-out player can still see what the ladder is before deciding to sign in for it.
create policy "bots readable"         on public.bots         for select using (true);
create policy "ladder_rungs readable" on public.ladder_rungs for select using (true);

create policy "ladder_progress own" on public.ladder_progress
  for select using (auth.uid() = user_id);
create policy "ladder_attempts own read" on public.ladder_attempts
  for select using (auth.uid() = user_id);
-- Writes to both go through `submit_ladder_attempt` (SECURITY DEFINER) — no insert/update
-- policy, so a client can't post itself to rung 30 without playing 1 through 29.

-- Records one attempt and advances the player's high-water mark. Returns the new `highest_rung`.
--
-- The rung gate is the whole point: `highest_rung` can only ever move to `p_rung` when
-- `p_rung = highest_rung + 1` and the attempt was won, so progress is a chain, not a claim.
create or replace function public.submit_ladder_attempt(
  p_rung int, p_score double precision, p_bot_score double precision,
  p_won boolean, p_elapsed_ms int)
returns int language plpgsql security definer as $$
declare
  me uuid := auth.uid();
  current_high int;
  s  double precision := least(greatest(coalesce(p_score, 0), 0), 1);
  bs double precision := least(greatest(coalesce(p_bot_score, 0), 0), 1);
  ms int := least(greatest(coalesce(p_elapsed_ms, 0), 0), 3_600_000);
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.ladder_rungs where rung = p_rung) then
    raise exception 'no such rung';
  end if;

  insert into public.ladder_attempts (user_id, rung, score, bot_score, won, elapsed_ms)
    values (me, p_rung, s, bs, coalesce(p_won, false), ms);

  insert into public.ladder_progress (user_id, highest_rung) values (me, 0)
    on conflict (user_id) do nothing;
  select highest_rung into current_high from public.ladder_progress where user_id = me;

  if coalesce(p_won, false) and p_rung = current_high + 1 then
    update public.ladder_progress
      set highest_rung = p_rung, updated_at = now()
      where user_id = me
      returning highest_rung into current_high;
  end if;

  return current_high;
end;
$$;

-- ── Content ──────────────────────────────────────────────────────────────────
-- Six characters, each recognisable and each honestly a bot. Beating "The Analyst" is a better
-- story than beating `bot_47`, and it costs nothing to say which is which.
insert into public.bots (id, name, avatar, tagline, base_skill, persona) values
  ('rookie',    'The Rookie',    '🐣', 'Watches every game. Remembers none of them.', 0.35,
   'Guesses fast and confidently. Gets the obvious ones and nothing else.'),
  ('stathead',  'Stat Head',     '📊', 'Reads the box score. Twice.',                 0.55,
   'Solid on the numbers, lost the moment a call needs judgement.'),
  ('analyst',   'The Analyst',   '🎙️', 'Has an opinion, and a graph to back it.',     0.70,
   'Talks through every pick. Usually right, occasionally spectacularly wrong.'),
  ('scout',     'The Scout',     '🔭', 'Saw them play in college.',                   0.82,
   'Deep on the players nobody else remembers. Quick, too.'),
  ('archivist', 'The Archivist', '📼', 'Owns the tape. All of it.',                   0.91,
   'Has seen the answer before. Slow to start, impossible to shake.'),
  ('oracle',    'The Oracle',    '🔮', 'Knew the answer before the question.',        0.98,
   'The last rung. Beat it and there is nothing left to beat.')
on conflict (id) do update set
  name = excluded.name, avatar = excluded.avatar, tagline = excluded.tagline,
  base_skill = excluded.base_skill, persona = excluded.persona;

-- 30 rungs, generated rather than hand-listed so the four levers stay legible as formulas.
--
--   skill  0.35 -> 0.98 linearly, +0.04 on a boss
--   clock  the format's own duel default, tightening to 55% of it by rung 30
--   puzzle Who Am I? draws from the tier's own obscurity band (easy/medium/hard)
--   mode   all Keep4 early, Who Am I? joins at 7, The Grid at 15
--
-- The board for each rung is picked deterministically (`order by id offset ...`), not randomly:
-- a rung has to be the same board for every player, forever, or none of the comparisons mean
-- anything. Re-running this statement re-picks the same rows.
with plan as (
  select
    r as rung,
    case when r <= 10 then 'bronze' when r <= 20 then 'silver' else 'gold' end as tier,
    (r % 10 = 0) as is_boss,
    case
      when r <= 6  then 'keep4'
      when r <= 14 then (case when r % 2 = 0 then 'whoami' else 'keep4' end)
      else (case r % 3 when 0 then 'grid' when 1 then 'keep4' else 'whoami' end)
    end as mode,
    (array['nfl', 'nba', 'baseball', 'soccer', 'tennis'])[1 + ((r - 1) % 5)] as sport,
    -- Capped at 0.98, not 1.0: a flawless bot can only be beaten by a flawless *and* faster
    -- run, which turns the final boss into a coin flip on latency rather than a test of play.
    least(0.98, 0.35 + (r - 1) * (0.98 - 0.35) / 29.0 + case when r % 10 = 0 then 0.04 else 0 end)
      as bot_skill
  from generate_series(1, 30) as r
),
sized as (
  select p.*,
    case p.mode when 'keep4' then 120 when 'whoami' then 90 else 180 end as base_seconds,
    case p.tier when 'bronze' then 'easy' when 'silver' then 'medium' else 'hard' end as band
  from plan p
),
picked as (
  select s.*, (
    select q.id from public.puzzles q
    where q.format = s.mode
      and q.sport = s.sport
      and q.active_date is not null
      and q.active_date < (now() at time zone 'utc')::date
      and (s.mode <> 'whoami' or q.content->>'difficulty' = s.band)
    order by q.id
    offset (s.rung * 7) % greatest(1, (
      select count(*) from public.puzzles q2
      where q2.format = s.mode and q2.sport = s.sport
        and q2.active_date is not null
        and q2.active_date < (now() at time zone 'utc')::date
        and (s.mode <> 'whoami' or q2.content->>'difficulty' = s.band)))
    limit 1) as puzzle_id
  from sized s
)
insert into public.ladder_rungs
  (rung, tier, mode, sport, puzzle_id, bot_id, bot_skill, time_limit_seconds, seed, is_boss)
select
  p.rung, p.tier, p.mode, p.sport, p.puzzle_id,
  -- The bot whose natural level is closest to this rung's, so a character's appearances cluster
  -- rather than scattering across the whole ladder.
  (select b.id from public.bots b order by abs(b.base_skill - p.bot_skill) limit 1),
  round(p.bot_skill::numeric, 3),
  round(p.base_seconds * (1.0 - 0.45 * (p.rung - 1) / 29.0)),
  -- Stable, distinct, and derived from the rung so a re-seed reproduces it exactly.
  (p.rung::bigint * 2654435761) % 9223372036854775807,
  p.is_boss
from picked p
where p.puzzle_id is not null
on conflict (rung) do update set
  tier = excluded.tier, mode = excluded.mode, sport = excluded.sport,
  puzzle_id = excluded.puzzle_id, bot_id = excluded.bot_id, bot_skill = excluded.bot_skill,
  time_limit_seconds = excluded.time_limit_seconds, seed = excluded.seed,
  is_boss = excluded.is_boss;
