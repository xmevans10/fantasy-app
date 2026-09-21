-- The automated growth engine's server-side state: the rotating X credentials and a posting
-- ledger. See tools/marketing/x_engine.py.
--
-- Why the credentials live here and not in GitHub Actions secrets: X rotates the OAuth2 refresh
-- token on every use, so any store a runner can only READ breaks the next run. GitHub secrets are
-- write-only from a workflow's point of view (and this environment has no management token to set
-- them anyway — the same constraint get_apns_config/get_app_store_config document). Supabase is
-- already a CI secret, so a table the service role can read AND write is the one place a rotating
-- value survives a scheduled run. `X_CLIENT_ID`/`X_CLIENT_SECRET` are static and are seeded here
-- too, so the engine needs no new repository secret at all.
--
-- Additive only, and RLS-enabled with no policies: service_role bypasses RLS, anon/authenticated
-- read nothing, so a leaked publishable key can neither read the secret nor forge a ledger row.

create table if not exists public.marketing_secrets (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

alter table public.marketing_secrets enable row level security;
-- No policies on purpose: service_role only.

-- The posting ledger. One row per tweet the engine has posted, so a re-run (a cron that fires
-- twice, a dispatch for a date already posted) is idempotent rather than a duplicate post. The
-- `id` is the engine's own key, `{date}:{kind}:{sport}:main` or `...:reply:{n}`, which is stable
-- across runs and independent of the tweet id X assigns.
create table if not exists public.marketing_posts (
  id         text primary key,
  platform   text not null default 'x',
  posted_at  timestamptz not null default now(),
  tweet_id   text,
  date       date,
  kind       text,
  sport      text
);

create index if not exists marketing_posts_date_idx on public.marketing_posts (date);

alter table public.marketing_posts enable row level security;
-- No policies on purpose: service_role only.

comment on table public.marketing_secrets is
  'Rotating credentials for the automated growth engine (x_client_id, x_client_secret, x_refresh_token). Service-role only.';
comment on table public.marketing_posts is
  'Idempotency ledger for the automated growth engine — one row per posted tweet, keyed by {date}:{kind}:{sport}:[{reply:n|reveal}]. Service-role only.';
