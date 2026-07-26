-- Applied live 2026-07-26 via the Supabase MCP. Idempotent — schema.sql stays the source of truth.
--
-- Nation -> League -> Club, in the data and not just in the picker.
--
-- `league` on both `teams` and `player_seasons` holds a NATION ("Germany"), which collapses the
-- middle level: Bundesliga and 2. Bundesliga are indistinguishable, so a "league" filter can
-- only ever mean "this country". `leagues` already carries country/tier/espn_slug (0008), and
-- `espn_slug` is the stable competition key ("ger.1", "ger.2").
--
-- This adds that competition key to the two tables that reference a league WITHOUT touching the
-- existing `league` column, so every current read keeps working and adoption can be incremental.
-- Nation becomes derived (competition -> leagues.country) rather than stored, which is what
-- makes the three levels independent of each other.
alter table public.teams          add column if not exists competition text;
alter table public.player_seasons add column if not exists competition text;

-- Every club ingested so far is top-flight, so its competition is its nation's tier-1 entry.
-- Only fills NULLs, so re-running is safe.
update public.teams t
   set competition = l.espn_slug
  from public.leagues l
 where t.competition is null
   and l.sport = t.sport and l.league = t.league and l.tier = 1
   and l.espn_slug is not null;

create index if not exists teams_competition_idx
  on public.teams (sport, competition) where competition is not null;
create index if not exists player_seasons_competition_idx
  on public.player_seasons (sport, competition) where competition is not null;
