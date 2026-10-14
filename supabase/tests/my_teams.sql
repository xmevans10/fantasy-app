-- Run against deployed schema; all test state is rolled back.
begin;
do $$
declare uid uuid:='f9d6a893-43ee-4c86-b8c7-202610140001'; board text; keeps text[];
 first_result jsonb; replay jsonb; denied boolean:=false;
begin
 insert into auth.users(id) values(uid);
 perform set_config('request.jwt.claim.sub',uid::text,true);
 select id into board from public.team_puzzles where is_starter and status='published' and available_at<=now() order by id limit 1;
 if board is null then raise exception 'Missing starter fixture';end if;
 select array_agg(id) into keeps from (select p->>'id' id from public.team_puzzles t,jsonb_array_elements(t.content->'players') p where t.id=board order by (p->>'grade')::numeric desc limit 4) cards;
 first_result:=public.complete_team_puzzle(board,keeps,current_date::text);
 if (first_result->>'awardedXP')::int<>250 or (first_result->>'correct')::int<>8 then raise exception 'Bad first reward';end if;
 replay:=public.complete_team_puzzle(board,keeps,current_date::text);
 if (replay->>'awardedXP')::int<>0 or replay->>'xp'<>first_result->>'xp' then raise exception 'Duplicate reward';end if;
 update public.progress set xp=0,last_played_day=(current_date-1)::text,streak=0 where user_id=uid;
 if (select xp from public.progress where user_id=uid)<>250 then raise exception 'Stale snapshot erased XP';end if;
 if (select last_played_day from public.progress where user_id=uid)<>current_date::text then raise exception 'Stale snapshot erased day';end if;
 begin perform public.complete_team_puzzle(board,array['bad'],current_date::text);
 exception when others then denied:=true;end;
 if not denied then raise exception 'Invalid cards accepted';end if;
 denied:=false;
 begin perform public.complete_team_puzzle(board,keeps,(current_date-10)::text);
 exception when others then denied:=true;end;
 if not denied then raise exception 'Invalid day accepted';end if;
 perform set_config('request.jwt.claim.sub','',true);denied:=false;
 begin perform public.complete_team_puzzle(board,keeps,current_date::text);
 exception when others then denied:=true;end;
 if not denied then raise exception 'Anonymous reward accepted';end if;
end $$;

-- RLS hides unpublished and future content even from a signed-in or anonymous client.
insert into public.team_puzzles(id,sport,team_abbr,format,shelf,recipe,recipe_version,content_hash,source_snapshot,content,status,available_at)
select 'team-test-future','nfl','NO','keep4','icons','test',1,'test-future-hash','test',content,'published',now()+interval '1 day'
from public.team_puzzles where is_starter limit 1;
set local role anon;
do $$ begin
 if exists(select 1 from public.team_puzzles where id='team-test-future') then raise exception 'Future content leaked';end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','f9d6a893-43ee-4c86-b8c7-202610140002',true);
set local role authenticated;
do $$ begin
 if exists(select 1 from public.team_completions) then raise exception 'Other user history leaked';end if;
end $$;
reset role;
rollback;
