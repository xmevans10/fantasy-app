-- Reuse the existing official-portrait policy for the new inventory.
create trigger official_portrait_guard before insert or update of content on public.team_puzzles for each row execute function public.enforce_league_portrait();

-- Older clients mirror a whole progress snapshot. Once team rewards exist, a delayed
-- pre-reward snapshot must not erase the XP/streak the atomic team completion just banked.
create or replace function public.preserve_team_progress() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.team_completions where user_id=old.user_id) then
   new.xp:=greatest(new.xp,old.xp);
   if coalesce(new.last_played_day,'') < coalesce(old.last_played_day,'') then
     new.last_played_day:=old.last_played_day;
     new.streak:=old.streak;
   end if;
 end if;
 return new;
end $$;
create trigger preserve_team_progress before update on public.progress for each row execute function public.preserve_team_progress();
