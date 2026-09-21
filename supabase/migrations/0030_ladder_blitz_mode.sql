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

-- A blitz rung has no pinned board: the run draws fresh boards every attempt, which is also why
-- it needs no `ladder_rung_boards` pool — the replay bug that table exists to prevent cannot
-- happen when nothing is pinned. `puzzle_id` carries the run's shape ('blitz-180s') so the
-- not-null column stays honest rather than holding a puzzle id that does not exist.
comment on column public.ladder_rungs.puzzle_id is
  'The rung''s board, or for mode=blitz the run shape (e.g. blitz-180s) — a blitz draws fresh.';
comment on column public.ladder_rungs.time_limit_seconds is
  'For mode=blitz this is the RUN LENGTH (60/180/300), the variance dial the curve is built on.';
