-- Applied live 2026-07-27 via the Supabase MCP. Idempotent, so re-running is a no-op —
-- schema.sql remains the source of truth (CLAUDE.md).
--
-- `puzzles` had NO index beyond its primary key, so every client-facing fetch was a
-- sequential scan over the whole table. Harmless at today's 178 rows (0.3 ms), but this is a
-- *precondition* for the Grid pool backfill rather than an optimization: the backfill takes
-- the pool from 41 grid boards to hundreds per sport, and both hot paths below are linear in
-- pool size.
--
-- Measured 2026-07-27 on a 14,085-row temp replica of this exact table (roughly what the
-- backfill plus a year of daily mints produces), EXPLAIN (ANALYZE, BUFFERS):
--
--   RemotePuzzleRepository.fetch — `where format=? and sport=? order by id`
--     before: Seq Scan (13,146 rows discarded) + quicksort  → 3.244 ms
--     after:  Index Scan, no sort node at all                → 0.664 ms
--   random_grid_puzzle RPC — `where format='grid' and sport=? and active_date is distinct from ?`
--     before: Seq Scan (13,147 rows discarded)               → 2.491 ms
--     after:  Bitmap Index Scan                              → 0.813 ms
--   notify-daily-drop edge function — `where format='keep4' and active_date=?`
--     before: Seq Scan (14,080 rows discarded)               → 1.891 ms
--     after:  Index Scan                                     → 0.042 ms  (45x)
--
-- `id` is the third column of the first index on purpose, not padding. The client's fetch
-- orders by id (RemotePuzzleRepository.fetch: "Stable order is essential" — the modulo
-- fallback indexes into the pool by date, so every device must see the same ordering), and
-- with id trailing two equality columns the btree already returns rows in that order, so the
-- sort node disappears entirely instead of sorting a pool that grows without bound.
create index if not exists puzzles_format_sport_id_idx
  on public.puzzles (format, sport, id);

-- The active_date lookup has no sport predicate (notify-daily-drop asks for every sport's
-- keep4 row for the day), so it cannot ride the index above — `sport` sits between the two
-- columns it needs and only `format` would be usable as a prefix.
create index if not exists puzzles_format_active_date_idx
  on public.puzzles (format, active_date);
