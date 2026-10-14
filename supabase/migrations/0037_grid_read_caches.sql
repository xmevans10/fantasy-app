-- Historical memberships remain valid when ingest is delayed. Reads must never rebuild.
create or replace function public.grid_membership_index(p_sport text, p_version int default 1)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select payload
  from public.grid_membership_index_cache
  where sport = p_sport
    and version = case when p_version >= 2 then 2 else 1 end;
$$;
revoke all on function public.grid_membership_index(text, int) from public;
grant execute on function public.grid_membership_index(text, int) to anon, authenticated, service_role;

-- Separate from memberships: autocomplete includes names even without team/season metadata.
create table if not exists public.grid_player_names_cache (
  sport text primary key,
  names text[] not null,
  computed_at timestamptz not null default now()
);
alter table public.grid_player_names_cache enable row level security;

create or replace function public.grid_player_names(p_sport text)
returns text[]
language sql
stable
security definer
set search_path = ''
set statement_timeout = '30s'
as $$
  select coalesce(
    (select names from public.grid_player_names_cache where sport = p_sport),
    (select coalesce(array_agg(distinct name order by name), '{}')
     from public.player_seasons
     where sport = p_sport and not career and name <> '')
  );
$$;
revoke all on function public.grid_player_names(text) from public;
grant execute on function public.grid_player_names(text) to anon, authenticated, service_role;

-- One RPC/transaction per sport prevents a timeout in one sport rolling back every other cache.
create or replace function public.refresh_grid_lookup_cache(p_sport text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
set statement_timeout = '120s'
as $$
declare
  v_version int;
  v_payload jsonb;
begin
  if p_sport is null or p_sport not in ('nfl','nba','baseball','soccer','tennis','hockey','f1','golf') then
    raise exception 'Unsupported sport';
  end if;

  for v_version in 1..2 loop
    v_payload := public.grid_membership_index_compute(p_sport, v_version);
    insert into public.grid_membership_index_cache(sport, version, payload, computed_at)
    values (p_sport, v_version, v_payload, now())
    on conflict (sport, version) do update
      set payload = excluded.payload, computed_at = excluded.computed_at;
  end loop;
end;
$$;
revoke all on function public.refresh_grid_lookup_cache(text) from public;
grant execute on function public.refresh_grid_lookup_cache(text) to service_role;

-- Names refresh independently so expensive membership rebuilds cannot roll it back.
create or replace function public.refresh_grid_player_names_cache(p_sport text)
returns void
language sql
volatile
security definer
set search_path = ''
set statement_timeout = '120s'
as $$
  insert into public.grid_player_names_cache(sport, names, computed_at)
  select p_sport, coalesce(array_agg(distinct name order by name), '{}'), now()
  from public.player_seasons
  where sport = p_sport and not career and name <> ''
  on conflict (sport) do update
    set names = excluded.names, computed_at = excluded.computed_at;

$$;
revoke all on function public.refresh_grid_player_names_cache(text) from public;
grant execute on function public.refresh_grid_player_names_cache(text) to service_role;

-- Rebuilds run only in service-role refreshes, outside player requests.
alter function public.grid_membership_index_compute(text, int) set statement_timeout = '120s';


-- Seed autocomplete immediately; it preserves the original sport/name predicate.
insert into public.grid_player_names_cache(sport,names,computed_at)
select sport,coalesce(array_agg(distinct name order by name),'{}'),now()
from public.player_seasons where not career and name<>''
group by sport
on conflict(sport) do update set names=excluded.names,computed_at=excluded.computed_at;
