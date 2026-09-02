-- Grid's "New random grid" blocks its own loading spinner on `grid_membership_index`, which the
-- client already measured and documented (RemotePuzzleRepository.swift) at ~10s for NFL once the
-- v2 axis joins (0013) landed on top of v1's 1.4-3.5s. The only index on `grid_axis_membership`
-- covers (sport, player_name); axis_key, which every v2 CTE joins on, is unindexed. That is
-- table-stakes and fixed below, but a from-scratch aggregate over the whole sport is always going
-- to be tens of thousands of rows re-summed into one JSON blob — a cost worth paying once per
-- content refresh, not once per cold app install / cache-TTL expiry / sport switch.
--
-- Fix: compute-and-cache. `grid_membership_index` becomes a thin wrapper — serve a fresh cached
-- payload in a single indexed row lookup (milliseconds) if one exists, otherwise fall back to the
-- original live computation (renamed `grid_membership_index_compute`) and populate the cache for
-- the next caller. `refresh_grid_membership_index_cache` lets CI proactively warm every
-- (sport, version) pair right after a grid mint, so real users hit the fast path essentially
-- always; the live-compute fallback stays as a correctness backstop, not the common case.
--
-- Purely additive: no existing function signature changes shape, no data is dropped.

create index if not exists grid_axis_membership_axis_key_idx
  on public.grid_axis_membership (sport, axis_key);

create table if not exists public.grid_membership_index_cache (
  sport      text not null,
  version    int  not null,
  payload    jsonb not null,
  computed_at timestamptz not null default now(),
  primary key (sport, version)
);

alter table public.grid_membership_index_cache enable row level security;

-- Read-only from the client's perspective — it never queries this table directly (it goes
-- through the RPC below), but the RPC runs as the caller under `security invoker` for the cache
-- hit path so it still needs a grant to read it.
drop policy if exists grid_membership_index_cache_read on public.grid_membership_index_cache;
create policy grid_membership_index_cache_read
  on public.grid_membership_index_cache for select
  to anon, authenticated
  using (true);

-- The original live-aggregation query, unchanged, just renamed so `grid_membership_index` can
-- wrap it.
create or replace function public.grid_membership_index_compute(p_sport text, p_version int default 1)
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
    'axisMemberships', coalesce((select jsonb_agg(coalesce(aa.line, '') order by p.pidx)
                                 from players p left join axis_any aa on aa.pidx = p.pidx),
                                '[]'::jsonb),
    'axisTeams', coalesce((select jsonb_agg(coalesce(atl.line, '') order by p.pidx)
                           from players p left join axis_team_lines atl on atl.pidx = p.pidx),
                          '[]'::jsonb)
  ) else '{}'::jsonb end;
$$;

revoke all on function public.grid_membership_index_compute(text, int) from public;
grant execute on function public.grid_membership_index_compute(text, int) to service_role;

-- Cache-or-compute wrapper, same signature/behavior contract the client already calls.
create or replace function public.grid_membership_index(p_sport text, p_version int default 1)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
set statement_timeout = '30s'
as $$
declare
  v_version int := case when p_version >= 2 then 2 else 1 end;
  v_payload jsonb;
begin
  select payload into v_payload
  from public.grid_membership_index_cache
  where sport = p_sport and version = v_version
    and computed_at > now() - interval '36 hours';

  if v_payload is not null then
    return v_payload;
  end if;

  v_payload := public.grid_membership_index_compute(p_sport, v_version);

  insert into public.grid_membership_index_cache (sport, version, payload, computed_at)
  values (p_sport, v_version, v_payload, now())
  on conflict (sport, version) do update
    set payload = excluded.payload, computed_at = excluded.computed_at;

  return v_payload;
end;
$$;

revoke all on function public.grid_membership_index(text, int) from public;
grant execute on function public.grid_membership_index(text, int) to anon, authenticated, service_role;

-- CI-callable: refresh every sport's cache for both versions right after a grid mint, so real
-- users hit the sub-second cache-read path instead of the ~10s live aggregate.
create or replace function public.refresh_grid_membership_index_cache()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sport text;
begin
  foreach v_sport in array array['nfl','nba','baseball','soccer','tennis'] loop
    insert into public.grid_membership_index_cache (sport, version, payload, computed_at)
    values (v_sport, 1, public.grid_membership_index_compute(v_sport, 1), now())
    on conflict (sport, version) do update
      set payload = excluded.payload, computed_at = excluded.computed_at;

    insert into public.grid_membership_index_cache (sport, version, payload, computed_at)
    values (v_sport, 2, public.grid_membership_index_compute(v_sport, 2), now())
    on conflict (sport, version) do update
      set payload = excluded.payload, computed_at = excluded.computed_at;
  end loop;
end;
$$;

revoke all on function public.refresh_grid_membership_index_cache() from public;
grant execute on function public.refresh_grid_membership_index_cache() to service_role;
