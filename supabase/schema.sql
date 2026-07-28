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
  format      text not null,                 -- 'keep4' | 'whoami' | 'grid'
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

-- A 1-v1 head-to-head relationship between two players, tracked over up to 7 challenges.
-- `user_a`/`user_b` are stored with user_a < user_b (enforced by `create_versus_challenge`)
-- so a series is addressable regardless of who issued the latest challenge.
create table if not exists public.versus_series (
  id         bigint generated always as identity primary key,
  user_a     uuid not null references auth.users(id) on delete cascade,
  user_b     uuid not null references auth.users(id) on delete cascade,
  sport      text not null,
  wins_a     int  not null default 0,
  wins_b     int  not null default 0,
  status     text not null default 'active',     -- 'active' | 'completed' (7 played)
  created_at timestamptz not null default now(),
  constraint versus_series_ordered check (user_a < user_b)
);
create unique index if not exists versus_series_pair_sport
  on public.versus_series (user_a, user_b, sport) where status = 'active';

-- One challenge = one shared daily puzzle played independently by both sides.
-- `expires_at` is set 24h out at creation; `versus-timeout` (pg_cron scheduling:
-- supabase/migrations/0001_schedule_edge_functions.sql) forfeits anyone who hasn't completed by then.
create table if not exists public.versus_challenges (
  id                    bigint generated always as identity primary key,
  series_id             bigint not null references public.versus_series(id) on delete cascade,
  sport                 text not null,
  puzzle_id             text not null references public.puzzles(id),
  challenger_id         uuid not null references auth.users(id) on delete cascade,
  opponent_id           uuid not null references auth.users(id) on delete cascade,
  status                text not null default 'pending',  -- 'pending'|'active'|'completed'|'forfeited'
  challenger_score      double precision,
  opponent_score        double precision,
  challenger_completed_at timestamptz,
  opponent_completed_at   timestamptz,
  winner_id             uuid references auth.users(id),
  created_at            timestamptz not null default now(),
  expires_at            timestamptz not null default (now() + interval '24 hours')
);
create index if not exists versus_challenges_participant_idx
  on public.versus_challenges (challenger_id, opponent_id, status);

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

-- Records the caller's score on a challenge they're part of; resolves the challenge + advances
-- the series once both sides have a score. Keeps the read-modify-write atomic (vs. a client
-- upsert racing the opponent's submission).
create or replace function public.submit_versus_result(p_challenge_id bigint, p_score double precision)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  is_challenger boolean;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null then raise exception 'challenge not found'; end if;
  if auth.uid() not in (c.challenger_id, c.opponent_id) then
    raise exception 'not a participant';
  end if;

  is_challenger := auth.uid() = c.challenger_id;
  if is_challenger then
    update public.versus_challenges
      set challenger_score = p_score, challenger_completed_at = now()
      where id = p_challenge_id;
  else
    update public.versus_challenges
      set opponent_score = p_score, opponent_completed_at = now()
      where id = p_challenge_id;
  end if;

  select * into c from public.versus_challenges where id = p_challenge_id;
  if c.challenger_score is not null and c.opponent_score is not null and c.status <> 'completed' then
    perform public.resolve_versus_challenge(p_challenge_id);
  end if;
end;
$$;

-- Shared resolution path for both normal completion (`submit_versus_result`) and the
-- `versus-timeout` Edge Function (forfeits). Marks the challenge decided and advances the series.
create or replace function public.resolve_versus_challenge(p_challenge_id bigint)
returns void language plpgsql security definer as $$
declare
  c public.versus_challenges%rowtype;
  winner uuid;
begin
  select * into c from public.versus_challenges where id = p_challenge_id for update;
  if c.id is null or c.status = 'completed' then return; end if;

  if c.challenger_score is not null and c.opponent_score is not null then
    winner := case when c.challenger_score >= c.opponent_score then c.challenger_id else c.opponent_id end;
  elsif c.challenger_score is not null then
    winner := c.challenger_id;       -- opponent forfeited
  elsif c.opponent_score is not null then
    winner := c.opponent_id;         -- challenger forfeited
  else
    winner := null;                  -- double no-show: no-contest, series unaffected
  end if;

  update public.versus_challenges
    set status = case when winner is null then 'forfeited' else 'completed' end, winner_id = winner
    where id = p_challenge_id;

  if winner is not null then
    update public.versus_series s
      set wins_a = wins_a + case when winner = s.user_a then 1 else 0 end,
          wins_b = wins_b + case when winner = s.user_b then 1 else 0 end,
          status = case when wins_a + wins_b + 1 >= 7 then 'completed' else status end
      where id = c.series_id;
  end if;
end;
$$;

-- Looks up (or starts) the active series for a pair + sport, creates the next challenge on
-- today's puzzle, and returns its id. Keeps `user_a < user_b` ordering + the find-or-create
-- race out of client code.
create or replace function public.create_versus_challenge(p_opponent uuid, p_sport text, p_puzzle_id text)
returns bigint language plpgsql security definer as $$
declare
  me uuid := auth.uid();
  a uuid; b uuid;
  s_id bigint;
  ch_id bigint;
begin
  if me is null or me = p_opponent then raise exception 'invalid opponent'; end if;
  a := least(me, p_opponent); b := greatest(me, p_opponent);

  select id into s_id from public.versus_series
    where user_a = a and user_b = b and sport = p_sport and status = 'active';
  if s_id is null then
    insert into public.versus_series (user_a, user_b, sport) values (a, b, p_sport)
      returning id into s_id;
  end if;

  insert into public.versus_challenges (series_id, sport, puzzle_id, challenger_id, opponent_id)
    values (s_id, p_sport, p_puzzle_id, me, p_opponent)
    returning id into ch_id;
  return ch_id;
end;
$$;

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
    headers := '{"Content-Type": "application/json"}'::jsonb);
  return new;
end;
$$;
drop trigger if exists versus_challenges_notify on public.versus_challenges;
create trigger versus_challenges_notify
  after insert on public.versus_challenges
  for each row execute function public.notify_versus_challenge_webhook();

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
      headers := '{"Content-Type": "application/json"}'::jsonb);
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
