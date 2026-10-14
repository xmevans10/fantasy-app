-- Boards taken out of Browse because they duplicated another board (same title, or 5+ of the
-- same 8 players). Kept whole so any of them can be restored with an insert back into puzzles.
-- puzzle_history is deliberately left alone: the generator reads it for novelty, so a retired
-- board's signature can never be minted again.
--
-- 2026-09-26 sweep: 130 of 465 keep4 boards retired (68 same title, 62 near-duplicates). Boards
-- referenced by versus_challenges / ladder_* were always kept, as was one board per group.
create table if not exists public.puzzles_retired (
  id           text primary key,
  sport        text not null,
  format       text not null,
  content      jsonb not null,
  active_date  date,
  kept_id      text,          -- the board it duplicated, which stays live
  reason       text not null, -- 'same title' | '5+ of 8 same players'
  retired_at   timestamptz not null default now()
);
alter table public.puzzles_retired enable row level security;
-- No policies: service role only.
