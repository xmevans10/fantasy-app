-- Run after migration 0040; all test rows and backups roll back.
begin;
create temporary table player_seasons(id text primary key,headshot text);
create trigger official_portrait_guard before insert or update of headshot on pg_temp.player_seasons for each row execute function public.enforce_league_portrait();
insert into pg_temp.player_seasons values ('portrait-policy-regression-fixture','https://upload.wikimedia.org/unapproved.jpg');
do $$ begin
 if (select headshot from pg_temp.player_seasons) <> '' then raise exception 'Unapproved portrait survived';end if;
 if (select original->>'headshot' from public.portrait_policy_backups where table_name='player_seasons' and row_id='portrait-policy-regression-fixture') <> 'https://upload.wikimedia.org/unapproved.jpg' then raise exception 'Original reference not backed up';end if;
 if public.league_portrait_allowed('https://cdn.nba.com.evil.example/a.png') then raise exception 'Spoofed source accepted';end if;
 if public.filter_portrait_json('{"players":[{"name":"Test","headshot":"https://upload.wikimedia.org/test.jpg","stats":{"points":42}}],"answer":1}'::jsonb) <> '{"players":[{"name":"Test","headshot":"","stats":{"points":42}}],"answer":1}'::jsonb then raise exception 'Puzzle content changed';end if;
end $$;
alter table pg_temp.player_seasons disable trigger official_portrait_guard;
update pg_temp.player_seasons set headshot=(select original->>'headshot' from public.portrait_policy_backups where table_name='player_seasons' and row_id='portrait-policy-regression-fixture');
do $$ begin
 if (select headshot from pg_temp.player_seasons) <> 'https://upload.wikimedia.org/unapproved.jpg' then raise exception 'Backup restoration failed';end if;
end $$;
rollback;
select 'portrait policy and restoration tests passed' as result;
