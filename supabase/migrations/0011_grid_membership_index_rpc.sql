-- Applied live 2026-07-27 via the Supabase MCP. `create or replace`, so re-running is a no-op —
-- schema.sql remains the source of truth (CLAUDE.md).
--
-- The membership relation — player -> (team, league, year) — for one sport, as a single compact
-- payload. This is what lets the client generate its OWN Grid boards offline instead of being
-- limited to the server-minted pool (41 boards total, of which baseball has 1). Sibling of
-- `grid_player_names`: same security posture, same "one aggregate so PostgREST's 1000-row cap
-- can't truncate it", same 7-day DiskCache on the client.
--
-- Scope note: memberships alone are enough for exactly two board shapes — teams x decades and
-- teams x teams. Both ask only "did this player appear for this team in this year", which is
-- this relation. Stat and position axes need the `stats` jsonb and are deliberately NOT shipped;
-- the client generator does not offer those archetypes. See GridLocalGenerator.swift.
--
-- Why the relation is so much smaller than the table: `player_seasons` carries game-grain rows
-- too (nfl 100,468 rows collapse to 27,135 distinct memberships). grid.py never sees the
-- difference — `_group_by_player` keys by name and a duplicate season can only re-satisfy an
-- axis the player already satisfied — so de-duplicating here is not an approximation.
--
--   sport     season rows -> memberships   players   teams
--   nfl           100,468 ->      27,135     6,210      39
--   baseball       83,160 ->      64,331     6,778      30
--   soccer         78,987 ->      78,987    21,894   1,253
--   nba            49,516 ->      23,249     4,540      72
--   tennis          8,502 ->       8,502     1,264      78
--
-- WIRE FORMAT (version 1). Two parallel arrays indexed by player, plus a team table:
--   { sport, version, minYear,
--     teams:        [{abbr, league}, ...]        -- index = team id, league "" when unscoped
--     players:      ["Tom Brady", ...]           -- index = player id
--     memberships:  ["3:12,13;7:20", ...]        -- same index as `players`
--   }
-- A membership line is `teamIdx:yearOffset[,yearOffset...][;teamIdx:...]`, year offsets relative
-- to `minYear`. Decimal rather than a bit-packed blob on purpose: the payload is gzipped on the
-- wire anyway (measured below), and a format both Postgres and Swift can express in a few lines
-- is worth more than the bytes a hand-rolled bit stream would save.
--
-- LEAGUE SCOPING mirrors grid.py's `_team_key`/`_team_keys` exactly, and it has to: soccer
-- `team_abbr` values are derived from club names and collide across countries (MCI is Manchester
-- City AND Melbourne City). So for soccer the team identity is (abbr, league) and rows with a
-- blank league are dropped — an unscoped axis is precisely the merged behaviour being prevented.
-- For every other sport league is forced to '' so one franchise can't split into several teams.
--
-- `set statement_timeout` is load-bearing, not defensive boilerplate. The aggregate runs
-- 1.4-3.5s depending on sport, and the anon role's default is 3s (`pg_roles.rolconfig`), so
-- without this soccer would return 57014 to exactly the users who aren't signed in — and
-- PostgREST's error is indistinguishable from "no data" to a client wrapping the call in
-- `try?`. This project has already shipped that bug once (see 0007's roster-lookup note).
create or replace function public.grid_membership_index(p_sport text)
returns jsonb
language sql
stable
security definer
set search_path = ''
set statement_timeout = '30s'
as $$
  with base as (
    select distinct
      ps.name,
      ps.team_abbr as abbr,
      case when p_sport = 'soccer' then coalesce(ps.league, '') else '' end as league,
      ps.season_year as yr
    from public.player_seasons ps
    where ps.sport = p_sport
      and not ps.career
      and coalesce(ps.team_abbr, '') <> ''
      and coalesce(ps.name, '') <> ''
      and ps.season_year is not null
  ),
  scoped as (
    select * from base where p_sport <> 'soccer' or league <> ''
  ),
  teams as (
    select abbr, league, (row_number() over (order by abbr, league))::int - 1 as tidx
    from (select distinct abbr, league from scoped) d
  ),
  players as (
    select name, (row_number() over (order by name))::int - 1 as pidx
    from (select distinct name from scoped) d
  ),
  lo as (select min(yr) as min_year from scoped),
  runs as (
    select p.pidx, t.tidx,
           string_agg((s.yr - lo.min_year)::text, ',' order by s.yr) as years
    from scoped s
    join players p on p.name = s.name
    join teams t on t.abbr = s.abbr and t.league = s.league
    cross join lo
    group by p.pidx, t.tidx
  ),
  lines as (
    select pidx, string_agg(tidx::text || ':' || years, ';' order by tidx) as line
    from runs group by pidx
  )
  select jsonb_build_object(
    'sport', p_sport,
    'version', 1,
    'minYear', coalesce((select min_year from lo), 0),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('abbr', abbr, 'league', league)
                              order by tidx) from teams), '[]'::jsonb),
    'players', coalesce((select jsonb_agg(name order by pidx) from players), '[]'::jsonb),
    'memberships', coalesce((select jsonb_agg(line order by pidx) from lines), '[]'::jsonb)
  );
$$;

revoke all on function public.grid_membership_index(text) from public;
grant execute on function public.grid_membership_index(text) to anon, authenticated, service_role;
