-- Week Packs: a batch of boards about the week a league just finished, dropped together.
--
-- Own tables rather than more rows in `puzzles`, for three reasons that each break something
-- live today:
--   1. Home's daily fetch takes the FIRST keep4 row matching the local day, so a second dated
--      keep4 row for a sport can take over the daily card.
--   2. An undated row is "always released" to Browse, so every installed build would list pack
--      boards in the archive the moment they were minted, a day before the pack opens.
--   3. `puzzle_history` is unique on (served_date, sport, format), so five same-format boards
--      for one day cannot all be recorded there.
-- Builds that predate this never read these tables, which is the whole wire-safety story.
--
-- Written by tools/ingest/pack.py. A pack is inserted as 'draft', its items written, and only
-- then flipped to 'published', so a run that dies midway leaves nothing any client can see.

create table if not exists public.packs (
  id            text primary key,              -- '<sport>-<period_key>', e.g. 'nfl-2026-wk01'
  sport         text not null,
  period_key    text not null,                 -- same key fresh_drop puts in theme keys
  label         text not null,                 -- '2026 Week 1'
  release_date  date not null,                 -- device-local day the pack opens
  status        text not null default 'draft'
                  check (status in ('draft', 'published', 'withdrawn')),
  created_at    timestamptz not null default now(),
  unique (sport, period_key)
);

create index if not exists packs_release_idx
  on public.packs (status, release_date desc);

create table if not exists public.pack_items (
  id          text primary key,                -- the headline reuses the daily's puzzles.id
  pack_id     text not null references public.packs(id) on delete cascade,
  ordinal     smallint not null,
  role        text not null,                   -- headline | game | position | division | niche
  format      text not null,                   -- 'keep4' today
  theme_key   text not null,
  signature   text not null unique,            -- novelty across packs
  content     jsonb not null,                  -- identical shape to puzzles.content
  unique (pack_id, ordinal)
);

alter table public.packs      enable row level security;
alter table public.pack_items enable row level security;

drop policy if exists "published packs readable" on public.packs;
create policy "published packs readable" on public.packs
  for select using (status = 'published');

drop policy if exists "published pack items readable" on public.pack_items;
create policy "published pack items readable" on public.pack_items
  for select using (exists (
    select 1 from public.packs p where p.id = pack_items.pack_id and p.status = 'published'
  ));
-- No write policies: service role only, like `puzzles`.

-- A pack board's result row. Unranked (like community), so the benchmark and percentile
-- functions, which read `ranked and mode in ('daily','versus')`, are unaffected.
alter table public.game_results drop constraint if exists game_results_mode_check;
alter table public.game_results add constraint game_results_mode_check
  check (mode in ('daily','practice','community','versus','dailyDraft','archive','pack'));

-- Which build registered each device token, so the Week Pack push only reaches builds that can
-- show a pack. Before this nothing on the server knew a device's app version, and a "your pack
-- is here" push to a build with no pack UI is a broken promise. NULL = registered by a build that
-- predates the column, which is exactly the population the push must skip.
alter table public.device_tokens add column if not exists app_build int;
