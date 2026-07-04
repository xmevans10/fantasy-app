-- Schedules the 4 cron-driven edge functions via pg_cron + pg_net (the hand-off referenced by
-- schema.sql's `seasons`/`versus_challenges` comments). `notify-versus-challenge` is NOT here —
-- it's triggered by a DB webhook on `versus_challenges` INSERT, a different mechanism.
--
-- Cadences below are taken verbatim from each function's own header comment
-- (supabase/functions/<name>/index.ts), not invented here.
--
-- HAND-OFF: <PROJECT_URL> and <SERVICE_ROLE_OR_ANON_KEY> below are placeholders — this session
-- has no live Supabase project access. Fill them in before running this migration. Recommend
-- storing the key as a `vault` secret (`select vault.create_secret(...)`) referenced via
-- `current_setting`, rather than a literal string in a checked-in file, once real project details
-- are known.
--
-- Idempotent: each job is unscheduled before being (re)scheduled, so this file is safe to re-run.

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.unschedule(jobid) from cron.job where jobname = 'weekly-cohort-rollover';
select cron.schedule(
  'weekly-cohort-rollover',
  '0 5 * * 1',  -- Monday 05:00 UTC, once a week (function comment: "Runs once a week")
  $$ select net.http_post(
       url := '<PROJECT_URL>/functions/v1/weekly-cohort-rollover',
       headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_OR_ANON_KEY>')
     ) $$
);

select cron.unschedule(jobid) from cron.job where jobname = 'versus-timeout';
select cron.schedule(
  'versus-timeout',
  '*/15 * * * *',  -- every 15 minutes (function comment: "Runs frequently ... e.g. every 15 min")
  $$ select net.http_post(
       url := '<PROJECT_URL>/functions/v1/versus-timeout',
       headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_OR_ANON_KEY>')
     ) $$
);

select cron.unschedule(jobid) from cron.job where jobname = 'notify-streak-risk';
select cron.schedule(
  'notify-streak-risk',
  '0 * * * *',  -- hourly (function comment: "Runs hourly")
  $$ select net.http_post(
       url := '<PROJECT_URL>/functions/v1/notify-streak-risk',
       headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_OR_ANON_KEY>')
     ) $$
);

select cron.unschedule(jobid) from cron.job where jobname = 'notify-season-end';
select cron.schedule(
  'notify-season-end',
  '0 9,15,21 * * *',  -- 3x/day (function comment: "Runs a few times a day")
  $$ select net.http_post(
       url := '<PROJECT_URL>/functions/v1/notify-season-end',
       headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_OR_ANON_KEY>')
     ) $$
);
