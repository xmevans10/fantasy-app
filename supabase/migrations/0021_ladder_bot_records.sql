-- "Your record vs each character" — the roster screen's record block.
--
-- `ladder_attempts` is own-read RLS and the bot is only reachable through `ladder_rungs`, so this
-- needs one SECURITY DEFINER aggregate rather than a client-side join over a table the client can
-- only see its own rows of. Scoped hard to `auth.uid()`: a signed-out caller gets zero rows,
-- which is exactly the roster's "sign in to see your record" state, so the screen needs no
-- separate signed-out code path.
create or replace function public.my_bot_records()
returns table (bot_id text, played int, won int,
               best_score double precision, best_bot_score double precision)
language sql security definer stable as $$
  select r.bot_id,
         count(*)::int,
         count(*) filter (where a.won)::int,
         max(a.score),
         max(a.bot_score)
  from public.ladder_attempts a
  join public.ladder_rungs r on r.rung = a.rung
  where a.user_id = auth.uid()
  group by r.bot_id;
$$;

revoke all on function public.my_bot_records() from public;
grant execute on function public.my_bot_records() to anon, authenticated, service_role;
