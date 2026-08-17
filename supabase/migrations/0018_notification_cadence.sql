-- 0018 — three-a-day push cadence. Applied live to nhccgufqwndtoasdbkhc 2026-08-13.
--
-- Slots, all resolved in the RECIPIENT's local time:
--   09:00  notify-daily-drop    "today's puzzles just dropped"     (existing)
--   13:00  notify-engagement    "your move" — duel > ladder > league  (new)
--   20:00  notify-streak-risk   streak at risk, else the evening recap from notify-engagement
--
-- Two things had to exist before the cadence could be turned up safely:
--
-- 1. **A record of what was sent.** Every notifier fired and forgot, so "why did I get five
--    pushes" was unanswerable and a cap was unenforceable. `notification_log` is that record,
--    and its unique index doubles as the idempotency guard — an hourly cron that double-fires
--    loses the race on the insert instead of sending twice.
-- 2. **An opt-out for the new slot.** Categories are per-user opt-outs with a missing row
--    meaning all-on, so a new category needs its own column to be declinable on its own.
--
-- `DAILY_PUSH_CAP` (3, in _shared/cadence.ts) is a **ceiling, not a target**. App Review 4.5.4
-- forbids push as a promotional channel and Apple can revoke push privileges for abuse, so each
-- slot picks from a priority chain of things that are actually true and sends nothing when the
-- chain comes up empty. An active player hits three without anything being manufactured.

alter table public.notification_settings
  add column if not exists engagement boolean not null default true;

comment on column public.notification_settings.engagement is
  'The midday "your move" nudge and the evening recap — the two slots added for the 3-a-day cadence.';

create table if not exists public.notification_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  category   text not null,
  -- The recipient's LOCAL day. Every send decision here is made in device-local time, so a cap
  -- counted in UTC days would let someone at UTC+13 collect two days' pushes in one evening.
  local_day  date not null,
  sent_at    timestamptz not null default now()
);

create index if not exists notification_log_user_day_idx
  on public.notification_log (user_id, local_day);
create unique index if not exists notification_log_once_per_day
  on public.notification_log (user_id, category, local_day);

alter table public.notification_log enable row level security;
drop policy if exists "notification_log own read" on public.notification_log;
create policy "notification_log own read" on public.notification_log
  for select using (auth.uid() = user_id);

-- Hourly; the function decides who is currently at 1pm/8pm locally. Uses
-- `public.edge_function_headers()` so the bearer token stays in Vault (see migration 0017),
-- unlike the older jobs in 0001/0002 which embed it literally.
select cron.unschedule('notify-engagement') where exists (
  select 1 from cron.job where jobname = 'notify-engagement');

select cron.schedule('notify-engagement', '0 * * * *', $job$
  select net.http_post(
    url := 'https://nhccgufqwndtoasdbkhc.supabase.co/functions/v1/notify-engagement',
    headers := public.edge_function_headers(),
    body := '{}'::jsonb);
$job$);
