-- Stat and position axis membership for client-side Grid generation, plus the v2 wire format
-- that serves it. Sibling of 0011 (`grid_membership_index`), which shipped the team/year relation
-- and could therefore only drive two board shapes: teams x decades and teams x teams. The other
-- three archetypes (`teams-x-stats`, `teams-x-mixed`, `mixed-x-teams`) need to know which
-- *seasons* clear "30+ Pass TD" or were played at QB, and nothing on the client did.
--
-- WHY A TABLE AND NOT A PREDICATE IN THIS FILE. The thresholds are curated editorial content --
-- `grid_axes._STATS` hand-sets "1,000+ Rush Yds" against real significance, with volume gates on
-- the rate stats (a .400 average over 3 plate appearances is not a .300 hitter). Re-expressing
-- those predicates in SQL would make this file a second source of truth for them, and the first
-- time someone retuned a threshold in Python the two would silently disagree -- with the daily
-- board and the practice board then asking measurably different questions under the same label.
-- So the pipeline evaluates the real `Filter` objects in Python (`--grid-axis-membership`,
-- tools/ingest/main.py) and writes the *result* here. Postgres stores facts; Python owns rules.
--
-- Grain: rows are (player, season_year) pairs, i.e. SEASON grain, which is what every stat and
-- position axis uses in grid_axes.py. Career-grain axes are a Tier-1 roadmap item and would need
-- their own shape (no season_year), not a reinterpretation of these rows.
create table if not exists public.grid_axis_membership (
  sport        text not null,
  axis_key     text not null,     -- grid_axes' own key, e.g. 'stat:passing_tds:gte:30'
  axis_kind    text not null,     -- 'stat' | 'position'
  axis_label   text not null,     -- rendered label, e.g. '30+ Pass TD'
  player_name  text not null,
  season_year  int  not null,
  primary key (sport, axis_key, player_name, season_year)
);
alter table public.grid_axis_membership enable row level security;
-- No policies: written by service-role ingest, read only through the security-definer RPC below.

-- Lookup path for the RPC's aggregate. The primary key already leads with `sport`, but the RPC
-- also joins on (player_name, season_year) to fold membership into the per-player lines, and
-- without this that join degrades to a scan of the sport's whole slice.
create index if not exists grid_axis_membership_player_idx
  on public.grid_axis_membership (sport, player_name, season_year);

-- v2 of the membership index. `p_version` DEFAULTS TO 1 and v1 output is byte-identical to
-- 0011's, which is the entire compatibility story: the shipped App Store client calls this with
-- one argument, gets exactly what it got yesterday, and never sees the new fields. A client that
-- cannot use v2 must not be handed it -- `GridMembershipIndex.isUsable` rejects any payload whose
-- `version` it doesn't recognise, so emitting v2 unconditionally would silently disable
-- client-side practice generation for every existing install and fall it back to the 41-board
-- server pool.
--
-- v2 adds two arrays, both parallel to `players` and both using the SAME run encoding as
-- `memberships` (`axisIdx:yearOffset[,yearOffset...][;axisIdx:...]`, offsets relative to
-- `minYear`) so the client parses one format rather than three:
--   axes:            [{key, kind, label}, ...]   -- index = axis id used by axisMemberships
--   axisMemberships: ["0:12,13;3:20", ...]       -- same index as `players`
-- The 1-arg overload from 0011 must GO, not coexist: with both present, PostgREST's one-argument
-- call becomes an ambiguous-function error rather than resolving to either. Dropping and
-- recreating inside one migration is atomic, so no request ever lands in a window where the
-- function is missing, and the 2-arg form with `p_version default 1` is a strict superset of the
-- behaviour being dropped.
drop function if exists public.grid_membership_index(text);

create or replace function public.grid_membership_index(p_sport text, p_version int default 1)
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
  ),
  -- Axis membership, only when v2 was asked for. Restricted to players already in `players`:
  -- an axis row for someone with no team membership could never satisfy a cell (every archetype
  -- crosses at least one team axis, and `mixed_any` only ever faces an all-team dimension), so
  -- shipping them would be payload with no reachable use.
  axes as (
    select m.axis_key, m.axis_kind, m.axis_label,
           (row_number() over (order by m.axis_kind, m.axis_key))::int - 1 as aidx
    from (select distinct axis_key, axis_kind, axis_label
          from public.grid_axis_membership where sport = p_sport and p_version >= 2) m
  ),
  axis_runs as (
    select p.pidx, a.aidx,
           string_agg((gam.season_year - lo.min_year)::text, ',' order by gam.season_year) as years
    from public.grid_axis_membership gam
    join axes a on a.axis_key = gam.axis_key
    join players p on p.name = gam.player_name
    cross join lo
    where gam.sport = p_sport and p_version >= 2
    group by p.pidx, a.aidx
  ),
  axis_lines as (
    select pidx, string_agg(aidx::text || ':' || years, ';' order by aidx) as line
    from axis_runs group by pidx
  )
  select jsonb_build_object(
    'sport', p_sport,
    'version', case when p_version >= 2 then 2 else 1 end,
    'minYear', coalesce((select min_year from lo), 0),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('abbr', abbr, 'league', league)
                              order by tidx) from teams), '[]'::jsonb),
    'players', coalesce((select jsonb_agg(name order by pidx) from players), '[]'::jsonb),
    'memberships', coalesce((select jsonb_agg(line order by pidx) from lines), '[]'::jsonb)
  ) || case when p_version >= 2 then jsonb_build_object(
    'axes', coalesce((select jsonb_agg(jsonb_build_object('key', axis_key, 'kind', axis_kind,
                                                          'label', axis_label) order by aidx)
                      from axes), '[]'::jsonb),
    -- Parallel to `players`, so a player with no axis membership still needs a slot. `lines`
    -- above can be sparse because 0011's client zips it against `players` by index and every
    -- player has at least one team; an axis-less player is normal, so this left-joins to ''.
    'axisMemberships', coalesce((select jsonb_agg(coalesce(al.line, '') order by p.pidx)
                                 from players p left join axis_lines al on al.pidx = p.pidx),
                                '[]'::jsonb)
  ) else '{}'::jsonb end;
$$;

revoke all on function public.grid_membership_index(text, int) from public;
grant execute on function public.grid_membership_index(text, int) to anon, authenticated, service_role;
