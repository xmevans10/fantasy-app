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
alter table public.puzzle_history enable row level security;
-- no policies -> service-role only

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
-- Headshot parity (pre-M17 session fix) + career-grain rows (M17): a career row's
-- season_year holds the player's LAST season; first_year/last_year give the full span.
alter table public.player_seasons add column if not exists headshot   text not null default '';
alter table public.player_seasons add column if not exists career     boolean not null default false;
alter table public.player_seasons add column if not exists first_year int;
alter table public.player_seasons add column if not exists last_year  int;

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
create or replace function public.bump_weekly_xp(amount int)
returns boolean language plpgsql security definer as $$
declare
  updated boolean;
begin
  update public.cohort_members cm
    set weekly_xp = weekly_xp + amount
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
