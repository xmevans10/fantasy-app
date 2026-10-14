-- Official-source portrait policy. Original image references are retained for rollback.
create table if not exists public.league_portrait_sources (
 url text primary key, original_url text not null, sport text not null
);
alter table public.league_portrait_sources enable row level security;
create table if not exists public.portrait_policy_backups (
 table_name text not null, row_id text not null, original jsonb not null,
 captured_at timestamptz not null default now(), primary key(table_name,row_id)
);
alter table public.portrait_policy_backups enable row level security;
insert into public.league_portrait_sources(url,original_url,sport)
select public_url,source_url,sport from public.headshot_assets
where status='ok' and public_url is not null and public_url<>''
and source_url ~ '^https://(cdn\.nba\.com|static\.www\.nfl\.com|img\.mlbstatic\.com|assets\.nhle\.com)/'
on conflict(url) do nothing;
insert into public.league_portrait_sources(url,original_url,sport)
select source_url,source_url,sport from public.headshot_assets
where status='ok' and source_url ~ '^https://(cdn\.nba\.com|static\.www\.nfl\.com|img\.mlbstatic\.com|assets\.nhle\.com)/'
on conflict(url) do nothing;
create or replace function public.league_portrait_allowed(u text) returns boolean
language sql stable security definer set search_path=public as $$
 select coalesce(u,'')='' or exists(select 1 from league_portrait_sources where url=u);
$$;
create or replace function public.filter_portrait_json(v jsonb) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare result jsonb; k text; value jsonb;
begin
 if jsonb_typeof(v)='object' then
  result='{}'::jsonb;
  for k,value in select * from jsonb_each(v) loop
   if k='headshot' and jsonb_typeof(value)='string' and not league_portrait_allowed(value#>>'{}') then
    result=result||jsonb_build_object(k,'');
   else result=result||jsonb_build_object(k,filter_portrait_json(value)); end if;
  end loop;
  return result;
 elsif jsonb_typeof(v)='array' then
  select coalesce(jsonb_agg(filter_portrait_json(a.value) order by a.ord),'[]'::jsonb) into result from jsonb_array_elements(v) with ordinality a(value,ord);
  return result;
 end if;
 return v;
end $$;
create or replace function public.enforce_league_portrait() returns trigger
language plpgsql security definer set search_path=public as $$
declare updated jsonb; current jsonb;
begin
 if tg_table_name in ('player_seasons','collectible_cards') then
  if not league_portrait_allowed(new.headshot) then
   insert into portrait_policy_backups(table_name,row_id,original) values(tg_table_name,new.id,jsonb_build_object('headshot',new.headshot)) on conflict do nothing;
   new.headshot='';
  end if;
 else
  current=new.content;updated=filter_portrait_json(current);
  if updated is distinct from current then
   insert into portrait_policy_backups(table_name,row_id,original) values(tg_table_name,new.id,jsonb_build_object('content',current)) on conflict do nothing;
   new.content=updated;
  end if;
 end if;
 return new;
end $$;
drop trigger if exists official_portrait_guard on public.player_seasons;
create trigger official_portrait_guard before insert or update of headshot on public.player_seasons for each row execute function public.enforce_league_portrait();
drop trigger if exists official_portrait_guard on public.puzzles;
create trigger official_portrait_guard before insert or update of content on public.puzzles for each row execute function public.enforce_league_portrait();
-- Collectibles may be installed separately on older catalogs.
do $$ begin
 if to_regclass('public.collectible_cards') is not null then
  execute 'drop trigger if exists official_portrait_guard on public.collectible_cards';
  execute 'create trigger official_portrait_guard before insert or update of headshot on public.collectible_cards for each row execute function public.enforce_league_portrait()';
 end if;
end $$;
revoke all on function public.league_portrait_allowed(text),public.filter_portrait_json(jsonb),public.enforce_league_portrait() from public,anon,authenticated;
grant execute on function public.league_portrait_allowed(text),public.filter_portrait_json(jsonb) to service_role;
-- Service-role-only bounded cleanup. The trigger saves the original reference before filtering.
create or replace function public.enforce_portraits_batch(target text, batch_size int default 500) returns int
language plpgsql security definer set search_path=public as $$
declare affected int;
begin
 if target not in ('player_seasons','puzzles','collectible_cards') then raise exception 'Unsupported portrait table'; end if;
 batch_size=greatest(1,least(batch_size,2000));
 if target in ('player_seasons','collectible_cards') then
  execute format('with candidates as materialized (select p.id,p.headshot from %I p where p.headshot<>'''' and not exists (select 1 from league_portrait_sources s where s.url=p.headshot) limit $1 for update of p skip locked), backups as (insert into portrait_policy_backups(table_name,row_id,original) select %L,id,jsonb_build_object(''headshot'',headshot) from candidates on conflict do nothing returning row_id) update %I p set headshot='''' from candidates c where p.id=c.id',target,target,target) using batch_size;
 else
  update puzzles p set content=p.content from (select id from puzzles where content is distinct from filter_portrait_json(content) limit batch_size for update skip locked) c where p.id=c.id;
 end if;
 get diagnostics affected=row_count;return affected;
end $$;
revoke all on function public.enforce_portraits_batch(text,int) from public,anon,authenticated;
grant execute on function public.enforce_portraits_batch(text,int) to service_role;

grant all on public.league_portrait_sources,public.portrait_policy_backups to service_role;
