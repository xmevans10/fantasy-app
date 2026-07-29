-- App Store Guideline 5.1.1(v): an app that supports account creation must also let the user
-- delete that account from inside the app. BallIQ 1.3 (17) was rejected on 2026-07-29 for
-- having no deletion path at all. Applied live 2026-07-29.

-- 1. Unblock the delete. Every other table referencing auth.users cascades (or, for `events`,
--    sets null to keep anonymised analytics). `versus_challenges.winner_id` was declared with
--    no ON DELETE action at all, so deleting any user who has ever WON a Versus challenge would
--    fail with a foreign-key violation -- i.e. deletion would work fine in testing and break for
--    the most engaged users.
alter table public.versus_challenges
  drop constraint if exists versus_challenges_winner_id_fkey;
alter table public.versus_challenges
  add constraint versus_challenges_winner_id_fkey
  foreign key (winner_id) references auth.users(id) on delete set null;

-- 2. Self-service deletion. `security definer` so it runs as `postgres`, which (unlike
--    `authenticated`) has DELETE on auth.users and BYPASSRLS. The user id comes from
--    auth.uid() -- derived from the caller's JWT -- so there is no parameter to forge and a
--    caller can only ever delete themselves.
--    NOTE: this deliberately does NOT touch storage.objects. Supabase guards that table with a
--    trigger (storage.protect_delete) rejecting any direct DELETE unless
--    `storage.allow_delete_query` is set, because deleting the row orphans the underlying file
--    in the object store. An earlier cut of this function deleted the avatar row here and
--    failed outright with 42501, taking the whole account deletion down with it. The avatar is
--    removed by the client through the Storage API instead (see
--    `RepositoryContainer.deleteAccount`), which drops the file and the row together.
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  -- Everything in public.* cascades from here (and events.user_id nulls out, so analytics stay
  -- anonymised rather than being deleted).
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.delete_own_account() from public, anon;
grant execute on function public.delete_own_account() to authenticated;
