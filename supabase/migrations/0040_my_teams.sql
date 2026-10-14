-- Shared, immutable team inventory. Kept outside general dailies to protect older clients.
create table if not exists public.team_puzzles (
 id text primary key check (id like 'team-%'),
 sport text not null, team_abbr text not null, format text not null check(format='keep4'),
 shelf text not null check(shelf in ('icons','history','deep_cuts')),
 recipe text not null, recipe_version int not null, content_hash text not null unique,
 source_snapshot text not null, content jsonb not null,
 status text not null check(status in ('draft','validated','published','withdrawn')),
 sort_order int not null default 0, is_starter boolean not null default false,
 available_at timestamptz not null default now(), created_at timestamptz not null default now()
);
create index if not exists team_puzzles_inventory_idx on public.team_puzzles(sport,team_abbr,sort_order) where status='published';
alter table public.team_puzzles enable row level security;
create policy "released team puzzles" on public.team_puzzles for select to anon,authenticated using(status='published' and available_at<=now());
grant select on public.team_puzzles to anon,authenticated;
grant all on public.team_puzzles to service_role;

create table if not exists public.team_completions (
 user_id uuid not null references auth.users(id) on delete cascade,
 puzzle_id text not null references public.team_puzzles(id),
 keep_ids text[] not null, correct int not null, xp_awarded int not null,
 completed_at timestamptz not null default now(), primary key(user_id,puzzle_id)
);
alter table public.team_completions enable row level security;
create policy "own team completions" on public.team_completions for select to authenticated using(user_id=auth.uid());
grant select on public.team_completions to authenticated;
grant all on public.team_completions to service_role;

-- Grades and correctness come from published content; reward and completion commit together.
-- Guest migration records an already awarded local completion without awarding again.
create or replace function public.complete_team_puzzle(p_puzzle_id text,p_keep_ids text[],p_day text,p_guest_migration boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); board jsonb; top_ids text[]; all_ids text[];
 correct_count int; award int:=0; inserted int; state public.progress%rowtype;
 day date; prior date; next_streak int;
begin
 if uid is null then raise exception 'Sign in required'; end if;
 day:=p_day::date;
 if abs(day-current_date)>1 then raise exception 'Invalid completion day'; end if;
 select content into board from public.team_puzzles where id=p_puzzle_id and status='published' and available_at<=now();
 if board is null then raise exception 'Puzzle unavailable'; end if;
 select array_agg(value->>'id') into all_ids from jsonb_array_elements(board->'players');
 if cardinality(all_ids)<>8 or cardinality(p_keep_ids)<>4 or
    (select count(distinct x) from unnest(p_keep_ids) x)<>4 or not p_keep_ids <@ all_ids then
   raise exception 'Exactly four distinct published cards required';
 end if;
 select array_agg(id) into top_ids from (select value->>'id' id from jsonb_array_elements(board->'players') order by (value->>'grade')::numeric desc limit 4) t;
 select count(*)*2 into correct_count from unnest(p_keep_ids) x where x=any(top_ids);
 insert into public.progress(user_id) values(uid) on conflict do nothing;
 select * into state from public.progress where user_id=uid for update;
 if not p_guest_migration then
   award:=100+case when correct_count=8 then 75 else 0 end;
   prior:=nullif(state.last_played_day,'')::date;
   next_streak:=case when prior=day then state.streak when prior=day-1 then state.streak+1 else 1 end;
   if prior is distinct from day then award:=award+50+least(next_streak,30)*25; end if;
 end if;
 insert into public.team_completions(user_id,puzzle_id,keep_ids,correct,xp_awarded)
 values(uid,p_puzzle_id,p_keep_ids,correct_count,award) on conflict do nothing;
 get diagnostics inserted=row_count;
 if inserted=0 then award:=0; end if;
 if award>0 then
   update public.progress set xp=xp+award,streak=next_streak,last_played_day=p_day,updated_at=now() where user_id=uid returning * into state;
   perform public.bump_weekly_xp(award);
 end if;
 return jsonb_build_object('awardedXP',award,'xp',state.xp,'streak',state.streak,'lastPlayedDay',coalesce(state.last_played_day,''),'correct',correct_count);
end $$;
revoke all on function public.complete_team_puzzle(text,text[],text,boolean) from public,anon;
grant execute on function public.complete_team_puzzle(text,text[],text,boolean) to authenticated;
