-- Applied live 2026-08-03 via the Supabase Management API. Idempotent, so re-running is a
-- no-op — schema.sql remains the source of truth (CLAUDE.md).
--
-- The pipeline's "already stored but improvable" lookup (upsert.fetch_catalog_ids_missing)
-- walks player_seasons for rows whose headshot/competition are NULL/'' — keyset-paginated
-- over (sport, id). With near-total coverage the filtered walk must traverse the whole
-- sport partition to find nothing: baseball (38.7k rows, ~100% headshot coverage) blew the
-- statement timeout (57014) in CI 2026-08-01 and 2026-08-03. The full (sport, id) index
-- can't help — it still walks every row of the partition. A partial index makes the
-- missing-set lookup an index-only scan of the (tiny) missing set, in id order as the
-- keyset pagination needs.
create index if not exists player_seasons_missing_headshot_idx
  on public.player_seasons (sport, id)
  where headshot is null or headshot = '';

create index if not exists player_seasons_missing_competition_idx
  on public.player_seasons (sport, id)
  where competition is null or competition = '';
