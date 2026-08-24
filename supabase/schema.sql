-- BallIQ — Milestone 2 schema. Run this in the Supabase SQL editor.
-- Safe to re-run (idempotent-ish: uses IF NOT EXISTS; policies dropped+recreated).

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  username      text unique,
  avatar        text,
  primary_sport text,
  created_at    timestamptz not null default now()
);
-- One team per sport a user follows, e.g. {"nfl": "KC", "nba": "DEN"} — keyed by
-- Sport.rawValue, value is player_seasons.team_abbr. Powers the Profile team picker and
-- client-side "your team's in today's puzzle" badges (no dedicated teams catalog table).
alter table public.profiles add column if not exists favorite_teams jsonb not null default '{}'::jsonb;

-- one row per user per sport
create table if not exists public.ratings (
  user_id    uuid not null references auth.users(id) on delete cascade,
  sport      text not null,
  rating     int  not null default 1000,
  updated_at timestamptz not null default now(),
  primary key (user_id, sport)
);

create table if not exists public.rating_history (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  sport      text not null,
  rating     int  not null,
  created_at timestamptz not null default now()
);

-- one row per user
create table if not exists public.progress (
  user_id         uuid primary key references auth.users(id) on delete cascade,
  streak          int  not null default 0,
  xp              int  not null default 0,
  last_played_day text,
  updated_at      timestamptz not null default now()
);

-- world-readable daily content. `content` is the JSON of a Keep4Puzzle / WhoAmIPuzzle
-- (same shape the app's Codable models decode — see Models/Keep4Puzzle.swift, WhoAmIPuzzle.swift).
create table if not exists public.puzzles (
  id          text primary key,
  sport       text not null,                 -- 'nfl' | 'nba' | 'baseball' | 'soccer' | 'tennis'
  format      text not null,                 -- 'keep4' | 'whoami' | 'grid' | 'journeyman'
  content     jsonb not null,
  active_date date
);
-- Applied live 2026-07-27 (migration `0010_puzzles_lookup_indexes`). Until then this table had
-- nothing but its primary key, so every client fetch was a sequential scan — a precondition for
-- deepening the Grid pool, not an optimization (see the migration for the measured plans).
-- `id` trails the two equality columns so `order by id` (RemotePuzzleRepository.fetch's stable
-- ordering, which the modulo daily fallback depends on) is served by the index with no sort node.
create index if not exists puzzles_format_sport_id_idx
  on public.puzzles (format, sport, id);
-- The active_date lookup (notify-daily-drop) carries no sport predicate, so it can't ride the
-- index above — `sport` sits between the two columns it needs.
create index if not exists puzzles_format_active_date_idx
  on public.puzzles (format, active_date);

-- Every puzzle signature ever served by the daily novel-puzzle picker
-- (tools/ingest/daily_puzzle.py) — service-role-only, no client read needed. Guarantees the
-- picker never re-serves the same theme+player-set combo, no matter how the candidate pool
-- shifts day to day.
create table if not exists public.puzzle_history (
  signature   text primary key,   -- theme_key || '|' || sorted player ids
  theme_key   text not null,
  sport       text not null,
  format      text not null default 'keep4',
  puzzle_id   text not null,
  served_date date not null
);
-- One minted pick per calendar day PER SPORT: daily_puzzle.py's own pre-check
-- (fetch_served_pairs) is the primary defense, but that's a read-then-act check, not atomic
-- -- two concurrent/retried runs can both pass it before either writes. This constraint is
-- the hard backstop: it turns that race into a loud upsert failure instead of two puzzles
-- silently claiming the same day (exactly what happened once in production before this was
-- added -- see BALLIQ_SPEC.md). Originally (served_date, format) when only one sport minted
-- per night; widened to include sport when every sport gained its own daily mint. Wrapped in
-- a duplicate-safe DO block rather than a bare ALTER TABLE, which would fail outright if
-- pre-existing rows already violate it.
alter table public.puzzle_history
  drop constraint if exists puzzle_history_served_date_format_key;
do $$ begin
  alter table public.puzzle_history
    add constraint puzzle_history_served_date_sport_format_key unique (served_date, sport, format);
exception when duplicate_object then null;
end $$;
alter table public.puzzle_history enable row level security;
-- no policies -> service-role only

-- Who Am I's canonical-pick audit trail (tools/ingest/daily_whoami.py). The pool is a small
-- hand-authored set (whoami_facts.json), so the picker prefers the LEAST-RECENTLY-served
-- entry per sport rather than guaranteeing exact novelty like Keep4's signature check --
-- append-only history, one canonical pick per (day, sport).
create table if not exists public.whoami_history (
  id          bigint generated always as identity primary key,
  sport       text not null,
  player_key  text not null,     -- normalized canonical player name
  served_date date not null,
  puzzle_id   text not null
);
do $$ begin
  alter table public.whoami_history
    add constraint whoami_history_date_sport_key unique (served_date, sport);
exception when duplicate_object then null;
end $$;
alter table public.whoami_history enable row level security;
-- no policies -> service-role only

-- Journeyman's canonical-pick audit trail (tools/ingest/daily_journeyman.py) — identical
-- shape and posture to whoami_history: a finite pool rotated least-recently-served, one
-- canonical pick per (day, sport), the unique constraint doubling as the mint's idempotency
-- key. Applied live 2026-08-19 (migration 0018).
create table if not exists public.journeyman_history (
  id          bigint generated always as identity primary key,
  sport       text not null,
  player_key  text not null,     -- normalized canonical player name
  served_date date not null,
  puzzle_id   text not null
);
do $$ begin
  alter table public.journeyman_history
    add constraint journeyman_history_date_sport_key unique (served_date, sport);
exception when duplicate_object then null;
end $$;
alter table public.journeyman_history enable row level security;
-- no policies -> service-role only

-- Grid's lightweight novelty guard (tools/ingest/grid.py): records each day's minted
-- team-set x decade-set so the generator's retry loop can reject a combo served within a
-- trailing window. Deliberately NOT signature-level dedup -- Grid stays deterministic
-- per (sport, date), this just stops verbatim repeats.
create table if not exists public.grid_history (
  id          bigint generated always as identity primary key,
  sport       text not null,
  row_teams   text not null,     -- '|'-joined sorted team abbrs
  col_decades text not null,     -- '|'-joined sorted decade labels
  served_date date not null
);
do $$ begin
  alter table public.grid_history
    add constraint grid_history_date_sport_key unique (served_date, sport);
exception when duplicate_object then null;
end $$;
alter table public.grid_history enable row level security;
-- no policies -> service-role only

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
-- FIFA-style Nation -> League -> Club hierarchy (2026-07-26). `league` stays the COUNTRY label
-- that `teams`/`player_seasons` join on; `country`/`tier`/`espn_slug` add the competition layer
-- so a country can carry its whole division ladder (Bundesliga + 2. Bundesliga). The PK had to
-- widen to include `tier` for the same reason -- keyed (sport, league) a country could only ever
-- hold ONE competition, which is why lower divisions were unreachable.
alter table public.leagues add column if not exists country   text;
alter table public.leagues add column if not exists tier      int;
alter table public.leagues add column if not exists espn_slug text;
update public.leagues set tier = 1 where tier is null;
alter table public.leagues alter column tier set default 1;
alter table public.leagues alter column tier set not null;
do $$ begin
  alter table public.leagues drop constraint leagues_pkey;
exception when undefined_object then null;
end $$;
do $$ begin
  alter table public.leagues add constraint leagues_pkey primary key (sport, league, tier);
exception when duplicate_table or invalid_table_definition then null;
end $$;
create index if not exists leagues_country_tier_idx
  on public.leagues (sport, country, tier) where country is not null;

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

-- ─────────────────────────────────────────────────────────────────────────────
-- Row Level Security
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.profiles       enable row level security;
alter table public.ratings        enable row level security;
alter table public.rating_history enable row level security;
alter table public.progress       enable row level security;
alter table public.puzzles        enable row level security;

drop policy if exists "own profile"  on public.profiles;
drop policy if exists "own ratings"  on public.ratings;
drop policy if exists "own history"  on public.rating_history;
drop policy if exists "own progress" on public.progress;
drop policy if exists "puzzles readable" on public.puzzles;

-- users can only touch their own rows
create policy "own profile"  on public.profiles
  for all using (auth.uid() = id)      with check (auth.uid() = id);
create policy "own ratings"  on public.ratings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own history"  on public.rating_history
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own progress" on public.progress
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- puzzles are readable by everyone (including the anon key); writes are admin-only (no policy).
create policy "puzzles readable" on public.puzzles
  for select using (true);

-- Optional: auto-create a profile row when a user signs up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ═════════════════════════════════════════════════════════════════════════════
-- User-generated puzzles (Community). Safe to re-run.
-- ═════════════════════════════════════════════════════════════════════════════

-- Searchable real-stat catalog for Keep4 creation. Populated by tools/ingest
-- (`--catalog`); `stats` is the raw numeric stat dict (same keys grade.py reads).
create table if not exists public.player_seasons (
  id          text primary key,            -- e.g. 'nfl-derrick-henry-2020' — sport-prefixed
                                            -- since 2026-07-14 (see RawSeason.player_id):
                                            -- the bare 'name-year' form let two different real
                                            -- players sharing a name silently overwrite each
                                            -- other on upsert whenever their sports' seasons
                                            -- overlapped in year (confirmed: NFL RB Chris
                                            -- Johnson's 2009 season was clobbered by MLB's
                                            -- Chris Johnson under the old scheme).
  sport       text not null,               -- 'nfl' | 'nba'
  name        text not null,
  team_abbr   text not null,
  season_year int  not null,
  position    text not null,               -- 'WR','RB','QB' | 'G','F','C'
  stats       jsonb not null
);
-- Headshot parity (pre-M17 session fix) + career-grain rows (M17): a career row's
-- season_year holds the player's LAST season; first_year/last_year give the full span.
alter table public.player_seasons add column if not exists headshot   text not null default '';
alter table public.player_seasons add column if not exists career     boolean not null default false;
alter table public.player_seasons add column if not exists first_year int;
alter table public.player_seasons add column if not exists last_year  int;
-- Human-readable league/country label (e.g. 'England'), populated only for rows sourced
-- from providers/espn_soccer.py's ~38-country sweep; null for every other source/sport.
-- Powers Draft & Spin's "restrict spins to one league" setup filter.
alter table public.player_seasons add column if not exists league     text;
-- Single-game grain (single-game puzzle creation): a row with `week` set is one player's
-- one game, mirroring RawSeason.week/opponent/game_date. Null for every season/career row.
alter table public.player_seasons add column if not exists week       integer;
alter table public.player_seasons add column if not exists opponent   text;
alter table public.player_seasons add column if not exists game_date  text;
-- Draft & Spin lands on one real franchise season at a time. This keeps that narrow roster
-- lookup indexed as the catalog grows, rather than scanning every player in a sport/year.
create index if not exists player_seasons_roster_lookup_idx
  on public.player_seasons (sport, career, team_abbr, season_year);
-- The ingest pipeline's existing-id fetch pages by (sport = X, id > last, order by id,
-- limit N) — see tools/ingest/upsert.py fetch_existing_catalog_ids. Without this the plan
-- heap-filters the pk index or seq-scans + sorts the whole table, which began exceeding
-- the statement timeout (57014) once the table doubled past ~460k rows (2026-07-14).
create index if not exists player_seasons_sport_id_idx
  on public.player_seasons (sport, id);
-- The pipeline's "already stored but improvable" lookup (upsert.fetch_catalog_ids_missing)
-- pages by (sport = X, id > last) over rows whose headshot/competition are NULL/''. With
-- near-total coverage the filtered (sport, id) walk must traverse the whole partition to
-- find nothing — baseball headshots blew the statement timeout (57014) in CI 2026-08-01/03.
-- Partial indexes make the missing-set lookup an index-only scan of the tiny missing set,
-- in id order as the keyset needs. Applied live 2026-08-03 (migration 0014).
-- `upsert.fetch_player_seasons` pages by (sport = $1, [career = $2,] id > last, order by id).
-- `player_seasons_sport_id_idx` above serves the sport + keyset half but leaves `career` as a
-- filter: measured 2026-08-19, the FIRST page of the NFL career-grain fetch discarded 15,341
-- rows to return 1,000 and took 1.0s, and deeper pages walk proportionally more — the pull began
-- exceeding the statement timeout (57014) mid-run. (sport, career, id) matches the predicate and
-- leaves the keyset column last: index scan, no filter, no sort. 16,461 buffers -> 999.
-- Applied live (migration 0020).
create index if not exists player_seasons_sport_grain_id_idx
  on public.player_seasons (sport, career, id);
-- The guess typeahead's payload (`grid_player_names`, used by The Grid and Journeyman) is
-- `array_agg(distinct name order by name) where sport = $1 and not career`. With no index that
-- is a seq scan + sort of the whole table: fine under the SQL editor's timeout, 57014 under the
-- anon role's — so the RPC 500'd in production and the client's `try?` turned it into an empty
-- array, i.e. a typeahead that silently wasn't one. Measured live 2026-08-19: 500 before,
-- 200 in 0.3-3.0s after, across all five sports. Applied live (migration 0019).
create index if not exists player_seasons_sport_name_idx
  on public.player_seasons (sport, career, name);
create index if not exists player_seasons_missing_headshot_idx
  on public.player_seasons (sport, id)
  where headshot is null or headshot = '';
create index if not exists player_seasons_missing_competition_idx
  on public.player_seasons (sport, id)
  where competition is null or competition = '';

-- User-authored puzzles, kept separate from `puzzles` so the daily rotation stays
-- clean. `content` is the same camelCase Keep4Puzzle/WhoAmIPuzzle JSON the app decodes.
create table if not exists public.community_puzzles (
  id          text primary key,            -- short share code
  author_id   uuid not null references auth.users(id) on delete cascade,
  sport       text not null,               -- 'nfl' | 'nba'
  format      text not null,               -- 'keep4' | 'whoami'
  title       text not null,
  content     jsonb not null,
  visibility  text not null default 'public',   -- 'public' | 'unlisted' | 'hidden' (moderation)
  play_count  int  not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists community_puzzles_feed_idx
  on public.community_puzzles (format, sport, created_at desc);

-- One row per (puzzle, player). Drives the "Popular" sort; unique stops double-count.
create table if not exists public.community_plays (
  puzzle_id  text not null references public.community_puzzles(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (puzzle_id, user_id)
);

-- Lightweight moderation: anyone signed in can flag a puzzle; reviewed out-of-band.
create table if not exists public.community_reports (
  id         bigint generated always as identity primary key,
  puzzle_id  text not null references public.community_puzzles(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  reason     text,
  created_at timestamptz not null default now()
);

alter table public.player_seasons     enable row level security;
alter table public.community_puzzles  enable row level security;
alter table public.community_plays    enable row level security;
alter table public.community_reports  enable row level security;

drop policy if exists "player_seasons readable"  on public.player_seasons;
drop policy if exists "community readable"        on public.community_puzzles;
drop policy if exists "community insert own"      on public.community_puzzles;
drop policy if exists "community update own"      on public.community_puzzles;
drop policy if exists "community delete own"      on public.community_puzzles;
drop policy if exists "plays insert own"          on public.community_plays;
drop policy if exists "reports insert own"        on public.community_reports;

-- Catalog is world-readable; writes are admin-only (pipeline service_role, no policy).
create policy "player_seasons readable" on public.player_seasons
  for select using (true);

-- Community puzzles readable by everyone (feed filters visibility=public; unlisted
-- reachable by id via a share link). Writes are restricted to the author.
create policy "community readable" on public.community_puzzles
  for select using (true);
create policy "community insert own" on public.community_puzzles
  for insert with check (auth.uid() = author_id);
create policy "community update own" on public.community_puzzles
  for update using (auth.uid() = author_id) with check (auth.uid() = author_id);
create policy "community delete own" on public.community_puzzles
  for delete using (auth.uid() = author_id);

create policy "plays insert own" on public.community_plays
  for insert with check (auth.uid() = user_id);
create policy "reports insert own" on public.community_reports
  for insert with check (auth.uid() = reporter_id);

-- A logged play bumps the puzzle's play_count. SECURITY DEFINER so a player can
-- increment a row they don't own without a broad update policy.
create or replace function public.bump_play_count()
returns trigger language plpgsql security definer as $$
begin
  update public.community_puzzles
    set play_count = play_count + 1
    where id = new.puzzle_id;
  return new;
end;
$$;

drop trigger if exists on_community_play on public.community_plays;
create trigger on_community_play
  after insert on public.community_plays
  for each row execute function public.bump_play_count();

-- ═════════════════════════════════════════════════════════════════════════════
-- Milestone 12 — Trust & safety: auto-hide on report threshold + admin review.
-- Safe to re-run. Mirrored client-side by BallIQ/Models/ModerationPolicy.swift —
-- keep the threshold there in sync with `auto_hide_reported_puzzle` below.
-- ═════════════════════════════════════════════════════════════════════════════

-- Operator flag for the in-app review surface. Granting it is a manual, out-of-band
-- step: `update public.profiles set is_admin = true where id = '<operator uuid>';`
alter table public.profiles add column if not exists is_admin boolean not null default false;

-- Whether the caller is a moderator. SECURITY DEFINER so policies below can consult
-- `profiles` regardless of that table's own RLS.
create or replace function public.is_admin()
returns boolean language sql stable security definer as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false);
$$;

-- One report per user per puzzle: a single account can't cross the threshold alone,
-- and repeat taps don't inflate review-queue counts (the app's insert is best-effort,
-- so the conflict is swallowed silently client-side). Dedupe first so the unique
-- index can be created on a table that already collected repeat reports.
delete from public.community_reports a
  using public.community_reports b
  where a.puzzle_id = b.puzzle_id and a.reporter_id = b.reporter_id and a.id > b.id;
create unique index if not exists community_reports_one_per_user
  on public.community_reports (puzzle_id, reporter_id);

-- Auto-hide: once a puzzle has reports from >= 3 distinct users it leaves the public
-- feed (visibility -> 'hidden') but is NOT deleted — the author and admins can still
-- see it, and an admin can restore it. Only 'public' puzzles flip; 'unlisted' ones
-- aren't in the feed to begin with. SECURITY DEFINER because the reporter doesn't
-- own the puzzle row being updated.
create or replace function public.auto_hide_reported_puzzle()
returns trigger language plpgsql security definer as $$
declare
  reporters int;
begin
  select count(distinct reporter_id) into reporters
    from public.community_reports where puzzle_id = new.puzzle_id;
  if reporters >= 3 then
    update public.community_puzzles
      set visibility = 'hidden'
      where id = new.puzzle_id and visibility = 'public';
  end if;
  return new;
end;
$$;

drop trigger if exists on_community_report on public.community_reports;
create trigger on_community_report
  after insert on public.community_reports
  for each row execute function public.auto_hide_reported_puzzle();

-- Server-enforced hiding: replace the blanket read policy so 'hidden' puzzles are
-- invisible to everyone except their author and admins (share links included — the
-- feed's `visibility=eq.public` filter alone would leave direct-id loads open).
drop policy if exists "community readable" on public.community_puzzles;
create policy "community readable" on public.community_puzzles
  for select using (
    visibility <> 'hidden' or auth.uid() = author_id or public.is_admin()
  );

-- Review access: reporters can read back their own reports; admins read all
-- (the table was previously insert-only — nothing could review it).
drop policy if exists "reports readable by reporter or admin" on public.community_reports;
create policy "reports readable by reporter or admin" on public.community_reports
  for select using (auth.uid() = reporter_id or public.is_admin());

-- Admin moderation actions: restore/hide a puzzle (update), remove it outright
-- (delete), and clear a restored puzzle's reports so the very next report doesn't
-- instantly re-trip the threshold.
drop policy if exists "community admin update" on public.community_puzzles;
create policy "community admin update" on public.community_puzzles
  for update using (public.is_admin()) with check (public.is_admin());
drop policy if exists "community admin delete" on public.community_puzzles;
create policy "community admin delete" on public.community_puzzles
  for delete using (public.is_admin());
drop policy if exists "reports admin delete" on public.community_reports;
create policy "reports admin delete" on public.community_reports
  for delete using (public.is_admin());

-- ═════════════════════════════════════════════════════════════════════════════
-- Milestone 13 — Discovery: This-Week trending sort. Safe to re-run.
-- ═════════════════════════════════════════════════════════════════════════════

-- Aggregated 7-day play counts for the Community "This Week" sort. SECURITY DEFINER
-- because community_plays is insert-only under RLS — this exposes only (puzzle, count),
-- never who played what. Client: CommunityPuzzleRepository.weeklyPlayCounts(), which
-- falls back to recent ordering if this function isn't deployed yet.
create or replace function public.weekly_play_counts()
returns table (puzzle_id text, plays bigint)
language sql stable security definer as $$
  select puzzle_id, count(*)::bigint
    from public.community_plays
    where created_at > now() - interval '7 days'
    group by puzzle_id;
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- Milestone 15 — Analytics: first-party event pipeline. Safe to re-run.
-- Written by BallIQ/Backend/AnalyticsClient.swift; queried via docs/ANALYTICS.md.
-- ═════════════════════════════════════════════════════════════════════════════

-- Telemetry, not a social feature: insert-only from the API (no select policy —
-- reads happen in the SQL editor / service_role). `user_id` is nullable so
-- signed-out play still shows up in funnels; no PII beyond the auth user id.
create table if not exists public.events (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users(id) on delete set null,
  event_name text not null,
  properties jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists events_name_time_idx
  on public.events (event_name, created_at desc);

alter table public.events enable row level security;

drop policy if exists "events insert own" on public.events;
create policy "events insert own" on public.events
  for insert with check (user_id is null or auth.uid() = user_id);

-- ═════════════════════════════════════════════════════════════════════════════
-- Milestone 4 — Social retention: Leagues (weekly cohorts), Versus 1v1, Push.
-- Safe to re-run.
-- ═════════════════════════════════════════════════════════════════════════════

-- `profiles` was previously self-readable only; Leagues/Versus standings need to show
-- opponents' usernames/avatars. Widen to world-readable (matches `puzzles`/`community_puzzles`);
-- writes stay restricted to the owning row.
drop policy if exists "own profile" on public.profiles;
drop policy if exists "profiles readable"     on public.profiles;
drop policy if exists "profiles insert own"   on public.profiles;
drop policy if exists "profiles update own"   on public.profiles;
create policy "profiles readable" on public.profiles
  for select using (true);
create policy "profiles insert own" on public.profiles
  for insert with check (auth.uid() = id);
create policy "profiles update own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- One row per weekly cycle. Edge Function `weekly-cohort-rollover` opens the next season
-- and closes the previous one (pg_cron scheduling: supabase/migrations/0001_schedule_edge_functions.sql).
create table if not exists public.seasons (
  id         bigint generated always as identity primary key,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  status     text not null default 'active',     -- 'active' | 'closed'
  created_at timestamptz not null default now()
);

-- A cohort is ~30 players grouped at similar rating for one season. Cohorts are NOT
-- per-sport: grouping uses each player's best current rating (see RepositoryContainer's
-- `bestSport` pattern), since weekly XP itself is a single global counter.
create table if not exists public.cohorts (
  id         bigint generated always as identity primary key,
  season_id  bigint not null references public.seasons(id) on delete cascade,
  size_limit int not null default 30,
  created_at timestamptz not null default now()
);

-- One row per (cohort, member). `weekly_xp` resets to 0 every new cohort (new season);
-- it's separate from `progress.xp` (lifetime) and from `ratings.rating`. `joined_rating`
-- is a snapshot used only for the rollover's next-week bucketing, not displayed live.
-- `prior_zone` records last week's outcome for this player ('promoted'|'relegated'|'held'|null).
create table if not exists public.cohort_members (
  cohort_id    bigint not null references public.cohorts(id) on delete cascade,
  season_id    bigint not null references public.seasons(id) on delete cascade,
  user_id      uuid   not null references auth.users(id) on delete cascade,
  joined_rating int   not null,
  weekly_xp    int    not null default 0,
  prior_zone   text,
  joined_at    timestamptz not null default now(),
  primary key (cohort_id, user_id)
);
-- A player belongs to exactly one cohort per season.
create unique index if not exists cohort_members_one_per_season
  on public.cohort_members (season_id, user_id);
create index if not exists cohort_members_standings_idx
  on public.cohort_members (cohort_id, weekly_xp desc);

-- A 1-v1 head-to-head relationship between two players, raced to 4 wins.
-- `user_a`/`user_b` are stored with user_a < user_b (enforced by `create_versus_challenge`)
-- so a series is addressable regardless of who issued the latest duel.
create table if not exists public.versus_series (
  id         bigint generated always as identity primary key,
  user_a     uuid not null references auth.users(id) on delete cascade,
  user_b     uuid not null references auth.users(id) on delete cascade,
  sport      text not null,
  wins_a     int  not null default 0,
  wins_b     int  not null default 0,
  status     text not null default 'active',     -- 'active' | 'completed' (first to 4)
  created_at timestamptz not null default now(),
  constraint versus_series_ordered check (user_a < user_b)
);
-- 'keep4' | 'whoami' | 'grid' | 'journeyman' — the same domain as `puzzles.format`
-- (Swift: `PuzzleFormat`).
-- Added 2026-08-13 (migration 0015). Without it the uniqueness index below was
-- `(user_a, user_b, sport)`, so a Grid duel between two players who already had a Keep4 series
-- in the same sport silently collided with it.
alter table public.versus_series
  add column if not exists format text not null default 'keep4';
drop index if exists public.versus_series_pair_sport;
create unique index if not exists versus_series_pair_sport_format
  on public.versus_series (user_a, user_b, sport, format) where status = 'active';

-- One duel = one shared board played independently by both sides, each against their own clock.
-- `expires_at` is set 24h out at creation and bounds when the board must be *opened*;
-- `versus-timeout` (pg_cron scheduling: supabase/migrations/0001_schedule_edge_functions.sql)
-- forfeits anyone who hasn't completed by then.
create table if not exists public.versus_challenges (
  id                    bigint generated always as identity primary key,
  series_id             bigint not null references public.versus_series(id) on delete cascade,
  sport                 text not null,
  puzzle_id             text not null references public.puzzles(id),
  challenger_id         uuid not null references auth.users(id) on delete cascade,
  opponent_id           uuid not null references auth.users(id) on delete cascade,
  status                text not null default 'pending',
  challenger_score      double precision,
  opponent_score        double precision,
  challenger_completed_at timestamptz,
  opponent_completed_at   timestamptz,
  -- `on delete set null` matters: without it, deleting a user who has ever won a duel
  -- fails on this constraint and account deletion (Guideline 5.1.1(v)) breaks for exactly the
  -- most engaged users. See `delete_own_account()` at the end of this file.
  winner_id             uuid references auth.users(id) on delete set null,
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null default (now() + interval '24 hours')
);
create index if not exists versus_challenges_participant_idx
  on public.versus_challenges (challenger_id, opponent_id, status);

-- Timed duels (migration 0015). Each side's clock starts when *they* open the board, so an
-- asynchronously scheduled duel still carries synchronous pressure. `*_started_at` is written
-- server-side by `start_versus_challenge` and never reset — backgrounding the app, or force-
-- quitting it, buys no extra time.
alter table public.versus_challenges
  add column if not exists format text not null default 'keep4',
  add column if not exists time_limit_seconds int not null default 120,
  add column if not exists challenger_started_at timestamptz,
  add column if not exists opponent_started_at   timestamptz;

-- One open duel per series. `create_versus_challenge` returns the live one rather than
-- inserting a second; this is the hard guard behind that, and it closes a spam vector (the RPC
-- used to insert unconditionally, so N pending duels against the same person was one loop away).
create unique index if not exists versus_challenges_one_open_per_series
  on public.versus_challenges (series_id) where status = 'pending';

-- `'active'` was declared in the Swift model and branched on in two places but written by no
-- RPC, ever — and it was a latent trap, because `versus-timeout` sweeps `status='pending'` only,
-- so a row that ever landed in `'active'` would never have expired. Constrained so it can't
-- come back.
alter table public.versus_challenges drop constraint if exists versus_challenges_status_domain;
alter table public.versus_challenges add constraint versus_challenges_status_domain
  check (status in ('pending', 'completed', 'forfeited'));

-- Live duels (migration 0021, 2026-08-21). Until now every duel was asynchronous: both sides
-- played the same board alone within 24h and the higher `performance` won, so "first to solve
-- wins" was never literally true and the two players were never on the board together. A live
-- duel keeps the same row, the same series and the same first-to-4 maths — it changes only *when*
-- the row resolves, and adds the shared start instant that makes one clock serve both players.
--
-- Every column is additive and nullable-or-defaulted, so the duels that were in flight when this
-- landed stayed valid: `mode` defaults to 'async' and none of the async RPCs read any of them.
alter table public.versus_challenges
  add column if not exists mode                text not null default 'async',   -- 'async' | 'live'
  add column if not exists challenger_ready_at timestamptz,
  add column if not exists opponent_ready_at   timestamptz,
  add column if not exists live_started_at     timestamptz,   -- stamped once, on the second ready
  add column if not exists challenger_solved   boolean,
  add column if not exists opponent_solved     boolean,
  add column if not exists challenger_guesses  int,
  add column if not exists opponent_guesses    int;

-- `*_solved` is three-valued on purpose. NULL means "still on the board", which is what makes
-- `finished` a separate fact from `solved` on the wire: a player who burns all five guesses is
-- finished-and-not-solved and does NOT end the duel — the opponent can still take the point by
-- solving — whereas a player who hasn't answered is NULL and only the clock bounds them.
-- Collapsing the two into one boolean would make "out of guesses" indistinguishable from
-- "hasn't answered yet", and the draw rule in `submit_versus_live_result` is exactly the
-- difference between them.

-- Constrained for the same reason `versus_challenges_status_domain` above is: `'active'` proved
-- that a status-ish text column with no domain check acquires a third value nobody handles, and
-- then every sweep that filters on the known values skips those rows forever.
alter table public.versus_challenges drop constraint if exists versus_challenges_mode_domain;
alter table public.versus_challenges add constraint versus_challenges_mode_domain
  check (mode in ('async', 'live'));

-- Per-user push registration (a user may have several devices). `utc_offset_minutes` is the
-- device's local offset at registration time (no per-user timezone table yet) — used to
-- approximate "8pm local" for `notify-streak-risk` without a full tz database on the server.
create table if not exists public.device_tokens (
  user_id            uuid not null references auth.users(id) on delete cascade,
  token              text not null,
  platform           text not null default 'ios',
  utc_offset_minutes int  not null default 0,
  created_at         timestamptz not null default now(),
  primary key (user_id, token)
);

-- Which APNs host a token is valid on (migration 0023).
--
-- APNs runs two entirely separate environments and a token minted for one is meaningless on the
-- other. `_shared/apns.ts` hardcoded the production host, so every token registered by a debug or
-- simulator build was posted somewhere that had never heard of it: 100% of the pushes this app
-- ever attempted failed with BadDeviceToken, while the cadence layer above worked perfectly and
-- the failure looked like corrupt tokens.
--
-- The environment belongs to the TOKEN, not the server, so it is stored per row. Defaulting to
-- 'production' is right for App Store builds; a debug build corrects its own row on the next
-- registration upsert, so no back-fill guess is needed.
alter table public.device_tokens
  add column if not exists apns_environment text not null default 'production';
alter table public.device_tokens drop constraint if exists device_tokens_apns_env;
alter table public.device_tokens add constraint device_tokens_apns_env
  check (apns_environment in ('production', 'development'));

-- Per-category opt-out. Rows are created lazily (missing row = all categories on);
-- `notify-*` Edge Functions treat an absent row as all-true.
create table if not exists public.notification_settings (
  user_id          uuid primary key references auth.users(id) on delete cascade,
  streak_at_risk   boolean not null default true,
  league_position  boolean not null default true,
  versus_challenge boolean not null default true,
  season_end       boolean not null default true,
  updated_at       timestamptz not null default now()
);
-- "Today's puzzles just dropped" 9am-local push (notify-daily-drop, pg_cron scheduling:
-- supabase/migrations/0002_notify_daily_drop.sql).
alter table public.notification_settings
  add column if not exists daily_drop boolean not null default true;

-- The midday "your move" nudge and the evening recap — the two slots added 2026-08-13 to reach
-- a three-a-day cadence (migration 0018). See supabase/functions/_shared/cadence.ts for the
-- hard daily ceiling that governs all of them.
alter table public.notification_settings
  add column if not exists engagement boolean not null default true;

-- Every push actually sent, keyed by the RECIPIENT's local day. Two jobs in one table: it is the
-- audit trail (nothing recorded what had been sent to whom before this), and its unique index is
-- the idempotency guard that stops an hourly cron double-firing the same category.
create table if not exists public.notification_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  category   text not null,
  local_day  date not null,
  sent_at    timestamptz not null default now()
);

-- Names the event a trigger-driven push is answering (migration 0022), so the guard below can
-- tell "the second duel someone challenged you to today" from "the cron fired twice".
alter table public.notification_log
  add column if not exists dedupe_key text;

comment on column public.notification_log.dedupe_key is
  'Names the event a trigger-driven push is answering ("challenge:42", "result:42", "friend:<requester uuid>"), so two legitimate same-day events of one category each get their own row and their own send. NULL for the scheduled slots, which are once-per-category-per-day by definition — see notification_log_once_per_event (nulls not distinct).';

create index if not exists notification_log_user_day_idx
  on public.notification_log (user_id, local_day);

-- 0018's guard was (user_id, category, local_day), which was right while only the three SCHEDULED
-- slots were logged and wrong the moment the trigger-driven pushes joined them: the second
-- challenge you received in a day lost the insert race with the first and was reported
-- `already_sent` — a real duel never announced. Proven against production before the change, with
-- an aborted DO block that re-inserted an existing triple and got 23505.
--
-- `nulls not distinct` is load-bearing, not incidental: under the default `nulls distinct` every
-- scheduled row (dedupe_key NULL) would be unique against every other one and 0018's
-- double-fire guard would silently evaporate. Requires PG15+; the project is on 17.6.
drop index if exists public.notification_log_once_per_day;
create unique index if not exists notification_log_once_per_event
  on public.notification_log (user_id, category, local_day, dedupe_key)
  nulls not distinct;
alter table public.notification_log enable row level security;
drop policy if exists "notification_log own read" on public.notification_log;
create policy "notification_log own read" on public.notification_log
  for select using (auth.uid() = user_id);

alter table public.seasons              enable row level security;
alter table public.cohorts              enable row level security;
alter table public.cohort_members       enable row level security;
alter table public.versus_series        enable row level security;
alter table public.versus_challenges    enable row level security;
alter table public.device_tokens        enable row level security;
alter table public.notification_settings enable row level security;

drop policy if exists "seasons readable" on public.seasons;
drop policy if exists "cohorts readable" on public.cohorts;
drop policy if exists "cohort_members readable by cohort" on public.cohort_members;
drop policy if exists "versus_series readable by participant" on public.versus_series;
drop policy if exists "versus_challenges readable by participant" on public.versus_challenges;
drop policy if exists "versus_challenges insert by challenger" on public.versus_challenges;
drop policy if exists "device_tokens own" on public.device_tokens;
drop policy if exists "notification_settings own" on public.notification_settings;

-- Seasons/cohorts are world-readable scaffolding (no PII); standings come from cohort_members.
create policy "seasons readable" on public.seasons for select using (true);
create policy "cohorts readable" on public.cohorts for select using (true);

-- A player can see every row in their own cohort (pseudonymous standings), nothing else.
create policy "cohort_members readable by cohort" on public.cohort_members
  for select using (
    exists (
      select 1 from public.cohort_members me
      where me.cohort_id = cohort_members.cohort_id and me.user_id = auth.uid()
    )
  );
-- Writes go through `bump_weekly_xp` (SECURITY DEFINER) and the rollover Edge Function
-- (service_role), not direct client upserts — no insert/update policy for authenticated users.

-- A versus series/challenge is visible only to its two participants.
create policy "versus_series readable by participant" on public.versus_series
  for select using (auth.uid() = user_a or auth.uid() = user_b);
create policy "versus_challenges readable by participant" on public.versus_challenges
  for select using (auth.uid() = challenger_id or auth.uid() = opponent_id);
create policy "versus_challenges insert by challenger" on public.versus_challenges
  for insert with check (auth.uid() = challenger_id);
-- Score submission goes through `submit_versus_result` (SECURITY DEFINER) so a player can't
-- edit the opponent's score column; no update policy for authenticated users.

create policy "device_tokens own" on public.device_tokens
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "notification_settings own" on public.notification_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- RPCs (SECURITY DEFINER — let a player touch shared rows they don't directly own)
-- ─────────────────────────────────────────────────────────────────────────────

-- Adds `amount` to the caller's weekly_xp in their *current* (most recently joined) cohort.
-- Called from `RepositoryContainer.complete(...)` after a ranked game, alongside the existing
-- rating/progress push. No-op (returns false) if the caller isn't in an active cohort.
--
-- `amount` is a client claim — nothing about a daily completion is recorded server-side, so it
-- is clamped here rather than trusted (2026-07-27, applied live as migration
-- `clamp_bump_weekly_xp_and_harden_random_grid_puzzle`). Before the clamp, any signed-in user
-- could POST {"amount": 999999} to /rest/v1/rpc/bump_weekly_xp and top the weekly cohort board
-- without playing; a negative amount subtracted. Flooring at 0 means a bump can only ever add.
--
-- 1075 = the maximum of `RepositoryContainer.complete(...)`'s XP expression:
--   base 200 (`GameFormatKind.grid`, the richest baseXP)
--   + 75  perfect bonus
--   + 50  first play of the day
--   + 750 streak bonus (`min(streak, 30) * 25`, only on a first play)
-- Keep this in sync with `Progression.swift`'s `baseXP` table and `complete(...)`'s bonuses —
-- a client that legitimately earns more would be silently short-changed.
create or replace function public.bump_weekly_xp(amount int)
returns boolean language plpgsql security definer
set search_path = ''
as $$
declare
  updated boolean;
  award int := least(greatest(coalesce(amount, 0), 0), 1075);
begin
  update public.cohort_members cm
    set weekly_xp = weekly_xp + award
    where cm.user_id = auth.uid()
      and cm.cohort_id = (
        select cohort_id from public.cohort_members
        where user_id = auth.uid()
        order by joined_at desc limit 1
      )
  returning true into updated;
  return coalesce(updated, false);
end;
$$;

-- Versus RPCs. See supabase/migrations/0015_versus_timed_duels.sql for the change log.
--
-- The duel board is picked SERVER-side from the released archive, excluding anything either
-- side already has a `game_results` row for.
-- Old signature took `p_puzzle_id` from the client; drop it so no caller can pin a board.
drop function if exists public.create_versus_challenge(uuid, text, text);

create or replace function public.create_versus_challenge(
  p_opponent uuid,
  p_sport text,
  p_format text default 'keep4',
  p_time_limit int default 120)
returns bigint language plpgsql security definer as $$
declare
  me uuid := auth.uid();
  a uuid; b uuid;
  s_id bigint; ch_id bigint; pz text;
  limit_s int := least(greatest(coalesce(p_time_limit, 120), 30), 900);
begin
  if me is null or me = p_opponent then raise exception 'invalid opponent'; end if;
  -- Widened for Journeyman 2026-08-19 (migration 0018): `PuzzleFormat.allCases` drives the
  -- duel format picker, so a format the client offers must be a format this accepts.
  if p_format not in ('keep4', 'grid', 'whoami', 'journeyman') then raise exception 'unsupported format'; end if;
  a := least(me, p_opponent); b := greatest(me, p_opponent);

  select id into s_id from public.versus_series
    where user_a = a and user_b = b and sport = p_sport and format = p_format and status = 'active';
  if s_id is null then
    insert into public.versus_series (user_a, user_b, sport, format) values (a, b, p_sport, p_format)
      returning id into s_id;
  end if;

  -- Idempotent while a duel is open: re-challenging returns the live one rather than stacking
  -- a second. (The partial unique index above is the guard; this is the friendly path.)
  select id into ch_id from public.versus_challenges
    where series_id = s_id and status = 'pending' limit 1;
  if ch_id is not null then return ch_id; end if;

  -- The board comes from the *released archive* (strictly before today), never today's daily:
  -- pinning today's row is what let a player finish their daily, learn the answers, then
  -- challenge and replay with perfect knowledge. Excluding every puzzle either side has a
  -- `game_results` row for closes that for both players at once.
  select p.id into pz
  from public.puzzles p
  where p.format = p_format
    and p.sport = p_sport
    and p.active_date is not null
    and p.active_date < (now() at time zone 'utc')::date
    and not exists (
      select 1 from public.game_results g
      where g.puzzle_id = p.id and g.user_id in (me, p_opponent))
  order by random()
  limit 1;
  if pz is null then raise exception 'no unplayed puzzle available'; end if;

  insert into public.versus_challenges
      (series_id, sport, format, puzzle_id, challenger_id, opponent_id, time_limit_seconds)
    values (s_id, p_sport, p_format, pz, me, p_opponent, limit_s)
    returning id into ch_id;
  return ch_id;
end;
$$;

-- The clock starts when *this* player opens the board.
-- Returns seconds remaining, not a timestamp: the client never has to trust (or correct for)
-- its own clock, and a second call after a crash resumes the same countdown instead of
-- restarting it.
create or replace function public.start_versus_challenge(p_challenge_id bigint)
returns int language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  started timestamptz;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if auth.uid() not in (c.challenger_id, c.opponent_id) then raise exception 'not a participant'; end if;
  if c.status <> 'pending' then raise exception 'duel is closed'; end if;

  if auth.uid() = c.challenger_id then
    started := c.challenger_started_at;
    if started is null then
      update public.versus_challenges set challenger_started_at = now() where id = p_challenge_id
        returning challenger_started_at into started;
    end if;
  else
    started := c.opponent_started_at;
    if started is null then
      update public.versus_challenges set opponent_started_at = now() where id = p_challenge_id
        returning opponent_started_at into started;
    end if;
  end if;

  return greatest(0, ceil(c.time_limit_seconds - extract(epoch from (now() - started))))::int;
end;
$$;

-- Submit: first-write-wins, clamped to 0...1, validated against the server's own clock.
create or replace function public.submit_versus_result(p_challenge_id bigint, p_score double precision)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  is_challenger boolean;
  final_score double precision;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if auth.uid() not in (c.challenger_id, c.opponent_id) then
    raise exception 'not a participant';
  end if;

  is_challenger := auth.uid() = c.challenger_id;

  -- `p_score` is a client claim. Every mode's `performance` is 0...1, so anything outside that
  -- is either a bug or an attempt (cf. `bump_weekly_xp`'s clamp). This clamp is the only
  -- server-side judgement left on a submitted score.
  --
  -- M25 removed the lateness penalty that used to sit here: a run submitted past
  -- `time_limit_seconds + 10` scored 0. Timers are gone app-wide — a clock may GRADE a run (via
  -- `SpeedMultiplier`, which pays a bonus for finishing under par) but may never END one. A slow
  -- player now records their real score and simply earns no bonus. `time_limit_seconds` survives
  -- as that par time, not as a deadline.
  final_score := least(greatest(coalesce(p_score, 0), 0), 1);

  -- First write wins (mirrors `submit_daily_draft_score`): a replay, even a better one, can
  -- never overwrite the score already locked in.
  if is_challenger then
    update public.versus_challenges
      set challenger_score = coalesce(c.challenger_score, final_score),
          challenger_completed_at = coalesce(c.challenger_completed_at, now())
      where id = p_challenge_id;
  else
    update public.versus_challenges
      set opponent_score = coalesce(c.opponent_score, final_score),
          opponent_completed_at = coalesce(c.opponent_completed_at, now())
      where id = p_challenge_id;
  end if;

  select * into c from public.versus_challenges where id = p_challenge_id;
  if c.challenger_score is not null and c.opponent_score is not null and c.status = 'pending' then
    perform public.resolve_versus_challenge(p_challenge_id);
  end if;
end;
$$;

-- Resolution: a score tie is broken on elapsed time (not on who sent the duel), and the
-- series completes at first-to-4.
create or replace function public.resolve_versus_challenge(p_challenge_id bigint)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  winner uuid;
  new_status text;
  ch_secs double precision;
  op_secs double precision;
  inc_a int; inc_b int;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null or c.status <> 'pending' then return; end if;

  if c.challenger_score is not null and c.opponent_score is not null then
    new_status := 'completed';
    if c.challenger_score > c.opponent_score then
      winner := c.challenger_id;
    elsif c.opponent_score > c.challenger_score then
      winner := c.opponent_id;
    else
      -- Equal scores go to the faster run. `*_completed_at` was already being written and never
      -- read; awarding the tie to the challenger stacked a second structural edge on the first.
      ch_secs := extract(epoch from
        (c.challenger_completed_at - coalesce(c.challenger_started_at, c.created_at)));
      op_secs := extract(epoch from
        (c.opponent_completed_at - coalesce(c.opponent_started_at, c.created_at)));
      if ch_secs is not null and op_secs is not null and ch_secs <> op_secs then
        winner := case when ch_secs < op_secs then c.challenger_id else c.opponent_id end;
      else
        -- A genuine dead heat is a draw: `completed` with no winner. Distinct from `forfeited`,
        -- which stays reserved for the double no-show.
        winner := null;
      end if;
    end if;
  elsif c.challenger_score is not null then
    winner := c.challenger_id; new_status := 'completed';   -- opponent forfeited
  elsif c.opponent_score is not null then
    winner := c.opponent_id;   new_status := 'completed';   -- challenger forfeited
  else
    winner := null; new_status := 'forfeited';              -- double no-show, series unaffected
  end if;

  update public.versus_challenges
    set status = new_status, winner_id = winner
    where id = p_challenge_id;

  if winner is not null then
    update public.versus_series s
      set wins_a = s.wins_a + (case when winner = s.user_a then 1 else 0 end),
          wins_b = s.wins_b + (case when winner = s.user_b then 1 else 0 end),
          -- First to 4 takes it; a 4-0 lead no longer grinds three dead rubbers. The 7-played
          -- cap survives as a backstop, because draws advance neither counter.
          status = case
            when greatest(s.wins_a + (case when winner = s.user_a then 1 else 0 end),
                          s.wins_b + (case when winner = s.user_b then 1 else 0 end)) >= 4
              or s.wins_a + s.wins_b + 1 >= 7
            then 'completed' else s.status end
      where s.id = c.series_id;
  end if;
end;
$$;



-- ─────────────────────────────────────────────────────────────────────────────
-- Live duels (migration 0021) — "first to solve wins", Journeyman first.
-- Design + wire contract: prompts/M23-live-duels.md §§1-3. The async RPCs above are untouched;
-- these four are a parallel path, and a row only ever travels one of them.
-- ─────────────────────────────────────────────────────────────────────────────

-- The shared shape returned by both `mark_versus_ready` and `versus_live_state`. Kept in one
-- place so the two can never drift: the Swift `LiveDuelState` decoder is written against these
-- exact keys, and a duel where the ready-handshake response disagrees with the poll response
-- would desync the lobby from the board.
--
-- Guess *counts* cross the wire; guessed *names* never do. A wrong name is a hint — handing one
-- player the other's eliminations turns a race into a collaboration.
--
-- Timestamps go out as Postgres's own `timestamptz` rendering ("…+00:00", microsecond
-- precision). That is deliberate: `SupabaseDate.parse` (Backend/SupabaseClient.swift) already
-- tolerates exactly that form, and Foundation's plain `.iso8601` strategy — which rejects
-- fractional seconds — is not what decodes these.
create or replace function public.versus_live_payload(c public.versus_challenges, p_me uuid)
returns jsonb language plpgsql stable as $$
declare
  is_challenger boolean := (p_me = c.challenger_id);
  my_ready   timestamptz := case when is_challenger then c.challenger_ready_at else c.opponent_ready_at end;
  their_ready timestamptz := case when is_challenger then c.opponent_ready_at else c.challenger_ready_at end;
  my_solved   boolean := case when is_challenger then c.challenger_solved else c.opponent_solved end;
  their_solved boolean := case when is_challenger then c.opponent_solved else c.challenger_solved end;
  my_guesses   int := case when is_challenger then c.challenger_guesses else c.opponent_guesses end;
  their_guesses int := case when is_challenger then c.opponent_guesses else c.challenger_guesses end;
begin
  return jsonb_build_object(
    'mode', c.mode,
    'live_started_at', c.live_started_at,
    -- The client renders the countdown from (server_now, live_started_at, time_limit_seconds)
    -- rather than from its own clock, so a device with a skewed clock still sees the same
    -- remaining time as its opponent — the same reason `start_versus_challenge` returns seconds
    -- remaining instead of a timestamp.
    'server_now', now(),
    'time_limit_seconds', c.time_limit_seconds,
    'status', c.status,
    'winner_id', c.winner_id,
    'me', jsonb_build_object(
      'ready', my_ready is not null,
      'guesses', coalesce(my_guesses, 0),
      'finished', my_solved is not null,
      'solved', coalesce(my_solved, false)),
    'them', jsonb_build_object(
      'ready', their_ready is not null,
      'guesses', coalesce(their_guesses, 0),
      'finished', their_solved is not null,
      'solved', coalesce(their_solved, false)));
end;
$$;
-- Not a client-facing RPC: it takes the caller's identity as a parameter, so anyone who could
-- call it directly could ask for the row from the *other* player's point of view.
revoke all on function public.versus_live_payload(public.versus_challenges, uuid) from public, anon, authenticated;

-- Resolution for the live path. Deliberately NOT `resolve_versus_challenge`: that one derives the
-- winner from two submitted scores and cannot fire until both sides have finished, which is the
-- exact property a race must not have. The series maths below is copied from it verbatim —
-- first to 4 takes the series, 7 played is the backstop, draws advance neither counter — because
-- a live duel is worth exactly one series point, the same as an async one.
--
-- Idempotent and lock-guarded: the `status <> 'pending'` early-out under `for update` is what
-- makes two simultaneous solves produce one winner instead of two counter increments.
create or replace function public.resolve_versus_live_challenge(p_challenge_id bigint, p_winner uuid)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null or c.status <> 'pending' then return; end if;
  if p_winner is not null and p_winner not in (c.challenger_id, c.opponent_id) then
    raise exception 'winner is not a participant';
  end if;

  -- A draw is `completed` with a null winner, never `forfeited` — `forfeited` stays reserved for
  -- the double no-show so the two remain distinguishable in the history.
  update public.versus_challenges
    set status = 'completed', winner_id = p_winner
    where id = p_challenge_id;

  if p_winner is not null then
    update public.versus_series s
      set wins_a = s.wins_a + (case when p_winner = s.user_a then 1 else 0 end),
          wins_b = s.wins_b + (case when p_winner = s.user_b then 1 else 0 end),
          status = case
            when greatest(s.wins_a + (case when p_winner = s.user_a then 1 else 0 end),
                          s.wins_b + (case when p_winner = s.user_b then 1 else 0 end)) >= 4
              or s.wins_a + s.wins_b + 1 >= 7
            then 'completed' else s.status end
      where s.id = c.series_id;
  end if;
end;
$$;
-- Takes the winner as an argument, so it is service-side only: exposing it would let either
-- player POST themselves a series point.
revoke all on function public.resolve_versus_live_challenge(bigint, uuid) from public, anon, authenticated;

-- Ready handshake. Neither board opens until both sides are in, and the second ready stamps
-- `live_started_at` — ONE shared start instant for both players, so the countdown is identical
-- on both devices and a slow network buys nobody a head start.
--
-- `for update` is doing real work here: two players hitting READY in the same instant serialize
-- on the row lock, so the second call is the only one that ever sees both `*_ready_at` set, and
-- `live_started_at` is written exactly once. The `is null` predicate on the update is the belt to
-- that braces.
--
-- Marking ready is also what flips `mode` to 'live'. `create_versus_challenge` has no mode
-- argument on purpose: adding one would have meant dropping and recreating the function that the
-- shipping app calls to create every duel, and readiness is unambiguous — nothing but a live duel
-- ever asks for it.
create or replace function public.mark_versus_ready(p_challenge_id bigint)
returns jsonb language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  me uuid := auth.uid();
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if me not in (c.challenger_id, c.opponent_id) then raise exception 'not a participant'; end if;

  -- Readying a duel that already resolved is a no-op rather than an error: the loser's client
  -- can have a READY tap in flight at the moment the winner's solve lands, and failing it would
  -- surface as an error alert on top of the verdict they are about to be shown.
  if c.status = 'pending' then
    update public.versus_challenges
      set mode = 'live',
          -- First write wins per side: re-readying after a reconnect must not restart anything.
          challenger_ready_at = case when me = c.challenger_id
            then coalesce(c.challenger_ready_at, now()) else c.challenger_ready_at end,
          opponent_ready_at = case when me = c.opponent_id
            then coalesce(c.opponent_ready_at, now()) else c.opponent_ready_at end
      where id = p_challenge_id
      returning * into c;

    if c.challenger_ready_at is not null and c.opponent_ready_at is not null then
      update public.versus_challenges
        set live_started_at = now()
        where id = p_challenge_id and live_started_at is null
        returning * into c;
      if c.id is null then
        select * into c from public.versus_challenges where id = p_challenge_id;
      end if;
    end if;
  end if;

  return public.versus_live_payload(c, me);
end;
$$;
revoke all on function public.mark_versus_ready(bigint) from public, anon;
grant execute on function public.mark_versus_ready(bigint) to authenticated, service_role;

-- The poll (1.5s, two clients, one ~120-byte row — see prompts/M23-live-duels.md §2 for why this
-- is cheaper than the websocket dependency the app has spent its whole life avoiding).
--
-- It is also the liveness detector, which is why a read function writes: if the clock runs out
-- with nobody having solved, whichever client is still polling resolves the duel to a draw. A
-- client that has backgrounded or died therefore cannot hold a duel open, and nothing about the
-- outcome depends on a client staying alive. (`versus-timeout`'s 24h sweep is the last backstop
-- for the case where *both* clients are gone.)
create or replace function public.versus_live_state(p_challenge_id bigint)
returns jsonb language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  me uuid := auth.uid();
  my_result boolean;
  their_result boolean;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if me not in (c.challenger_id, c.opponent_id) then raise exception 'not a participant'; end if;

  my_result    := case when me = c.challenger_id then c.challenger_solved else c.opponent_solved end;
  their_result := case when me = c.challenger_id then c.opponent_solved else c.challenger_solved end;

  -- **Abandonment, not a deadline** (M25). This used to draw the duel the moment
  -- `time_limit_seconds + 10` elapsed, which is a gameplay timer wearing a server's clothes — a
  -- player still reading the board lost it to the clock. Timers are gone: a clock may GRADE a run
  -- (`SpeedMultiplier`) but never end one.
  --
  -- What survives is the narrow case something still has to close: **I finished and they never
  -- did.** Fifteen minutes is long enough that nobody racing is caught by it and short enough
  -- that a series does not stall forever behind a player who walked away. It cannot fire while
  -- both sides are still playing, because `my_result` would be null.
  if c.mode = 'live' and c.status = 'pending' and c.live_started_at is not null
     and my_result is not null and their_result is null
     and now() - c.live_started_at > interval '15 minutes' then
    perform public.resolve_versus_live_challenge(p_challenge_id, null);
    select * into c from public.versus_challenges where id = p_challenge_id;
  end if;

  return public.versus_live_payload(c, me);
end;
$$;
revoke all on function public.versus_live_state(bigint) from public, anon;
grant execute on function public.versus_live_state(bigint) to authenticated, service_role;

-- Progress ping. The opponent's strip ticking up in real time is the whole reason this is a live
-- duel and not an async one with extra steps — without it neither player can tell whether the
-- other is closing in, and the race has no tension.
--
-- Monotonic (`greatest`) because the poll and the ping race each other over a lossy network: a
-- retried or reordered ping must never walk a count backwards on the opponent's screen.
create or replace function public.bump_versus_guesses(p_challenge_id bigint, p_guesses int)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  is_challenger boolean;
  n int := least(greatest(coalesce(p_guesses, 0), 0), 99);
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if auth.uid() not in (c.challenger_id, c.opponent_id) then raise exception 'not a participant'; end if;
  -- Silent no-op once the duel is over, or once this side has finished: a guess ping is fire-and-
  -- forget from the client's point of view, and the one in flight when the opponent solves must
  -- not fail loudly on a board that is already showing a verdict.
  if c.status <> 'pending' then return; end if;

  is_challenger := auth.uid() = c.challenger_id;
  if is_challenger then
    if c.challenger_solved is not null then return; end if;
    update public.versus_challenges
      set challenger_guesses = greatest(coalesce(c.challenger_guesses, 0), n)
      where id = p_challenge_id;
  else
    if c.opponent_solved is not null then return; end if;
    update public.versus_challenges
      set opponent_guesses = greatest(coalesce(c.opponent_guesses, 0), n)
      where id = p_challenge_id;
  end if;
end;
$$;
revoke all on function public.bump_versus_guesses(bigint, int) from public, anon;
grant execute on function public.bump_versus_guesses(bigint, int) to authenticated, service_role;

-- Finish. This is where "first to solve wins" actually lives:
--
--   * a correct solve resolves the whole challenge on the spot — status, winner, series counter —
--     without waiting for the opponent, who is beaten the moment their next poll returns;
--   * a finisher who did NOT solve (five burned, or gave up) resolves nothing: they are out, but
--     the duel stays open and the opponent can still take the point by solving;
--   * both finished without a solve → draw, exactly like the existing dead-heat rule: completed,
--     no winner, neither series counter moves.
--
-- The clock is server-authoritative, with the same +10s network grace and the same reasoning as
-- `submit_versus_result`: a late solve is scored as *not solved* rather than rejected, because a
-- rejected submit leaves the duel open and stalling would become a strategy.
create or replace function public.submit_versus_live_result(
  p_challenge_id bigint,
  p_solved boolean,
  p_guesses int)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  me uuid := auth.uid();
  is_challenger boolean;
  solved boolean := coalesce(p_solved, false);
  n int := least(greatest(coalesce(p_guesses, 0), 0), 99);
  recorded boolean;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if me not in (c.challenger_id, c.opponent_id) then raise exception 'not a participant'; end if;
  is_challenger := (me = c.challenger_id);

  -- M25 removed the lateness downgrade that stood here: a solve arriving past
  -- `time_limit_seconds + 10` was rewritten to not-solved, so a player who named the right person
  -- was recorded as having failed. A solve is a solve. Slow costs the speed bonus, nothing else.

  -- First write wins per side (mirrors `submit_versus_result`): a replay, a retry, or a second
  -- tab can never overwrite the result already locked in for this player.
  if is_challenger then
    if c.challenger_solved is null then
      update public.versus_challenges
        set challenger_solved = solved,
            challenger_guesses = greatest(coalesce(c.challenger_guesses, 0), n),
            challenger_completed_at = coalesce(c.challenger_completed_at, now())
        where id = p_challenge_id;
    end if;
  else
    if c.opponent_solved is null then
      update public.versus_challenges
        set opponent_solved = solved,
            opponent_guesses = greatest(coalesce(c.opponent_guesses, 0), n),
            opponent_completed_at = coalesce(c.opponent_completed_at, now())
        where id = p_challenge_id;
    end if;
  end if;

  select * into c from public.versus_challenges where id = p_challenge_id;
  -- Resolve off the STORED value, never off `solved`: a second submit claiming a solve after this
  -- side already reported a miss has to lose to the first write, or first-write-wins is theatre.
  recorded := case when is_challenger then c.challenger_solved else c.opponent_solved end;

  if c.status = 'pending' then
    if coalesce(recorded, false) then
      perform public.resolve_versus_live_challenge(p_challenge_id, me);
    elsif c.challenger_solved is not null and c.opponent_solved is not null then
      -- Both out, neither solved. (Not reachable with a solve on either side: that resolved the
      -- row when it arrived, so `status` would not still be 'pending'.)
      perform public.resolve_versus_live_challenge(p_challenge_id, null);
    end if;
  end if;
end;
$$;
revoke all on function public.submit_versus_live_result(bigint, boolean, int) from public, anon;
grant execute on function public.submit_versus_live_result(bigint, boolean, int) to authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- Daily Draft (Draft & Spin's daily seeded mode) — one official score per user per UTC day
-- ─────────────────────────────────────────────────────────────────────────────

-- Server-side first-write-wins mirrors the client's DailyDraftStore.recordIfFirst — a replay
-- (even a better one) can never overwrite the locked-in official run.
create table if not exists public.daily_draft_scores (
  user_id      uuid not null references auth.users(id) on delete cascade,
  day          date not null,
  sport        text not null,
  wins         int  not null check (wins >= 0),
  losses       int  not null check (losses >= 0),
  total_points int  not null,
  outcome      text not null,
  created_at   timestamptz not null default now(),
  primary key (user_id, day)
);
create index if not exists daily_draft_scores_day_idx
  on public.daily_draft_scores (day, wins desc, total_points desc);

alter table public.daily_draft_scores enable row level security;

drop policy if exists "daily_draft_scores readable" on public.daily_draft_scores;
-- The daily leaderboard is public content (pseudonymous, like cohort standings); ranked
-- output should come from the daily_draft_leaderboard RPC, but plain reads are harmless.
create policy "daily_draft_scores readable" on public.daily_draft_scores
  for select using (true);
-- Writes only via submit_daily_draft_score (SECURITY DEFINER) — no insert/update policy.

-- Records the caller's official Daily Draft score for `p_day` iff none exists yet.
-- Returns whether this call became the official score (false = already locked in).
-- No future days; past days are allowed so an offline run can retry on a later launch.
create or replace function public.submit_daily_draft_score(
  p_day date, p_sport text, p_wins int, p_losses int, p_total_points int, p_outcome text)
returns boolean language plpgsql security definer as $$
declare
  inserted boolean;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_day > (now() at time zone 'utc')::date then raise exception 'future day'; end if;
  insert into public.daily_draft_scores (user_id, day, sport, wins, losses, total_points, outcome)
    values (auth.uid(), p_day, p_sport, p_wins, p_losses, p_total_points, p_outcome)
    on conflict (user_id, day) do nothing
    returning true into inserted;
  return coalesce(inserted, false);
end;
$$;

-- Top-50 rows for a day plus the caller's own row (rank included) even when outside the top 50.
create or replace function public.daily_draft_leaderboard(p_day date)
returns table (
  rank bigint, user_id uuid, username text, avatar text, sport text,
  wins int, losses int, total_points int, outcome text, is_me boolean
) language sql security definer stable as $$
  with ranked as (
    select s.*,
           row_number() over (order by s.wins desc, s.total_points desc, s.created_at asc) as rnk
    from public.daily_draft_scores s
    where s.day = p_day
  )
  select r.rnk, r.user_id, p.username, p.avatar, r.sport,
         r.wins, r.losses, r.total_points, r.outcome,
         coalesce(r.user_id = auth.uid(), false)
  from ranked r
  left join public.profiles p on p.id = r.user_id
  where r.rnk <= 50 or r.user_id = auth.uid()
  order by r.rnk;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Arcade leaderboards (backlog #5) — weekly boards per sport for Over/Under + Grid
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per finished run (like `events`, insert-only); the board ranks each user's
-- best score of the UTC week. week_start is server-authoritative: the column default
-- computes it and the insert policy rejects any other value, so a client can't post
-- into a past or future week.
create table if not exists public.arcade_scores (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  game       text not null check (game in ('over_under', 'grid')),
  sport      text not null,
  score      int  not null check (score >= 0),
  week_start date not null default (date_trunc('week', now() at time zone 'utc'))::date,
  created_at timestamptz not null default now()
);
create index if not exists arcade_scores_board_idx
  on public.arcade_scores (game, sport, week_start, score desc);

alter table public.arcade_scores enable row level security;

drop policy if exists "arcade_scores readable" on public.arcade_scores;
-- Public pseudonymous content, same stance as daily_draft_scores: ranked output should
-- come from the arcade_leaderboard RPC, but plain reads are harmless.
create policy "arcade_scores readable" on public.arcade_scores
  for select using (true);

drop policy if exists "arcade_scores insert own" on public.arcade_scores;
create policy "arcade_scores insert own" on public.arcade_scores
  for insert with check (
    auth.uid() = user_id
    and week_start = (date_trunc('week', now() at time zone 'utc'))::date
  );
-- No update/delete policies: rows are immutable once posted.

-- Top-50 weekly board for one game+sport, plus the caller's own row (true rank included)
-- even when outside the top 50 — mirrors daily_draft_leaderboard. p_week null = current
-- UTC week. Best score per user; ties broken by who reached that score first.
create or replace function public.arcade_leaderboard(
  p_game text, p_sport text, p_week date default null)
returns table (
  rank bigint, user_id uuid, username text, avatar text,
  best_score int, is_me boolean
) language sql security definer stable as $$
  with wk as (
    select coalesce(p_week, (date_trunc('week', now() at time zone 'utc'))::date) as w
  ),
  best as (
    select distinct on (s.user_id) s.user_id, s.score as best_score, s.created_at
    from public.arcade_scores s, wk
    where s.game = p_game and s.sport = p_sport and s.week_start = wk.w
    order by s.user_id, s.score desc, s.created_at asc
  ),
  ranked as (
    select b.*, row_number() over (order by b.best_score desc, b.created_at asc) as rnk
    from best b
  )
  select r.rnk, r.user_id, p.username, p.avatar, r.best_score,
         coalesce(r.user_id = auth.uid(), false)
  from ranked r
  left join public.profiles p on p.id = r.user_id
  where r.rnk <= 50 or r.user_id = auth.uid()
  order by r.rnk;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- M5 Phase F — rating seasons (8-week competitive ladder, roadmap v1.4)
-- ─────────────────────────────────────────────────────────────────────────────
-- Distinct from the weekly `seasons` table (that is the XP-league rollover): this is the
-- rating ladder. All-time rating stays permanent; each season is a fresh parallel ladder
-- seeded from a soft-reset snapshot, so a server reset never fights the client's max-merge.

-- One row per 8-week cycle. `rating-season-rollover` closes the active row and opens the
-- next (starts_at = prev.ends_at, ends_at = starts_at + 8 weeks). Exactly one 'active' row.
create table if not exists public.rating_seasons (
  id         bigint generated always as identity primary key,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  status     text not null default 'active',   -- 'active' | 'closed'
  created_at timestamptz not null default now()
);
create unique index if not exists rating_seasons_one_active
  on public.rating_seasons (status) where status = 'active';

alter table public.rating_seasons enable row level security;
drop policy if exists "rating_seasons readable" on public.rating_seasons;
create policy "rating_seasons readable" on public.rating_seasons
  for select using (true);
-- No client writes: opened/closed only by the rollover Edge Function (service_role).

-- Per (season, user, sport) mirror of the client-computed season rating. The ladder reuses
-- the same Elo engine as the all-time rating, seeded fresh each season from a soft-reset
-- snapshot, so a season row is authoritative on its own (no max-merge like `ratings`): a
-- client only ever writes its *current* season's row (RLS pins season_id to the active one).
-- `peak_rating` is the high-water mark used for the end-of-season badge.
create table if not exists public.season_ratings (
  season_id   bigint not null references public.rating_seasons(id) on delete cascade,
  user_id     uuid   not null references auth.users(id) on delete cascade,
  sport       text   not null,
  rating      int    not null default 1000,
  peak_rating int    not null default 1000,
  updated_at  timestamptz not null default now(),
  primary key (season_id, user_id, sport)
);
create index if not exists season_ratings_board_idx
  on public.season_ratings (season_id, sport, rating desc);

alter table public.season_ratings enable row level security;
drop policy if exists "season_ratings readable" on public.season_ratings;
create policy "season_ratings readable" on public.season_ratings
  for select using (true);
drop policy if exists "season_ratings insert own current" on public.season_ratings;
create policy "season_ratings insert own current" on public.season_ratings
  for insert with check (
    auth.uid() = user_id
    and season_id = (select id from public.rating_seasons where status = 'active')
  );
drop policy if exists "season_ratings update own current" on public.season_ratings;
create policy "season_ratings update own current" on public.season_ratings
  for update using (
    auth.uid() = user_id
    and season_id = (select id from public.rating_seasons where status = 'active')
  ) with check (auth.uid() = user_id);
-- No delete policy: season rows are retained for history.

-- End-of-season cosmetic reward: the peak tier reached that season. Written only by the
-- rollover Edge Function (service_role) when a season closes. World-readable (like ratings)
-- so badges can surface on public profiles too.
create table if not exists public.season_badges (
  season_id   bigint not null references public.rating_seasons(id) on delete cascade,
  user_id     uuid   not null references auth.users(id) on delete cascade,
  sport       text   not null,
  peak_tier   text   not null,   -- bronze|silver|gold|platinum|diamond|legend
  peak_rating int    not null,
  created_at  timestamptz not null default now(),
  primary key (season_id, user_id, sport)
);
create index if not exists season_badges_user_idx
  on public.season_badges (user_id, created_at desc);

alter table public.season_badges enable row level security;
drop policy if exists "season_badges readable" on public.season_badges;
create policy "season_badges readable" on public.season_badges
  for select using (true);
-- No client writes — rollover (service_role) only.

-- The active season, for the client to seed against (mirrors notify-season-end's read shape).
create or replace function public.current_rating_season()
returns table (id bigint, starts_at timestamptz, ends_at timestamptz, status text)
language sql security definer stable as $$
  select id, starts_at, ends_at, status
  from public.rating_seasons
  where status = 'active'
  order by starts_at desc
  limit 1;
$$;

-- Top-50 board for one sport in one season, plus the caller's own row even when outside the
-- top 50 — mirrors arcade_leaderboard/daily_draft_leaderboard. p_season null = active season.
create or replace function public.season_leaderboard(
  p_sport text, p_season bigint default null)
returns table (
  rank bigint, user_id uuid, username text, avatar text,
  rating int, peak_rating int, is_me boolean
) language sql security definer stable as $$
  with sn as (
    select coalesce(
      p_season,
      (select id from public.rating_seasons where status = 'active' order by starts_at desc limit 1)
    ) as s
  ),
  ranked as (
    select sr.user_id, sr.rating, sr.peak_rating,
           row_number() over (order by sr.rating desc, sr.updated_at asc) as rnk
    from public.season_ratings sr, sn
    where sr.season_id = sn.s and sr.sport = p_sport
  )
  select r.rnk, r.user_id, p.username, p.avatar, r.rating, r.peak_rating,
         coalesce(r.user_id = auth.uid(), false)
  from ranked r
  left join public.profiles p on p.id = r.user_id
  where r.rnk <= 50 or r.user_id = auth.uid()
  order by r.rnk;
$$;

-- Bootstrap the first active season if none exists (8 weeks from now).
insert into public.rating_seasons (starts_at, ends_at, status)
select now(), now() + interval '8 weeks', 'active'
where not exists (select 1 from public.rating_seasons where status = 'active');

-- ─────────────────────────────────────────────────────────────────────────────
-- M5 monetization (StoreKit 2 entitlements)
-- ─────────────────────────────────────────────────────────────────────────────

-- Server-verified entitlement state, one row per (user, product). Written only by the
-- `app-store-notifications` Edge Function (service_role) after verifying Apple's signed
-- payload — never directly by the client. The client's on-device `Transaction
-- .currentEntitlements` read (`StoreService`) is the instant-UX path; this table is the
-- belt-and-suspenders source of truth that syncs Pro state across devices/reinstalls.
create table if not exists public.entitlements (
  user_id                 uuid not null references auth.users(id) on delete cascade,
  product_id              text not null,
  status                  text not null default 'active',  -- 'active' | 'expired' | 'revoked'
  original_transaction_id text not null,
  expires_at              timestamptz,   -- null for non-consumable packs (never expire)
  updated_at              timestamptz not null default now(),
  primary key (user_id, product_id)
);
create index if not exists entitlements_original_transaction_idx
  on public.entitlements (original_transaction_id);

alter table public.entitlements enable row level security;
drop policy if exists "entitlements own read" on public.entitlements;
create policy "entitlements own read" on public.entitlements
  for select using (auth.uid() = user_id);
-- No insert/update/delete policy for authenticated users — writes are service_role-only
-- (`app-store-notifications`), so a client can never grant itself an entitlement.

-- ─────────────────────────────────────────────────────────────────────────────
-- M19 social layer (friends graph + public profiles)
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per friendship edge; requester sends, addressee accepts. A declined request is
-- simply deleted (so it can be re-sent later). The least/greatest unique index blocks a
-- reverse-direction duplicate edge (A->B and B->A can't both exist).
create table if not exists public.friends (
  requester_id uuid not null references auth.users(id) on delete cascade,
  addressee_id uuid not null references auth.users(id) on delete cascade,
  status       text not null default 'pending',   -- 'pending' | 'accepted'
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  primary key (requester_id, addressee_id),
  constraint friends_not_self check (requester_id <> addressee_id),
  constraint friends_status_valid check (status in ('pending','accepted'))
);
create unique index if not exists friends_unique_pair
  on public.friends (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index if not exists friends_addressee_idx on public.friends (addressee_id, status);

alter table public.friends enable row level security;
drop policy if exists "friends visible to participants" on public.friends;
create policy "friends visible to participants" on public.friends
  for select using (auth.uid() = requester_id or auth.uid() = addressee_id);
drop policy if exists "friends request own" on public.friends;
create policy "friends request own" on public.friends
  for insert with check (auth.uid() = requester_id and status = 'pending');
drop policy if exists "friends respond own" on public.friends;
create policy "friends respond own" on public.friends
  for update using (auth.uid() = addressee_id) with check (auth.uid() = addressee_id);
drop policy if exists "friends delete own" on public.friends;
create policy "friends delete own" on public.friends
  for delete using (auth.uid() = requester_id or auth.uid() = addressee_id);

-- Public-profile read: ratings/progress are own-only by RLS (correctly), so expose a
-- deliberately-limited projection for viewing another player's profile. Everything here is
-- leaderboard-grade data (username, avatar, per-sport ratings, streak, xp) — no email, no
-- entitlements, no notification settings.
create or replace function public.public_profile(target uuid)
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select jsonb_build_object(
    'id', p.id,
    'username', p.username,
    'avatar', p.avatar,
    'created_at', p.created_at,
    'streak', coalesce(pr.streak, 0),
    'xp', coalesce(pr.xp, 0),
    'ratings', coalesce(
      (select jsonb_object_agg(r.sport, r.rating) from public.ratings r where r.user_id = p.id),
      '{}'::jsonb)
  )
  from public.profiles p
  left join public.progress pr on pr.user_id = p.id
  where p.id = target;
$$;

-- The app's PostgREST wrapper only speaks select/insert/upsert/rpc (no PATCH/DELETE), so
-- responding to and removing friend edges go through RPCs. SECURITY INVOKER on purpose:
-- the friends RLS policies (addressee may update, either participant may delete) are the
-- authorization layer; these functions add no privilege.

create or replace function public.respond_friend_request(p_requester uuid, p_accept boolean)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if p_accept then
    update public.friends
       set status = 'accepted', responded_at = now()
     where requester_id = p_requester and addressee_id = auth.uid() and status = 'pending';
  else
    delete from public.friends
     where requester_id = p_requester and addressee_id = auth.uid() and status = 'pending';
  end if;
end;
$$;

create or replace function public.remove_friend(p_other uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  delete from public.friends
   where (requester_id = auth.uid() and addressee_id = p_other)
      or (requester_id = p_other and addressee_id = auth.uid());
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- M20 social follow-through (friends leaderboard + friend-request push)
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.notification_settings
  add column if not exists friend_request boolean not null default true;

-- All accepted friends of the caller as public_profile projections, one round trip —
-- powers the FRIENDS leaderboard scope without N per-friend RPC calls.
create or replace function public.friend_profiles()
returns jsonb
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(jsonb_agg(public.public_profile(f.other)), '[]'::jsonb)
  from (
    select case when requester_id = auth.uid() then addressee_id else requester_id end as other
    from public.friends
    where status = 'accepted'
      and (requester_id = auth.uid() or addressee_id = auth.uid())
  ) f;
$$;

-- Auth for the DB -> Edge Function webhooks below.
--
-- Every `notify-*` function runs with `verify_jwt = true`. The pg_cron jobs account for that
-- (see supabase/migrations/0001) but the pg_net *triggers* did not: they posted only a
-- Content-Type header, so every trigger-driven push was rejected at the edge from the day it
-- shipped until 2026-08-13. Measured, same request both ways:
--     no Authorization  -> 401 UNAUTHORIZED_NO_AUTH_HEADER
--     via this function -> 200
-- Nothing surfaced it: `net.http_post` is fire-and-forget, so the insert always succeeded.
--
-- The bearer token lives in Vault, not inline — this file is in a public repo, and a key
-- rotation is then one UPDATE rather than a migration. See supabase/migrations/0017.
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

-- DB -> edge-function webhooks via pg_net (async fire-and-forget; an unreachable function
-- never fails the insert). Replaces the dashboard-webhook hand-off for notify-versus-challenge.
create or replace function public.notify_versus_challenge_webhook()
returns trigger
language plpgsql
security definer
set search_path = public
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
drop trigger if exists versus_challenges_notify on public.versus_challenges;
create trigger versus_challenges_notify
  after insert on public.versus_challenges
  for each row execute function public.notify_versus_challenge_webhook();

-- "Your opponent finished" push.
-- Same pg_net pattern as `versus_challenges_notify`, on UPDATE instead of INSERT. Fires only on
-- the null -> non-null score transition, so the repeated writes `resolve_versus_challenge` makes
-- to the same row can't re-push. The Edge Function re-reads the row and decides the copy.
create or replace function public.notify_versus_result_webhook()
returns trigger
language plpgsql
security definer
set search_path = public
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
drop trigger if exists versus_challenges_result_notify on public.versus_challenges;
create trigger versus_challenges_result_notify
  after update of challenger_score, opponent_score on public.versus_challenges
  for each row execute function public.notify_versus_result_webhook();

create or replace function public.notify_friend_request_webhook()
returns trigger
language plpgsql
security definer
set search_path = public
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
drop trigger if exists friends_notify_request on public.friends;
create trigger friends_notify_request
  after insert on public.friends
  for each row execute function public.notify_friend_request_webhook();

-- ============================================================
-- APNs credentials via Vault (2026-07-15, applied live as migration `apns_vault_config`)
-- ============================================================
-- The real APNs auth key (F92WNG523G) lives in Supabase Vault, written 2026-07-15, because
-- no management token exists in the agent environment to set true Edge Function secrets.
-- Edge functions read it through this service-role-only RPC (see _shared/apns.ts: env vars
-- win when present; Vault is the fallback). A temporary `vault_set_secret` writer was used
-- once and dropped in migration `drop_vault_setter`.
-- Vault rows (names only; values encrypted): APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY,
-- APNS_BUNDLE_ID.

create or replace function public.get_apns_config()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_object_agg(name, decrypted_secret)
  from vault.decrypted_secrets
  where name in ('APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_PRIVATE_KEY', 'APNS_BUNDLE_ID');
$$;

revoke all on function public.get_apns_config() from public, anon, authenticated;
grant execute on function public.get_apns_config() to service_role;

-- App Store Server Notifications trust anchor via Vault (2026-07-17, applied live as migration
-- `app_store_notifications_root_ca_vault`). The public Apple Root CA - G3 PEM is stored in
-- Vault as `APPLE_ROOT_CA_PEM`; the `app-store-notifications` edge function reads it through
-- this service-role-only RPC when the env secret is absent (see _shared/app_store_config.ts).
-- Same rationale as get_apns_config: no management token here to set true Edge Function secrets.
create or replace function public.get_app_store_config()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select jsonb_object_agg(name, decrypted_secret)
  from vault.decrypted_secrets
  where name in ('APPLE_ROOT_CA_PEM');
$$;

revoke all on function public.get_app_store_config() from public, anon, authenticated;
grant execute on function public.get_app_store_config() to service_role;

-- Sport-wide distinct player-name index for The Grid's guess autocomplete (2026-07-17, applied
-- live as migration `grid_player_names_index`). security definer to read the full catalog past
-- player_seasons RLS, and returns one array so PostgREST's 1000-row table cap doesn't truncate
-- it. Sport-wide by design — a cell-scoped list would hand the player the grid's answers.
create or replace function public.grid_player_names(p_sport text)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct name order by name), '{}')
  from public.player_seasons
  where sport = p_sport and not career and name <> '';
$$;

revoke all on function public.grid_player_names(text) from public;
grant execute on function public.grid_player_names(text) to anon, authenticated, service_role;

-- One random minted Grid board, for the setup screen's "new random grid" (2026-07-27, applied
-- live as migration `random_grid_puzzle_rpc`). An RPC rather than a client-side pick over the
-- pool because the client's normal grid fetch pulls EVERY board for the sport, and NFL board
-- content averages 64 KB (cells carry 149-425 answer names) — picking client-side would grow
-- the payload linearly with the pool, which is the exact thing that blocks deepening it.
-- Returns one row regardless of pool size. Null when the pool holds nothing else, a real state
-- today: baseball has one board ever minted.
-- `search_path = ''` (not `public`) to match its siblings `grid_player_names`/`grid_guess_stats`
-- — the table reference below is fully qualified, so the body can't be redirected by a caller's
-- search_path. Not advisor-flagged (a literal `public` isn't "mutable"), just consistency.
create or replace function public.random_grid_puzzle(p_sport text, p_exclude_date text default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select p.content
  from public.puzzles p
  where p.format = 'grid'
    and p.sport = p_sport
    and (p_exclude_date is null or p.active_date is distinct from p_exclude_date::date)
  order by random()
  limit 1;
$$;

grant execute on function public.random_grid_puzzle(text, text) to anon, authenticated;

-- The membership relation — player -> (team, league, year) — for one sport (2026-07-27, applied
-- live as migration `grid_membership_index_rpc`). This is what lets the CLIENT generate its own
-- Grid boards (`GridLocalGenerator.swift`) instead of being capped by the minted pool, which
-- stood at 41 boards across all five sports. Sibling of `grid_player_names` above: same posture,
-- one aggregate so PostgREST's 1000-row cap can't truncate it, cached a week on the device.
--
-- Memberships alone support exactly two board shapes — teams x decades and teams x teams — since
-- both ask only "did this player appear for this team in this year". Stat/position axes need the
-- `stats` jsonb and are deliberately not shipped; the client simply doesn't offer those shapes.
--
-- Wire format v1: `teams` [{abbr, league}] indexed by team id, `players` [name] indexed by player
-- id, and `memberships` parallel to `players`, each `teamIdx:yearOffset[,...][;teamIdx:...]` with
-- offsets relative to `minYear`. Measured gzipped on the wire 2026-07-27: nfl 69 KB, nba 62 KB,
-- baseball 119 KB, soccer 254 KB, tennis 16 KB — about what a *single* NFL board's content costs.
--
-- League scoping mirrors grid.py's `_team_key`: for soccer the identity is (abbr, league) and
-- blank-league rows are dropped, because soccer codes collide across countries (MCI is Manchester
-- City and Melbourne City). Every other sport forces league to '' so a franchise can't split.
--
-- `set statement_timeout` is load-bearing: the aggregate runs 1.2-7.4s and anon's default is 3s,
-- so without it the RPC would 57014 for signed-out users and look exactly like "no data" to a
-- client wrapping it in `try?` — the same failure mode migration 0007 documents.
create or replace function public.grid_membership_index(p_sport text)
returns jsonb
language sql
stable
security definer
set search_path = ''
set statement_timeout = '30s'
as $$
  with base as (
    select distinct
      ps.name,
      ps.team_abbr as abbr,
      case when p_sport = 'soccer' then coalesce(ps.league, '') else '' end as league,
      ps.season_year as yr
    from public.player_seasons ps
    where ps.sport = p_sport
      and not ps.career
      and coalesce(ps.team_abbr, '') <> ''
      and coalesce(ps.name, '') <> ''
      and ps.season_year is not null
  ),
  scoped as (
    select * from base where p_sport <> 'soccer' or league <> ''
  ),
  teams as (
    select abbr, league, (row_number() over (order by abbr, league))::int - 1 as tidx
    from (select distinct abbr, league from scoped) d
  ),
  players as (
    select name, (row_number() over (order by name))::int - 1 as pidx
    from (select distinct name from scoped) d
  ),
  lo as (select min(yr) as min_year from scoped),
  runs as (
    select p.pidx, t.tidx,
           string_agg((s.yr - lo.min_year)::text, ',' order by s.yr) as years
    from scoped s
    join players p on p.name = s.name
    join teams t on t.abbr = s.abbr and t.league = s.league
    cross join lo
    group by p.pidx, t.tidx
  ),
  lines as (
    select pidx, string_agg(tidx::text || ':' || years, ';' order by tidx) as line
    from runs group by pidx
  )
  select jsonb_build_object(
    'sport', p_sport,
    'version', 1,
    'minYear', coalesce((select min_year from lo), 0),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('abbr', abbr, 'league', league)
                              order by tidx) from teams), '[]'::jsonb),
    'players', coalesce((select jsonb_agg(name order by pidx) from players), '[]'::jsonb),
    'memberships', coalesce((select jsonb_agg(line order by pidx) from lines), '[]'::jsonb)
  );
$$;

revoke all on function public.grid_membership_index(text) from public;
grant execute on function public.grid_membership_index(text) to anon, authenticated, service_role;

-- Crowd-sourced Grid rarity (2026-07-17, applied live as migration `grid_guesses_crowd_rarity`).
-- Every submitted Grid guess is logged; grid_guess_stats aggregates correct picks per cell to
-- power "X% picked this" on the result screen. Display-only — star scoring untouched.
create table if not exists public.grid_guesses (
  id bigint generated always as identity primary key,
  puzzle_day text not null,
  sport text not null,
  cell_index int not null check (cell_index between 0 and 8),
  guess_name text not null,
  correct boolean not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists grid_guesses_cell_idx
  on public.grid_guesses (sport, puzzle_day, cell_index);

alter table public.grid_guesses enable row level security;

create policy grid_guesses_insert_own on public.grid_guesses
  for insert to authenticated with check (user_id = (select auth.uid()));

create or replace function public.grid_guess_stats(p_sport text, p_day text)
returns table(cell_index int, guess_name text, picks bigint, cell_total bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select g.cell_index, g.guess_name, count(*) as picks,
         sum(count(*)) over (partition by g.cell_index) as cell_total
  from public.grid_guesses g
  where g.sport = p_sport and g.puzzle_day = p_day and g.correct
  group by g.cell_index, g.guess_name;
$$;

revoke all on function public.grid_guess_stats(text, text) from public;
grant execute on function public.grid_guess_stats(text, text) to anon, authenticated, service_role;

-- Trigram index for catalog name search (2026-07-18, applied live as migration
-- `player_seasons_name_trgm_idx`). The app filters with name ilike '%…%' (creation search,
-- WhoAmI photo reveal); at ~315k rows a cold seq scan under bulk-upsert load hit the anon
-- role's statement timeout (observed 500s → silent bundled-catalog fallback → blank photos).
create extension if not exists pg_trgm;
create index if not exists player_seasons_name_trgm_idx
  on public.player_seasons using gin (name gin_trgm_ops);

-- ─────────────────────────────────────────────────────────────────────────────
-- Storage: profile photo uploads (M20)
-- ─────────────────────────────────────────────────────────────────────────────

-- Public-read, owner-write bucket for uploaded profile photos (path: {uid}/avatar.jpg).
-- Public read so avatars render for friends/community without a signed URL round-trip;
-- write/update/delete restricted to the owning user via the {uid}/ path prefix, mirroring
-- the "own profile" RLS pattern on public.profiles.
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "avatar public read" on storage.objects;
drop policy if exists "avatar owner insert" on storage.objects;
drop policy if exists "avatar owner update" on storage.objects;
drop policy if exists "avatar owner delete" on storage.objects;

create policy "avatar public read" on storage.objects
  for select using (bucket_id = 'avatars');

create policy "avatar owner insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatar owner update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatar owner delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

--
-- Nation -> League -> Club, in the data and not just in the picker.
--
-- `league` on both `teams` and `player_seasons` holds a NATION ("Germany"), which collapses the
-- middle level: Bundesliga and 2. Bundesliga are indistinguishable, so a "league" filter can
-- only ever mean "this country". `leagues` already carries country/tier/espn_slug (0008), and
-- `espn_slug` is the stable competition key ("ger.1", "ger.2").
--
-- This adds that competition key to the two tables that reference a league WITHOUT touching the
-- existing `league` column, so every current read keeps working and adoption can be incremental.
-- Nation becomes derived (competition -> leagues.country) rather than stored, which is what
-- makes the three levels independent of each other.
alter table public.teams          add column if not exists competition text;
alter table public.player_seasons add column if not exists competition text;

-- Every club ingested so far is top-flight, so its competition is its nation's tier-1 entry.
-- Only fills NULLs, so re-running is safe.
update public.teams t
   set competition = l.espn_slug
  from public.leagues l
 where t.competition is null
   and l.sport = t.sport and l.league = t.league and l.tier = 1
   and l.espn_slug is not null;

create index if not exists teams_competition_idx
  on public.teams (sport, competition) where competition is not null;
create index if not exists player_seasons_competition_idx
  on public.player_seasons (sport, competition) where competition is not null;

-- ---------------------------------------------------------------------------
-- Account deletion (App Store Guideline 5.1.1(v))
-- ---------------------------------------------------------------------------
-- An app that supports account creation must let the user delete that account from inside the
-- app. `security definer` so this runs as `postgres`, which (unlike `authenticated`) has DELETE
-- on auth.users and BYPASSRLS. The user id comes from auth.uid() -- derived from the caller's
-- JWT -- so there is no parameter to forge and a caller can only ever delete themselves.
-- Deliberately does NOT touch storage.objects: Supabase guards that table with a trigger
-- (storage.protect_delete) that rejects any direct DELETE unless `storage.allow_delete_query`
-- is set, because deleting the row orphans the underlying file. The avatar is removed by the
-- client through the Storage API (`RepositoryContainer.deleteAccount`), which drops the file
-- and the row together.
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

-- ---------------------------------------------------------------------------------------------
-- Career game log (applied live 2026-08-01 as migrations `game_results_career_log` +
-- `game_results_benchmark_rpcs`).
--
-- One row per finished session. This exists because the app used to throw away everything about
-- a game the moment it ended: `RepositoryContainer.complete()` consumed `performance`/`perfect`
-- for the Elo delta and discarded both, raw scores never reached it at all, and the only
-- per-attempt record anywhere was `rating_history`'s `{sport, rating}` — no score, no accuracy,
-- no format. Every "what's my best ever / am I better at NFL or NBA" question was unanswerable
-- for want of writing it down.
--
-- Insert-only and immutable, like `arcade_scores`. `id` is client-generated (the device is the
-- source of truth — the app is fully playable signed out) so re-pushing a backlog is an
-- idempotent `on conflict do nothing`.
create table if not exists public.game_results (
  id            uuid primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  -- Client-supplied and therefore untrustworthy: the check clamps the future, and every
  -- cross-user aggregate below windows on server-set `created_at` instead.
  played_at     timestamptz not null check (played_at <= now() + interval '1 day'),
  format        text not null,
  sport         text not null,
  mode          text not null default 'daily'
                  check (mode in ('daily','practice','community','versus','dailyDraft','archive')),
  ranked        boolean not null default false,
  perfect       boolean not null default false,
  performance   double precision not null check (performance >= 0 and performance <= 1),
  score         int not null default 0 check (score >= 0),
  max_score     int not null default 0 check (max_score >= 0),
  correct       int not null default 0 check (correct >= 0),
  attempted     int not null default 0 check (attempted >= 0),
  duration_ms   int check (duration_ms is null or duration_ms >= 0),
  rating_before int,
  rating_after  int,
  xp_earned     int not null default 0,
  streak_after  int not null default 0,
  puzzle_id     text,
  details       jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists game_results_user_idx  on public.game_results (user_id, played_at desc);
create index if not exists game_results_bench_idx on public.game_results (format, sport, mode) where ranked;

alter table public.game_results enable row level security;

-- Own-read is what makes the analytics feature possible at all. Contrast `grid_guesses`, which
-- has NO select policy and is consequently write-only — its per-cell history can never be shown
-- back to the player who produced it. Don't repeat that here.
drop policy if exists "game_results own read" on public.game_results;
create policy "game_results own read" on public.game_results
  for select using (auth.uid() = user_id);

drop policy if exists "game_results insert own" on public.game_results;
create policy "game_results insert own" on public.game_results
  for insert with check (auth.uid() = user_id);
-- No update/delete policies: a recorded session is immutable.

-- Population benchmarks, so the client can render "you 76% - everyone 61%" in one round trip
-- rather than one per stat (same posture as `arcade_leaderboard`/`friend_profiles`).
--
-- The `having count(distinct user_id) >= 20` gate is load-bearing, not caution. Measured
-- 2026-07-27 this app had 4 profiles and 2 users who had ever finished a game; without the gate
-- these functions would tell the author he is in the 50th percentile of himself, and in a small
-- cohort would leak a recognisable individual's performance. Below the gate they must return NO
-- rows, so the UI omits the section entirely rather than rendering a fake comparison.
create or replace function public.format_benchmarks()
returns table (format text, sport text, players bigint, sessions bigint,
               avg_performance double precision, p50_score int, p90_score int,
               perfect_rate double precision)
language sql
stable
security definer
set search_path = ''
as $$
  select r.format, r.sport,
         count(distinct r.user_id) as players,
         count(*) as sessions,
         avg(r.performance) as avg_performance,
         percentile_disc(0.5) within group (order by r.score)::int as p50_score,
         percentile_disc(0.9) within group (order by r.score)::int as p90_score,
         avg(case when r.perfect then 1.0 else 0.0 end) as perfect_rate
  from public.game_results r
  where r.ranked
    and r.mode in ('daily','versus')
    and r.created_at > now() - interval '180 days'
  group by r.format, r.sport
  having count(distinct r.user_id) >= 20;
$$;

revoke all on function public.format_benchmarks() from public;
grant execute on function public.format_benchmarks() to anon, authenticated, service_role;

-- The caller's own standing per (format, sport), against the same gated population.
-- Caller-scoped via `auth.uid()`; anon is revoked explicitly (Supabase's default privileges
-- grant EXECUTE to anon on new public functions, and that survives `revoke ... from public`).
create or replace function public.my_stat_percentiles()
returns table (format text, sport text, my_accuracy double precision,
               my_best_score int, percentile double precision, sample_size bigint)
language sql
stable
security definer
set search_path = ''
as $$
  with eligible as (
    select r.format, r.sport, r.user_id,
           avg(r.performance) as user_performance,
           max(r.score) as user_best
    from public.game_results r
    where r.ranked
      and r.mode in ('daily','versus')
      and r.created_at > now() - interval '180 days'
    group by r.format, r.sport, r.user_id
  ),
  gated as (
    select format, sport from eligible
    group by format, sport
    having count(distinct user_id) >= 20
  ),
  ranked_users as (
    select e.*,
           percent_rank() over (partition by e.format, e.sport order by e.user_performance) as pr,
           count(*) over (partition by e.format, e.sport) as cohort
    from eligible e
    join gated g on g.format = e.format and g.sport = e.sport
  )
  select ru.format, ru.sport, ru.user_performance, ru.user_best, ru.pr, ru.cohort
  from ranked_users ru
  where ru.user_id = auth.uid();
$$;

revoke all on function public.my_stat_percentiles() from public;
revoke execute on function public.my_stat_percentiles() from anon;
grant execute on function public.my_stat_percentiles() to authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- The bot ladder (M22) — see supabase/migrations/0016_bot_ladder.sql
--
-- The bots are skill-limited SOLVERS, not score generators: the client runs the rung's real
-- puzzle through `BotSolver` with the rung's `bot_skill` and `seed`, so the bot makes real
-- decisions on real players and its run can be replayed alongside the player in real time.
-- That delivers the feeling of a live opponent with zero realtime infrastructure. Consequently
-- nothing about a bot's play lives on the server: `ladder_rungs` carries only the inputs (which
-- board, which bot, how good, how long, what seed) and the run reproduces identically on every
-- device from those five columns.
--
-- Two product rules, encoded here as far as a schema can encode them:
--   * bots are labelled as bots, always — hence `bots` is its own world-readable table with a
--     name/avatar/tagline, never a row in `profiles` wearing a human's clothes;
--   * the ladder pays XP and ladder rank only, never the solo rating — so there is no rating
--     column here, and `submit_ladder_attempt` touches nothing but ladder state.
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.bots (
  id         text primary key,
  name       text not null,
  avatar     text not null default '🤖',
  tagline    text not null default '',
  -- The bot's natural level. A rung may override it (`ladder_rungs.bot_skill`) so the same
  -- character can appear early as a warm-up and late as a boss.
  base_skill double precision not null check (base_skill >= 0 and base_skill <= 1),
  persona    text not null default ''
);

-- Bots are characters, not difficulty labels (migration 0019). `style` changes `BotSolver`'s
-- policy — two bots at identical `bot_skill` play visibly differently — so it feeds the ladder's
-- difficulty calibration, not just its copy.
alter table public.bots
  add column if not exists style          text not null default 'consistent',
  add column if not exists style_line     text not null default '',
  add column if not exists backstory      text not null default '',
  add column if not exists palette        text not null default 'electric',
  add column if not exists voice          jsonb not null default '{}'::jsonb,
  add column if not exists favorite_teams jsonb not null default '[]'::jsonb;
alter table public.bots drop constraint if exists bots_style_domain;
alter table public.bots add constraint bots_style_domain check (style in
  ('overeager', 'methodical', 'consistent', 'deepCuts', 'slowBurn', 'prescient'));

-- The two numbers that make a rung's difficulty inspectable (migration 0015 of the ladder work):
-- `board_difficulty` from each format's own scoring metric, and `target_win_rate`, the simulated
-- P(reference player wins) that `bot_skill` is now solved backwards from.
alter table public.ladder_rungs
  add column if not exists board_difficulty double precision,
  add column if not exists target_win_rate  double precision;

-- One row per rung. Four independent difficulty levers so the curve doesn't go flat:
-- bot skill, the clock, the puzzle's own difficulty, and which game it is.
create table if not exists public.ladder_rungs (
  rung               int primary key,
  tier               text not null,        -- 'bronze' | 'silver' | 'gold', matching Home's tiers
  mode               text not null check (mode in ('keep4', 'whoami', 'grid')),
  sport              text not null,
  puzzle_id          text not null references public.puzzles(id),
  bot_id             text not null references public.bots(id),
  bot_skill          double precision not null check (bot_skill >= 0 and bot_skill <= 1),
  time_limit_seconds int not null check (time_limit_seconds > 0),
  -- Seeds the bot's decisions AND its pacing, so a rung plays out identically for every player:
  -- comparable, leaderboard-able, speedrun-able.
  seed               bigint not null,
  is_boss            boolean not null default false
);

-- A rung is a difficulty, not a board — so it needs a pool of them (migration 0020).
--
-- With a single `puzzle_id`, losing rung 7 and retrying handed back the identical board with the
-- answers already known: the score meant nothing, and `ladder_attempts` — the corpus human ghost
-- duels will later be built from — filled with rows that look like skill and are actually recall.
--
-- Why a child table rather than an array column on `ladder_rungs`: each board needs its own
-- `seed` (the same bot must not replay an identical decision pattern on a new board) and its own
-- verified `board_difficulty`, because a rung's difficulty is a promise. If board A is 0.25 and
-- board B is 0.60 then the rung is a different rung depending on which one you drew, and the
-- calibration in `tools/ingest/ladder.py` stops describing anything. Pools are therefore selected
-- difficulty-homogeneous and re-verified per board; see that tool for the tolerances.
--
-- `ladder_rungs.puzzle_id` stays as the pool's ordinal-0 board, so an already-shipped client that
-- never calls `next_ladder_board` keeps working unchanged.
create table if not exists public.ladder_rung_boards (
  rung             int  not null references public.ladder_rungs(rung) on delete cascade,
  ordinal          int  not null,               -- stable serve order
  puzzle_id        text not null references public.puzzles(id),
  board_difficulty double precision not null,
  seed             bigint not null,             -- per BOARD, not per rung
  primary key (rung, ordinal)
);
-- One board may not appear twice in the same pool — without this a short pool could be padded
-- with duplicates and still report a healthy count.
create unique index if not exists ladder_rung_boards_unique_board
  on public.ladder_rung_boards (rung, puzzle_id);

-- And no puzzle may be served by two DIFFERENT bots either. The index above is (rung, puzzle_id),
-- which only stops one rung listing a board twice; two rungs could each be handed the same puzzle
-- and nothing would complain. Live data was clean when this was added (165 rows, 165 distinct) but
-- clean by luck — `build_pool` de-duplicates in memory within a single reseed, so the guarantee
-- lasted exactly as long as one process. A partial reseed or a manual insert would collide
-- silently, and the symptom (the same board under two different bot names) reads as a content bug
-- rather than a constraint gap. Applied live 2026-08-21 (migration 0022), probed with a rejected
-- cross-rung duplicate insert.
create unique index if not exists ladder_rung_boards_puzzle_unique
  on public.ladder_rung_boards (puzzle_id);

create table if not exists public.ladder_progress (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  highest_rung int not null default 0,
  updated_at   timestamptz not null default now()
);

-- Every attempt, won or lost. Doubles as the per-puzzle score corpus that human ghost duels
-- will need later — that is why `score`/`bot_score` are the normalized 0...1 `performance` every
-- mode already produces, not each format's own point scale. No second migration later.
create table if not exists public.ladder_attempts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  rung       int  not null,
  score      double precision not null check (score >= 0 and score <= 1),
  bot_score  double precision not null check (bot_score >= 0 and bot_score <= 1),
  won        boolean not null,
  elapsed_ms int not null check (elapsed_ms >= 0),
  created_at timestamptz not null default now()
);
-- Which board of the rung's pool this attempt was played on (migration 0020). Nullable because
-- every attempt recorded before pools existed was played on the rung's single board, and
-- back-filling a guess would be inventing history.
alter table public.ladder_attempts
  add column if not exists puzzle_id text references public.puzzles(id);

create index if not exists ladder_attempts_user_idx on public.ladder_attempts (user_id, rung);
-- The corpus lookup: "what did people score on this board".
create index if not exists ladder_attempts_rung_idx on public.ladder_attempts (rung, score desc);
-- `next_ladder_board`'s unseen-board probe: (user_id, rung) alone leaves the puzzle comparison
-- as a heap fetch per candidate row.
create index if not exists ladder_attempts_seen_idx
  on public.ladder_attempts (user_id, rung, puzzle_id);

alter table public.bots              enable row level security;
alter table public.ladder_rungs      enable row level security;
alter table public.ladder_rung_boards enable row level security;
alter table public.ladder_progress   enable row level security;
alter table public.ladder_attempts   enable row level security;

drop policy if exists "bots readable"              on public.bots;
drop policy if exists "ladder_rungs readable"      on public.ladder_rungs;
drop policy if exists "ladder_rung_boards readable" on public.ladder_rung_boards;
drop policy if exists "ladder_progress own"        on public.ladder_progress;
drop policy if exists "ladder_attempts own read"   on public.ladder_attempts;

-- Ladder content is world-readable scaffolding, like `seasons`/`cohorts`. It has to be: a
-- signed-out player can still see what the ladder is before deciding to sign in for it.
create policy "bots readable"         on public.bots         for select using (true);
create policy "ladder_rungs readable" on public.ladder_rungs for select using (true);
create policy "ladder_rung_boards readable"
  on public.ladder_rung_boards for select using (true);

create policy "ladder_progress own" on public.ladder_progress
  for select using (auth.uid() = user_id);
create policy "ladder_attempts own read" on public.ladder_attempts
  for select using (auth.uid() = user_id);
-- Writes to both go through `submit_ladder_attempt` (SECURITY DEFINER) — no insert/update
-- policy, so a client can't post itself to rung 30 without playing 1 through 29.

-- Records one attempt and advances the player's high-water mark. Returns the new `highest_rung`.
--
-- The rung gate is the whole point: `highest_rung` can only ever move to `p_rung` when
-- `p_rung = highest_rung + 1` and the attempt was won, so progress is a chain, not a claim.
-- Dropped and recreated rather than `create or replace`d when `p_puzzle_id` was added (migration
-- 0020): the new argument changes the signature, and leaving the old five-argument function in
-- place would make every existing five-argument call ambiguous between the two overloads and fail
-- outright. With the sixth argument defaulted, a shipped client that posts only the original five
-- still resolves here and behaves as before — it records a null board, which is honest, since a
-- client that doesn't know about pools genuinely played the rung's ordinal-0 board.
drop function if exists public.submit_ladder_attempt(int, double precision, double precision,
                                                     boolean, int);

create or replace function public.submit_ladder_attempt(
  p_rung int, p_score double precision, p_bot_score double precision,
  p_won boolean, p_elapsed_ms int, p_puzzle_id text default null)
returns int language plpgsql security definer as $$
declare
  me uuid := auth.uid();
  current_high int;
  s  double precision := least(greatest(coalesce(p_score, 0), 0), 1);
  bs double precision := least(greatest(coalesce(p_bot_score, 0), 0), 1);
  ms int := least(greatest(coalesce(p_elapsed_ms, 0), 0), 3_600_000);
  board text;
begin
  if me is null then raise exception 'not signed in'; end if;
  if not exists (select 1 from public.ladder_rungs where rung = p_rung) then
    raise exception 'no such rung';
  end if;

  -- Trust the rung's own pool over the client's claim: a board that isn't in this rung's pool
  -- (or is not the rung's own board) is recorded as null rather than poisoning the "which boards
  -- has this player seen" answer with an id they could have posted by hand.
  select p_puzzle_id into board
   where p_puzzle_id is not null
     and (exists (select 1 from public.ladder_rung_boards b
                   where b.rung = p_rung and b.puzzle_id = p_puzzle_id)
          or exists (select 1 from public.ladder_rungs r
                      where r.rung = p_rung and r.puzzle_id = p_puzzle_id));

  insert into public.ladder_attempts (user_id, rung, score, bot_score, won, elapsed_ms, puzzle_id)
    values (me, p_rung, s, bs, coalesce(p_won, false), ms, board);

  insert into public.ladder_progress (user_id, highest_rung) values (me, 0)
    on conflict (user_id) do nothing;
  select highest_rung into current_high from public.ladder_progress where user_id = me;

  if coalesce(p_won, false) and p_rung = current_high + 1 then
    update public.ladder_progress
      set highest_rung = p_rung, updated_at = now()
      where user_id = me
      returning highest_rung into current_high;
  end if;

  return current_high;
end;
$$;

revoke all on function public.submit_ladder_attempt(int, double precision, double precision,
                                                    boolean, int, text) from public;
grant execute on function public.submit_ladder_attempt(int, double precision, double precision,
                                                       boolean, int, text)
  to authenticated, service_role;

-- Which board this player gets next on this rung (migration 0020).
--
-- Lowest-ordinal board they have no `ladder_attempts` row for; if they have seen the whole pool,
-- the least recently attempted one. `SECURITY DEFINER` because the decision reads the caller's
-- own attempt history, which is own-read RLS — scoped hard to `auth.uid()`, and it returns
-- nothing about anyone else.
--
-- A signed-out caller gets ordinal 0: the ladder is browsable signed out, so this has to answer
-- rather than fail; it just can't personalise. Returns zero rows when the rung has no pool at
-- all, which the client treats as "fall back to `ladder_rungs.puzzle_id`" — the same path it
-- needs for playing offline anyway.
create or replace function public.next_ladder_board(p_rung int)
returns table (puzzle_id text, seed bigint, board_difficulty double precision)
language plpgsql security definer stable as $$
declare
  me uuid := auth.uid();
begin
  if me is null then
    return query
      select b.puzzle_id, b.seed, b.board_difficulty
        from public.ladder_rung_boards b
       where b.rung = p_rung
       order by b.ordinal
       limit 1;
    return;
  end if;

  return query
    select b.puzzle_id, b.seed, b.board_difficulty
      from public.ladder_rung_boards b
     where b.rung = p_rung
       and not exists (select 1 from public.ladder_attempts a
                        where a.user_id = me and a.rung = p_rung
                          and a.puzzle_id = b.puzzle_id)
     order by b.ordinal
     limit 1;
  -- RETURN QUERY sets FOUND, so this distinguishes "pool has an unseen board" from "seen it all"
  -- without counting the pool twice.
  if found then return; end if;

  return query
    select b.puzzle_id, b.seed, b.board_difficulty
      from public.ladder_rung_boards b
      left join lateral (
        select max(a.created_at) as last_at
          from public.ladder_attempts a
         where a.user_id = me and a.rung = p_rung and a.puzzle_id = b.puzzle_id
      ) la on true
     where b.rung = p_rung
     order by la.last_at nulls first, b.ordinal
     limit 1;
end $$;

revoke all on function public.next_ladder_board(int) from public;
grant execute on function public.next_ladder_board(int) to anon, authenticated, service_role;

-- "Your record vs each character" for the roster screen (migration 0021).
--
-- `ladder_attempts` is own-read RLS and the bot is only reachable through `ladder_rungs`, so the
-- record block needs one SECURITY DEFINER aggregate rather than a client-side join over a table
-- the client can only see its own rows of. A signed-out caller gets zero rows, which is exactly
-- the roster's "sign in to see your record" state.
create or replace function public.my_bot_records()
returns table (bot_id text, played int, won int,
               best_score double precision, best_bot_score double precision)
language sql security definer stable as $$
  select r.bot_id,
         count(*)::int,
         count(*) filter (where a.won)::int,
         max(a.score),
         max(a.bot_score)
  from public.ladder_attempts a
  join public.ladder_rungs r on r.rung = a.rung
  where a.user_id = auth.uid()
  group by r.bot_id;
$$;

revoke all on function public.my_bot_records() from public;
grant execute on function public.my_bot_records() to anon, authenticated, service_role;

-- ── Content ──────────────────────────────────────────────────────────────────
-- Six characters, each recognisable and each honestly a bot. Beating "The Analyst" is a better
-- story than beating `bot_47`, and it costs nothing to say which is which.
insert into public.bots (id, name, avatar, tagline, base_skill, persona) values
  ('rookie',    'The Rookie',    '🐣', 'Watches every game. Remembers none of them.', 0.35,
   'Guesses fast and confidently. Gets the obvious ones and nothing else.'),
  ('stathead',  'Stat Head',     '📊', 'Reads the box score. Twice.',                 0.55,
   'Solid on the numbers, lost the moment a call needs judgement.'),
  ('analyst',   'The Analyst',   '🎙️', 'Has an opinion, and a graph to back it.',     0.70,
   'Talks through every pick. Usually right, occasionally spectacularly wrong.'),
  ('scout',     'The Scout',     '🔭', 'Saw them play in college.',                   0.82,
   'Deep on the players nobody else remembers. Quick, too.'),
  ('archivist', 'The Archivist', '📼', 'Owns the tape. All of it.',                   0.91,
   'Has seen the answer before. Slow to start, impossible to shake.'),
  ('oracle',    'The Oracle',    '🔮', 'Knew the answer before the question.',        0.98,
   'The last rung. Beat it and there is nothing left to beat.')
on conflict (id) do update set
  name = excluded.name, avatar = excluded.avatar, tagline = excluded.tagline,
  base_skill = excluded.base_skill, persona = excluded.persona;

-- 30 rungs, generated rather than hand-listed so the four levers stay legible as formulas.
--
--   skill  0.35 -> 0.98 linearly, +0.04 on a boss
--   clock  the format's own duel default, tightening to 55% of it by rung 30
--   puzzle Who Am I? draws from the tier's own obscurity band (easy/medium/hard)
--   mode   all Keep4 early, Who Am I? joins at 7, The Grid at 15
--
-- The board for each rung is picked deterministically (`order by id offset ...`), not randomly:
-- a rung has to be the same board for every player, forever, or none of the comparisons mean
-- anything. Re-running this statement re-picks the same rows.
with plan as (
  select
    r as rung,
    case when r <= 10 then 'bronze' when r <= 20 then 'silver' else 'gold' end as tier,
    (r % 10 = 0) as is_boss,
    case
      when r <= 6  then 'keep4'
      when r <= 14 then (case when r % 2 = 0 then 'whoami' else 'keep4' end)
      else (case r % 3 when 0 then 'grid' when 1 then 'keep4' else 'whoami' end)
    end as mode,
    (array['nfl', 'nba', 'baseball', 'soccer', 'tennis'])[1 + ((r - 1) % 5)] as sport,
    -- Capped at 0.98, not 1.0: a flawless bot can only be beaten by a flawless *and* faster
    -- run, which turns the final boss into a coin flip on latency rather than a test of play.
    least(0.98, 0.35 + (r - 1) * (0.98 - 0.35) / 29.0 + case when r % 10 = 0 then 0.04 else 0 end)
      as bot_skill
  from generate_series(1, 30) as r
),
sized as (
  select p.*,
    case p.mode when 'keep4' then 120 when 'whoami' then 90 else 180 end as base_seconds,
    case p.tier when 'bronze' then 'easy' when 'silver' then 'medium' else 'hard' end as band
  from plan p
),
picked as (
  select s.*, (
    select q.id from public.puzzles q
    where q.format = s.mode
      and q.sport = s.sport
      and q.active_date is not null
      and q.active_date < (now() at time zone 'utc')::date
      and (s.mode <> 'whoami' or q.content->>'difficulty' = s.band)
    order by q.id
    offset (s.rung * 7) % greatest(1, (
      select count(*) from public.puzzles q2
      where q2.format = s.mode and q2.sport = s.sport
        and q2.active_date is not null
        and q2.active_date < (now() at time zone 'utc')::date
        and (s.mode <> 'whoami' or q2.content->>'difficulty' = s.band)))
    limit 1) as puzzle_id
  from sized s
)
insert into public.ladder_rungs
  (rung, tier, mode, sport, puzzle_id, bot_id, bot_skill, time_limit_seconds, seed, is_boss)
select
  p.rung, p.tier, p.mode, p.sport, p.puzzle_id,
  -- The bot whose natural level is closest to this rung's, so a character's appearances cluster
  -- rather than scattering across the whole ladder.
  (select b.id from public.bots b order by abs(b.base_skill - p.bot_skill) limit 1),
  round(p.bot_skill::numeric, 3),
  round(p.base_seconds * (1.0 - 0.45 * (p.rung - 1) / 29.0)),
  -- Stable, distinct, and derived from the rung so a re-seed reproduces it exactly.
  (p.rung::bigint * 2654435761) % 9223372036854775807,
  p.is_boss
from picked p
where p.puzzle_id is not null
on conflict (rung) do update set
  tier = excluded.tier, mode = excluded.mode, sport = excluded.sport,
  puzzle_id = excluded.puzzle_id, bot_id = excluded.bot_id, bot_skill = excluded.bot_skill,
  time_limit_seconds = excluded.time_limit_seconds, seed = excluded.seed,
  is_boss = excluded.is_boss;

-- ============================================================================
-- M26 — player headshot rehost (2026-08-24)
--
-- Headshots were hotlinked to five third-party CDNs while only team logos were ever
-- rehosted, and every one of them failed differently and silently:
--   * img.mlbstatic.com carried Cloudinary's d_people:generic:headshot:silo fallback on all
--     90,092 baseball rows, so "no photo" returned 200 OK with a grey silhouette;
--   * a.espncdn.com 404s retired players (Michael Jordan included);
--   * upload.wikimedia.org rate-limits us (26 of 40 probes returned 429).
-- Because player_seasons.headshot was 100% non-null throughout, none of this was visible
-- as a coverage metric. Rehosting also unlocks Storage's render/transform endpoint, which
-- AppImagePipeline.transformed() only applies to Storage URLs — hotlinked NFL headshots
-- were shipping at a 373 KB median for circles drawn at ~40 pt.
-- ============================================================================

-- One row per distinct SOURCE url seen in player_seasons.headshot. Doubles as the work
-- queue for the rehost: shards claim a disjoint slice by (status, shard) rather than each
-- paginating player_seasons, which at 18 concurrent deep-OFFSET scans produced 57014
-- statement timeouts.
create table if not exists public.headshot_assets (
  source_url  text primary key,
  sport       text,
  status      text not null,
  storage_key text,
  public_url  text,
  bytes       integer,
  note        text,
  shard       smallint,
  checked_at  timestamptz not null default now()
);

alter table public.headshot_assets drop constraint if exists headshot_assets_status_check;
alter table public.headshot_assets add constraint headshot_assets_status_check
  check (status in ('pending','ok','placeholder','missing','error'));

create index if not exists headshot_assets_status_idx on public.headshot_assets (status);
create index if not exists headshot_assets_sport_idx  on public.headshot_assets (sport);
create index if not exists headshot_assets_claim_idx  on public.headshot_assets (status, shard);

alter table public.headshot_assets enable row level security;
-- Ingest-side bookkeeping only: service-role writes it, nothing in the app reads it.
-- RLS on with no policy = anon sees nothing; service_role bypasses.

-- World-readable, same contract as team-logos (objects served immutable, max-age 1y).
insert into storage.buckets (id, name, public)
values ('player-headshots', 'player-headshots', true)
on conflict (id) do update set public = true;

-- Applies the ledger to the catalog. 'ok' rows get repointed at our copy; 'placeholder' and
-- 'missing' are CLEARED to '' so PlayerHeadshotBadge renders its initials-on-team-colors
-- monogram — a designed fallback beats a grey silo, and clearing is the only way to get
-- there because the silo returns 200 to every layer above it.
create or replace function public.headshot_repoint(dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  to_point bigint;
  to_clear bigint;
begin
  select count(*) into to_point
  from player_seasons p
  join headshot_assets a on a.source_url = p.headshot
  where a.status = 'ok' and a.public_url is not null and p.headshot <> a.public_url;

  select count(*) into to_clear
  from player_seasons p
  join headshot_assets a on a.source_url = p.headshot
  where a.status in ('placeholder','missing') and coalesce(p.headshot,'') <> '';

  if not dry_run then
    update player_seasons p set headshot = a.public_url
      from headshot_assets a
     where a.source_url = p.headshot and a.status = 'ok' and a.public_url is not null;

    update player_seasons p set headshot = ''
      from headshot_assets a
     where a.source_url = p.headshot and a.status in ('placeholder','missing');
  end if;

  return jsonb_build_object('dry_run', dry_run, 'repointed', to_point, 'cleared', to_clear);
end;
$$;

revoke all on function public.headshot_repoint(boolean) from public, anon, authenticated;
grant execute on function public.headshot_repoint(boolean) to service_role;

-- headshot_repoint() joins player_seasons.headshot against headshot_assets.source_url.
-- Without this the join is a seq scan over ~382k rows and the RPC dies with 57014
-- (statement timeout) before touching a row.
create index if not exists player_seasons_headshot_idx on public.player_seasons (headshot);
