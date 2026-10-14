-- Preserve the client sample: first 2,000 season rows by id, then newest/name-desc prefix.
-- JSON aggregation avoids PostgREST's row cap on the inner sample. Only the arcade's prefix
-- crosses the network; Draft & Spin still requests the full discovery sample.
create or replace function public.arcade_season_sample(p_sport text, p_limit int default 200)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with sample as materialized (
    select id, sport, name, team_abbr, season_year, position, stats, headshot, league, competition
    from public.player_seasons
    where sport = p_sport and not career and week is null
    order by id
    limit 2000
  ), selected as (
    select * from sample
    order by season_year desc, name collate "C" desc, id
    limit greatest(0, least(coalesce(p_limit, 200), 200))
  )
  select coalesce(jsonb_agg(to_jsonb(selected) order by season_year desc, name collate "C" desc, id), '[]'::jsonb)
  from selected;
$$;
revoke all on function public.arcade_season_sample(text, int) from public;
grant execute on function public.arcade_season_sample(text, int) to anon, authenticated, service_role;
