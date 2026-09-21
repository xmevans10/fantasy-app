-- The bot ladder becomes Puzzle Blitz (see tools/ingest/ladder_blitz.py, BotBlitzRun.swift).
--
-- Every per-format rung was fighting a floor its format could not get under, and the two floors
-- pointed opposite ways: keep4's forced 4/4 split meant no `bot_skill` could take the reference
-- player's win rate below ~0.27 (and ~0.63 on an easy board, which is why rungs 1-9 shipped at
-- minimum skill and were won 99.8% of the time), while Who Am I?'s 7-value clue ladder saturates
-- so completely that a *perfect* bot still lost ~75% of duels. One curve cannot descend through
-- both. A blitz run rebases chance to zero (`BlitzScoring.surplus`) and aggregates several
-- boards, which measured 1.000 -> 0.011 across the skill range — the lever, restored.
--
-- Additive only: the existing three modes stay valid, so this can land ahead of the client that
-- plays a blitz rung without invalidating a single live row.
alter table public.ladder_rungs drop constraint if exists ladder_rungs_mode_check;
alter table public.ladder_rungs add constraint ladder_rungs_mode_check
  check (mode in ('keep4', 'whoami', 'grid', 'blitz'));

-- A blitz rung pins no board: a run draws fresh boards every attempt, so `puzzle_id` carries the
-- run's SHAPE ('blitz-180s'), which is not a `puzzles.id`, and the foreign key from migration
-- 0016 (`ladder_rungs_puzzle_id_fkey`) would reject every one of them. Dropped here rather than
-- making the column nullable, and that choice is load-bearing: a shipped client decodes
-- `puzzle_id` as a non-optional `String`, so a NULL would throw for the whole rung array under
-- `LadderRepository.rungs()`'s single `try?` — emptying the Ladder tab for every live user. The
-- column stays `not null` and keeps carrying the run shape for a blitz rung.
alter table public.ladder_rungs
  drop constraint if exists ladder_rungs_puzzle_id_fkey;

comment on column public.ladder_rungs.puzzle_id is
  'The rung''s board (a real puzzles.id) for the four board modes, or for mode=blitz the run shape (e.g. blitz-180s) — a blitz draws fresh boards every attempt, so it pins none.';
comment on column public.ladder_rungs.time_limit_seconds is
  'For mode=blitz this is the RUN LENGTH (60/180/300), the variance dial the curve is built on.';
