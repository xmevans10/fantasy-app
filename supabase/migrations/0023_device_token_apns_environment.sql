-- Which APNs host a token is valid on.
--
-- APNs runs two entirely separate environments and a token minted for one is meaningless on the
-- other. `_shared/apns.ts` hardcoded the production host, so every token registered by a debug or
-- simulator build was posted somewhere that had never heard of it: 100% of the pushes this app
-- ever attempted failed with BadDeviceToken, while the cadence layer above worked correctly.
--
-- The environment belongs to the TOKEN, not the server, so it has to be stored per row.
-- Defaulting to 'production' is right for App Store builds; a debug build corrects its own row on
-- the next registration upsert, so nothing is back-filled on a guess.
alter table public.device_tokens
  add column if not exists apns_environment text not null default 'production';

alter table public.device_tokens drop constraint if exists device_tokens_apns_env;
alter table public.device_tokens add constraint device_tokens_apns_env
  check (apns_environment in ('production', 'development'));
