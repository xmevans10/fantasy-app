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
  sport       text not null,                 -- 'nfl' | 'nba'
  format      text not null,                 -- 'keep4' | 'whoami'
  content     jsonb not null,
  active_date date
);

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
  id          text primary key,            -- e.g. 'derrick-henry-2020'
  sport       text not null,               -- 'nfl' | 'nba'
  name        text not null,
  team_abbr   text not null,
  season_year int  not null,
  position    text not null,               -- 'WR','RB','QB' | 'G','F','C'
  stats       jsonb not null
);

-- User-authored puzzles, kept separate from `puzzles` so the daily rotation stays
-- clean. `content` is the same camelCase Keep4Puzzle/WhoAmIPuzzle JSON the app decodes.
create table if not exists public.community_puzzles (
  id          text primary key,            -- short share code
  author_id   uuid not null references auth.users(id) on delete cascade,
  sport       text not null,               -- 'nfl' | 'nba'
  format      text not null,               -- 'keep4' | 'whoami'
  title       text not null,
  content     jsonb not null,
  visibility  text not null default 'public',   -- 'public' | 'unlisted'
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
