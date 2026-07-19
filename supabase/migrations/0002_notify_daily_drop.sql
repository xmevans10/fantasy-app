-- notify-daily-drop: "today's puzzles just dropped" push at ~9am device-local time
-- (supabase/functions/notify-daily-drop/index.ts). Two parts: the per-user opt-out column,
-- and the hourly pg_cron trigger (hourly because "9am local" happens 24 times a day
-- somewhere — the function itself filters to devices whose local hour is 9, same pattern as
-- notify-streak-risk).
--
-- Applied live 2026-07-19 via the Supabase MCP (real project URL + anon key filled in);
-- <SERVICE_ROLE_OR_ANON_KEY> is a placeholder here for the same reason as in 0001.
--
-- Idempotent: `add column if not exists` + unschedule-before-schedule.

alter table public.notification_settings
  add column if not exists daily_drop boolean not null default true;

select cron.unschedule(jobid) from cron.job where jobname = 'notify-daily-drop';
select cron.schedule(
  'notify-daily-drop',
  '0 * * * *',  -- hourly (function comment: "Runs hourly")
  $$ select net.http_post(
       url := 'https://nhccgufqwndtoasdbkhc.supabase.co/functions/v1/notify-daily-drop',
       headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_OR_ANON_KEY>')
     ) $$
);
