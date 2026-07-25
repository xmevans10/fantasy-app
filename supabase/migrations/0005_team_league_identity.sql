-- Data-driven team/league identity: teams + leagues tables + public team-logos bucket
-- Applied live 2026-07-22 via the Supabase MCP (prod migration `teams_and_leagues_identity_tables`); recorded
-- here after the fact so the repo's migration ledger matches production. Idempotent
-- (IF NOT EXISTS / duplicate-safe DO blocks), so re-running is a no-op — schema.sql
-- remains the source of truth (CLAUDE.md).

-- Data-driven club identity: logo (rehosted into the public `team-logos` Storage bucket) +
-- real colors + full name, keyed league-qualified so post-collision same-code clubs (BRO
-- Blackburn vs BROA Brisbane) stay distinct. Replaces the client's hardcoded 11-club soccer
-- maps; the Swift TeamColors / teamLogoURL tables remain only as the offline fallback.
-- Built by tools/ingest (--teams), logos rehosted via tools/ingest/logos.py.
create table if not exists public.teams (
  sport           text not null,   -- 'nfl' | 'nba' | 'baseball' | 'soccer' | 'tennis'
  team_abbr       text not null,
  league          text not null default '',  -- '' for single-league US sports; country label for soccer
  full_name       text,
  logo_url        text,            -- rehosted team-logos bucket URL (stable), null if none
  primary_color   text,            -- hex '#RRGGBB'
  secondary_color text,
  espn_id         text,            -- source id, for re-fetch/debug
  updated_at      timestamptz not null default now(),
  primary key (sport, team_abbr, league)
);
alter table public.teams enable row level security;
do $$ begin
  create policy "teams are world-readable" on public.teams for select using (true);
exception when duplicate_object then null;
end $$;
-- writes are service-role only (no insert/update/delete policy), same posture as player_seasons

-- League/competition identity: display name + rehosted logo. Small reference table (--leagues).
create table if not exists public.leagues (
  sport        text not null,
  league       text not null,   -- matches player_seasons.league / teams.league
  display_name text,            -- e.g. 'Premier League' for country label 'England'
  logo_url     text,
  updated_at   timestamptz not null default now(),
  primary key (sport, league)
);
alter table public.leagues enable row level security;
do $$ begin
  create policy "leagues are world-readable" on public.leagues for select using (true);
exception when duplicate_object then null;
end $$;

-- Public Storage bucket holding rehosted club/league logos (world-readable by design — logos
-- render in unauthenticated/guest sessions). Created idempotently so schema.sql stays runnable.
insert into storage.buckets (id, name, public)
values ('team-logos', 'team-logos', true)
on conflict (id) do update set public = true;
