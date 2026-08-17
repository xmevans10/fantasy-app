-- A rung is a difficulty, not a board — so it needs a pool of them.
--
-- `ladder_rungs` carried a single `puzzle_id`. Lose rung 7, retry, and you got the identical
-- board with the answers already known: the score meant nothing, and `ladder_attempts` — the
-- corpus human ghost duels will later be built from — filled with rows that look like skill and
-- are actually recall. Every rung now owns an ordered pool, and a retry serves a board the
-- player has not seen.
--
-- Why a child table rather than an array column on `ladder_rungs`: each board needs its own
-- `seed` (the same bot must not replay an identical decision pattern on a new board) and its own
-- verified `board_difficulty`, because a rung's difficulty is a promise. If board A is 0.25 and
-- board B is 0.60 then the rung is a different rung depending on which one you drew, and the
-- whole calibration in `tools/ingest/ladder.py` stops describing anything. The pool is therefore
-- selected difficulty-homogeneous and re-verified per board; see that tool for the tolerances.
--
-- `ladder_rungs.puzzle_id` stays as the pool's first board (ordinal 0) so an already-shipped
-- client that never calls `next_ladder_board` keeps working unchanged.
create table if not exists public.ladder_rung_boards (
  rung             int  not null references public.ladder_rungs(rung) on delete cascade,
  ordinal          int  not null,               -- stable serve order
  puzzle_id        text not null references public.puzzles(id),
  board_difficulty double precision not null,
  seed             bigint not null,             -- per BOARD, not per rung
  primary key (rung, ordinal)
);

-- One board may not appear twice in the same rung's pool — without this a short pool could be
-- padded with duplicates and still report a healthy count.
create unique index if not exists ladder_rung_boards_unique_board
  on public.ladder_rung_boards (rung, puzzle_id);

-- "Which boards has this player seen?" is the question the whole feature turns on, and until now
-- it was unanswerable. Nullable because every attempt recorded before this migration was played
-- on the rung's single board and back-filling a guess would be inventing history.
alter table public.ladder_attempts
  add column if not exists puzzle_id text references public.puzzles(id);

-- `next_ladder_board`'s unseen-board probe. The existing `ladder_attempts_user_idx` stops at
-- (user_id, rung), which leaves the puzzle comparison as a heap fetch per candidate row.
create index if not exists ladder_attempts_seen_idx
  on public.ladder_attempts (user_id, rung, puzzle_id);

alter table public.ladder_rung_boards enable row level security;
drop policy if exists "ladder_rung_boards readable" on public.ladder_rung_boards;
-- Same reasoning as `ladder_rungs`: ladder content is world-readable scaffolding, because a
-- signed-out player can still browse what the ladder is before deciding to sign in for it.
create policy "ladder_rung_boards readable"
  on public.ladder_rung_boards for select using (true);

-- Which board this player gets next on this rung.
--
-- Lowest-ordinal board they have no `ladder_attempts` row for; if they have seen the whole pool,
-- the least recently attempted one. `SECURITY DEFINER` because the decision reads the caller's
-- own attempt history, which is own-read RLS — the function is scoped hard to `auth.uid()` and
-- returns nothing about anyone else.
--
-- A signed-out caller gets ordinal 0. The ladder is browsable signed out, so this has to answer
-- rather than fail; it just can't personalise.
--
-- Returns zero rows when the rung has no pool at all, which the client treats as "fall back to
-- `ladder_rungs.puzzle_id`" — the same path it needs for playing offline anyway.
create or replace function public.next_ladder_board(p_rung int)
returns table (puzzle_id text, seed bigint, board_difficulty double precision)
language plpgsql security definer stable as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    return query
      select b.puzzle_id, b.seed, b.board_difficulty
        from public.ladder_rung_boards b
       where b.rung = p_rung
       order by b.ordinal
       limit 1;
    return;
  end if;

  return query
    select b.puzzle_id, b.seed, b.board_difficulty
      from public.ladder_rung_boards b
     where b.rung = p_rung
       and not exists (select 1 from public.ladder_attempts a
                        where a.user_id = me and a.rung = p_rung
                          and a.puzzle_id = b.puzzle_id)
     order by b.ordinal
     limit 1;
  -- RETURN QUERY sets FOUND, so this distinguishes "pool has an unseen board" from "seen it all"
  -- without counting the pool twice.
  if found then return; end if;

  return query
    select b.puzzle_id, b.seed, b.board_difficulty
      from public.ladder_rung_boards b
      left join lateral (
        select max(a.created_at) as last_at
          from public.ladder_attempts a
         where a.user_id = me and a.rung = p_rung and a.puzzle_id = b.puzzle_id
      ) la on true
     where b.rung = p_rung
     order by la.last_at nulls first, b.ordinal
     limit 1;
end $$;

revoke all on function public.next_ladder_board(int) from public;
grant execute on function public.next_ladder_board(int) to anon, authenticated, service_role;

-- `submit_ladder_attempt` records which board was played.
--
-- Dropped and recreated rather than `create or replace`d because the new argument changes the
-- signature: leaving the old five-argument function in place would make every existing
-- five-argument call ambiguous between the two overloads and fail outright. With the sixth
-- argument defaulted, a shipped client that posts only the original five still resolves here and
-- behaves exactly as before — it just records a null board, which is honest, since a client that
-- doesn't know about pools genuinely played the rung's ordinal-0 board.
drop function if exists public.submit_ladder_attempt(int, double precision, double precision,
                                                     boolean, int);

create or replace function public.submit_ladder_attempt(
  p_rung int, p_score double precision, p_bot_score double precision,
  p_won boolean, p_elapsed_ms int, p_puzzle_id text default null)
returns int language plpgsql security definer as $$
declare
  me uuid := auth.uid();
  current_high int;
  s  double precision := least(greatest(coalesce(p_score, 0), 0), 1);
  bs double precision := least(greatest(coalesce(p_bot_score, 0), 0), 1);
  ms int := least(greatest(coalesce(p_elapsed_ms, 0), 0), 3_600_000);
  board text;
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.ladder_rungs where rung = p_rung) then
    raise exception 'no such rung';
  end if;

  -- Trust the rung's own pool over the client's claim: a board that isn't in this rung's pool
  -- (or in `ladder_rungs` itself) is recorded as null rather than poisoning the "which boards
  -- has this player seen" answer with an id they could have posted by hand.
  select p_puzzle_id into board
   where p_puzzle_id is not null
     and (exists (select 1 from public.ladder_rung_boards b
                   where b.rung = p_rung and b.puzzle_id = p_puzzle_id)
          or exists (select 1 from public.ladder_rungs r
                      where r.rung = p_rung and r.puzzle_id = p_puzzle_id));

  insert into public.ladder_attempts (user_id, rung, score, bot_score, won, elapsed_ms, puzzle_id)
    values (me, p_rung, s, bs, coalesce(p_won, false), ms, board);

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
end $$;

revoke all on function public.submit_ladder_attempt(int, double precision, double precision,
                                                    boolean, int, text) from public;
grant execute on function public.submit_ladder_attempt(int, double precision, double precision,
                                                       boolean, int, text)
  to authenticated, service_role;
