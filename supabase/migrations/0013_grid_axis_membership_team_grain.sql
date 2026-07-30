-- Corrects the wire format 0012 introduced, before anything shipped against it.
--
-- 0012 stored (axis, player, season_year) and left the client to join that against the team
-- relation on the YEAR. That silently answers a different question than `grid.py` does.
-- `player_seasons` is game-grain and additionally carries teamless season-aggregate rows for
-- players who moved mid-season: James Harden has 7 CLE rows for 2026 and 3 rows with a blank
-- `team_abbr`, and it is the blank-team aggregate that clears "8+ APG". A year-join therefore
-- concluded he cleared 8 APG *as a Cavalier* — a claim `grid.py` denies, because
-- `_satisfying_season` matches both predicates against ONE `RawSeason`. `GridCrossCheckTests`
-- caught it against production data, which is exactly what that file exists for.
--
-- Fix: carry the team from the same row that satisfied the axis, so the pairing is a stored fact
-- rather than a client-side inference. Years then drop out of the payload entirely, because
-- neither grain needs them:
--   * season grain (team x stat) — the cell asks "was there a season with both", so the
--     (axis, team) pair IS the answer.
--   * career grain (stat row vs career team column, inside mixed-x-teams) — the stat is the
--     cell's only season-grain constraint, so it reduces to "ever satisfied it": a set of axes.
-- The payload gets smaller as well as correct.
--
-- Purely additive, and deliberately so — no drop, no delete, nothing to ask permission for.
-- 0012's rows survive the change *correctly*, which is worth spelling out because it is not
-- obvious: they carry no team, so the new `team_abbr` default of '' says "satisfied this axis in
-- a season whose team we didn't record". For the CAREER-grain question ("ever cleared 8 APG")
-- that is still a true fact and still counted. For the SEASON-grain one it contributes nothing,
-- because the (axis x team) join below drops blank teams by construction. So the pre-change rows
-- are inert where they'd be wrong and correct where they'd be used, and re-running
-- `--grid-axis-membership` simply adds the team-qualified rows alongside them.
alter table public.grid_axis_membership
  add column if not exists team_abbr text not null default '',
  add column if not exists league    text not null default '';

-- The identity of a row now includes the team: one player can satisfy one axis in one year for
-- more than one club (a mid-season move), and those are distinct facts. Widening a primary key
-- can never conflict — every existing row stays unique under a superset of its old columns.
do $$ begin
  alter table public.grid_axis_membership drop constraint grid_axis_membership_pkey;
  alter table public.grid_axis_membership
    add constraint grid_axis_membership_pkey
    primary key (sport, axis_key, player_name, team_abbr, league, season_year);
exception when others then null;
end $$;

create index if not exists grid_axis_membership_lookup_idx
  on public.grid_axis_membership (sport, player_name);

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
  axes as (
    select m.axis_key, m.axis_kind, m.axis_label,
           (row_number() over (order by m.axis_kind, m.axis_key))::int - 1 as aidx
    from (select distinct axis_key, axis_kind, axis_label
          from public.grid_axis_membership where sport = p_sport and p_version >= 2) m
  ),
  -- Career grain: which axes a player ever satisfied, blank-team aggregate rows included.
  -- Deduped in a subquery rather than `string_agg(distinct ... order by ...)`, which Postgres
  -- only allows when the ordering expression matches the distinct one — forcing a text sort that
  -- would emit "10" before "2" unless zero-padded, and leak the padding into the wire format.
  axis_any_pairs as (
    select distinct p.pidx, a.aidx
    from public.grid_axis_membership gam
    join axes a on a.axis_key = gam.axis_key
    join players p on p.name = gam.player_name
    where gam.sport = p_sport and p_version >= 2
  ),
  axis_any as (
    select pidx, string_agg(aidx::text, ',' order by aidx) as line
    from axis_any_pairs group by pidx
  ),
  -- Season grain: (axis, team) pairs a SINGLE row satisfied. Blank-team rows are excluded here
  -- by the join to `teams` — they can't anchor a team cell, which is the entire correction.
  axis_team as (
    select distinct p.pidx, a.aidx, t.tidx
    from public.grid_axis_membership gam
    join axes a on a.axis_key = gam.axis_key
    join players p on p.name = gam.player_name
    join teams t on t.abbr = gam.team_abbr and t.league = gam.league
    where gam.sport = p_sport and p_version >= 2
  ),
  axis_team_lines as (
    select pidx,
           string_agg(aidx::text || ':' || teams_csv, ';' order by aidx) as line
    from (
      select pidx, aidx, string_agg(tidx::text, ',' order by tidx) as teams_csv
      from axis_team group by pidx, aidx
    ) g
    group by pidx
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
    -- Both arrays are parallel to `players`, so a player with no axis membership keeps a slot.
    'axisMemberships', coalesce((select jsonb_agg(coalesce(aa.line, '') order by p.pidx)
                                 from players p left join axis_any aa on aa.pidx = p.pidx),
                                '[]'::jsonb),
    'axisTeams', coalesce((select jsonb_agg(coalesce(atl.line, '') order by p.pidx)
                           from players p left join axis_team_lines atl on atl.pidx = p.pidx),
                          '[]'::jsonb)
  ) else '{}'::jsonb end;
$$;

revoke all on function public.grid_membership_index(text, int) from public;
grant execute on function public.grid_membership_index(text, int) to anon, authenticated, service_role;
