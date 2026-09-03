-- One-call coverage snapshot for the headshot-backfill.yml convergence loop (and for anyone
-- checking coverage by hand instead of hand-rolling the group-by every time). PostgREST has no
-- GROUP BY, so this is the difference between one RPC call and N sport-scoped count queries.
create or replace function public.headshot_coverage_summary()
returns jsonb
language sql
stable
security definer
set search_path = 'public'
as $$
  select coalesce(jsonb_object_agg(sport, by_status), '{}'::jsonb)
  from (
    select sport, jsonb_object_agg(status, cnt order by status) as by_status
    from (
      select sport, status, count(*) cnt
      from headshot_assets
      group by sport, status
    ) s
    group by sport
  ) t;
$$;

revoke all on function public.headshot_coverage_summary() from public, anon, authenticated;
grant execute on function public.headshot_coverage_summary() to service_role;
