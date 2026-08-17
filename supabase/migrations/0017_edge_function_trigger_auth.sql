-- 0017 — DB -> Edge Function triggers were 401ing. Applied live to nhccgufqwndtoasdbkhc.
--
-- **What was broken.** Every `notify-*` Edge Function runs with `verify_jwt = true`. The pg_cron
-- jobs account for that (`0001_schedule_edge_functions.sql` passes a bearer token); the three
-- pg_net *triggers* did not — they posted `'{"Content-Type": "application/json"}'` and nothing
-- else. So every trigger-driven push has been rejected at the edge since the day it shipped:
--
--   probe, 2026-08-13, headers exactly as the trigger sent them:
--     status 401  {"code":"UNAUTHORIZED_NO_AUTH_HEADER","message":"Missing authorization header"}
--   same probe through `edge_function_headers()`:
--     status 200  {"skipped":"gone"}
--
-- This is invisible from every direction: `net.http_post` is fire-and-forget so the insert
-- succeeds, the trigger has an exception guard, and `net._http_response` is pruned. The app's
-- Versus tab badge existed as an explicit stopgap "while APNs pushes are stubbed" — they were
-- not stubbed, they were 401ing.
--
-- **The fix.** One shared header builder, reading the publishable key from Vault. Vault rather
-- than an inline literal because `supabase/schema.sql` is in a public repo, and because a key
-- rotation is then one UPDATE instead of a migration. Mirrors `get_apns_config()`, the
-- established pattern here for exactly this problem.

select vault.create_secret(
  '<PUBLISHABLE_KEY>',
  'EDGE_FUNCTION_BEARER',
  'Publishable key used as the bearer token when a DB trigger posts to an Edge Function (they all run verify_jwt = true). Rotate alongside the publishable key.')
where not exists (select 1 from vault.secrets where name = 'EDGE_FUNCTION_BEARER');

create or replace function public.edge_function_headers()
returns jsonb language plpgsql security definer
set search_path = ''
as $$
declare
  bearer text;
begin
  select decrypted_secret into bearer
    from vault.decrypted_secrets where name = 'EDGE_FUNCTION_BEARER' limit 1;
  -- Degrade to the old header set rather than failing the trigger: a missing secret should
  -- cost a push, never an insert.
  if bearer is null then
    return '{"Content-Type": "application/json"}'::jsonb;
  end if;
  return jsonb_build_object('Content-Type', 'application/json',
                            'Authorization', 'Bearer ' || bearer);
end;
$$;

revoke all on function public.edge_function_headers() from public, anon, authenticated;

create or replace function public.notify_versus_challenge_webhook()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://nhccgufqwndtoasdbkhc.supabase.co/functions/v1/notify-versus-challenge',
    body := jsonb_build_object('record', jsonb_build_object(
      'id', new.id, 'challenger_id', new.challenger_id, 'opponent_id', new.opponent_id)),
    headers := public.edge_function_headers());
  return new;
end;
$$;

create or replace function public.notify_versus_result_webhook()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  finisher uuid; waiting uuid;
begin
  if new.challenger_score is not null and old.challenger_score is null then
    finisher := new.challenger_id; waiting := new.opponent_id;
  elsif new.opponent_score is not null and old.opponent_score is null then
    finisher := new.opponent_id; waiting := new.challenger_id;
  else
    return new;
  end if;

  perform net.http_post(
    url := 'https://nhccgufqwndtoasdbkhc.supabase.co/functions/v1/notify-versus-result',
    body := jsonb_build_object('record', jsonb_build_object(
      'id', new.id, 'finisher_id', finisher, 'waiting_id', waiting)),
    headers := public.edge_function_headers());
  return new;
end;
$$;

create or replace function public.notify_friend_request_webhook()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'pending' then
    perform net.http_post(
      url := 'https://nhccgufqwndtoasdbkhc.supabase.co/functions/v1/notify-friend-request',
      body := jsonb_build_object('record', jsonb_build_object(
        'requester_id', new.requester_id, 'addressee_id', new.addressee_id)),
      headers := public.edge_function_headers());
  end if;
  return new;
end;
$$;
