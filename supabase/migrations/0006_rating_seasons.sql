-- Rating seasons DDL: rating_seasons + season_ratings + season_badges + leaderboard RPCs
-- Applied live 2026-07-20 via the Supabase MCP (prod migration `m5_phase_f_rating_seasons`); recorded
-- here after the fact so the repo's migration ledger matches production. Idempotent
-- (IF NOT EXISTS / duplicate-safe DO blocks), so re-running is a no-op — schema.sql
-- remains the source of truth (CLAUDE.md).

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
