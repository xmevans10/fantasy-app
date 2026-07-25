-- rating-season-rollover: closes the 8-week rating season and opens the next
-- (supabase/functions/rating-season-rollover/index.ts, M5 Phase F).
--
-- pg_cron has no native "every 8 weeks" expression, and anchoring to a fixed calendar date drifts
-- as season boundaries shift. Instead this fires WEEKLY and the function self-gates: it no-ops
-- unless the active season has actually passed its `ends_at` (same "boundary drives the rollover,
-- not the cron cadence" pattern the weekly-cohort-rollover self-gate could use). Monday 06:00 UTC —
-- one hour after weekly-cohort-rollover (0 5 * * 1) so the two never contend for the same tick.
--
-- Applied live 2026-07-20 via the Supabase MCP (real project URL + anon key filled in);
-- <SERVICE_ROLE_OR_ANON_KEY> is a placeholder here for the same reason as in 0001/0002.
--
-- Idempotent: unschedule-before-schedule.

select cron.unschedule(jobid) from cron.job where jobname = 'rating-season-rollover';
select cron.schedule(
  'rating-season-rollover',
  '0 6 * * 1',  -- Monday 06:00 UTC, weekly (function self-gates to the real 8-week boundary)
  $$ select net.http_post(
       url := 'https://nhccgufqwndtoasdbkhc.supabase.co/functions/v1/rating-season-rollover',
       headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_OR_ANON_KEY>')
     ) $$
);
