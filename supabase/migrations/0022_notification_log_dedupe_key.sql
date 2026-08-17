-- 0022 — make `notification_log` able to hold the trigger-driven pushes too.
--
-- Migration 0018 built the log for the three SCHEDULED slots, where "once per category per
-- local day" is not merely a guard, it is the definition of the slot: there is one 9am, one
-- 1pm, one 8pm. So `notification_log_once_per_day (user_id, category, local_day)` could be
-- both the audit row and the idempotency guard for free.
--
-- Routing the three TRIGGER-driven functions (notify-versus-challenge, notify-versus-result,
-- notify-friend-request) through the same `sendOnce` breaks that assumption. Those categories
-- are inherently multi-per-day: two different people can challenge you on a Tuesday, and both
-- challenges are legitimate. Under the 0018 index the second one loses the insert race with
-- the FIRST one and is reported `already_sent` — a real duel silently never announced.
--
-- Confirmed live against nhccgufqwndtoasdbkhc before this migration, rather than assumed: a
-- re-insert of an existing (user_id, category, local_day) triple inside an aborted DO block
-- raised `unique_violation`. The index was, and had to remain, enforcing.
--
-- The fix keeps one index doing both jobs by giving it a fourth column that names the EVENT:
--
--   * scheduled slots pass no key      -> dedupe_key NULL -> unchanged, one per category per day
--   * trigger-driven pushes pass a key -> "challenge:42", "result:42", "friend:<uuid>"
--
-- `nulls not distinct` (Postgres 15+; this project is on 17.6) is what makes the NULL half keep
-- working — under the default NULLS DISTINCT every scheduled row would be unique against every
-- other and the 0018 guard would quietly evaporate, which is the trap in this change.
--
-- The key must be derived from the TRIGGERING ROW and nothing else, so it is stable across a
-- pg_net retry. Deriving it from mutable state (e.g. whether the duel had settled by the time
-- the function ran) would make a retry compute a different key and double-send — the exact
-- failure the guard exists to prevent.

alter table public.notification_log
  add column if not exists dedupe_key text;

comment on column public.notification_log.dedupe_key is
  'Names the event a trigger-driven push is answering ("challenge:42", "result:42", '
  '"friend:<requester uuid>"), so two legitimate same-day events of one category each get '
  'their own row and their own send. NULL for the scheduled slots, which are once-per-'
  'category-per-day by definition — see notification_log_once_per_event (nulls not distinct).';

-- Index-definition swap only: no rows are read, written or deleted by this migration, and it
-- is reversible by recreating the 0018 index verbatim (kept here so the rollback is one copy):
--   create unique index notification_log_once_per_day
--     on public.notification_log (user_id, category, local_day);
drop index if exists public.notification_log_once_per_day;

create unique index if not exists notification_log_once_per_event
  on public.notification_log (user_id, category, local_day, dedupe_key)
  nulls not distinct;
