-- `headshot_repoint_batch` (0007-era) only ever writes `player_seasons.headshot`. Every minted
-- Keep4/Journeyman board FREEZES its own copy of the URL at mint time
-- (`content.players[].headshot` for keep4, top-level `content.headshot` for journeyman) — a
-- gotcha `apply_headshot_ledger`'s docstring already names for FRESH mints (it rewrites
-- `RawSeason` before generation so a newly-minted board inherits the fixed URL). What nothing
-- has ever done is retroactively fix a board that already exists: once `player_seasons` gets a
-- real photo from a later backfill, an already-minted puzzle whose content still says '' just
-- stays that way forever — the catalog looks fixed, the app doesn't.
--
-- Found investigating a live report (xmevans10, 2026-09-03 blitz run): two WR-themed Keep4
-- boards had ALL 8 players blank (`gen-wr-2000-sub6-00-daily-20260825`,
-- `gen-wr-2000-mr-irrelevant-00`) — Blitz draws randomly from the whole Keep4 pool
-- (`BlitzRoundLoader.warm`/`allKeep4`), not just today's daily, so either could be served.
-- Measured scope across the whole `puzzles` table same day: NFL keep4 is 154 boards, 5 entirely
-- blank and 110 more partially blank — 390 blank player slots total. Themes like "Day 3 picks"
-- and "Mr. Irrelevant" (literally the draft's last pick) select obscure players by construction,
-- which is exactly the group whose only source was the league CDN's placeholder — cleared to ''
-- by repoint, and never recovered because nothing repointed the puzzle after the fact.
--
-- Fix: a puzzle-content repoint pass, the missing counterpart to `headshot_repoint_batch`.
-- Joins back to `player_seasons` by id (keep4: `content.players[].id` matches directly;
-- journeyman: `content.id` is `<player-id>-journeyman`, `player_seasons`' equivalent row is
-- `<player-id>-career` — verified live, e.g. `nfl-aaron-kampman-journeyman` -> a real Storage URL
-- sitting on `nfl-aaron-kampman-career` that was never propagated). Only overwrites a blank slot
-- with a non-blank replacement — never touches a board that already has something, so a curated
-- non-placeholder photo can't be clobbered.

create or replace function public.repoint_puzzle_headshots(batch_size int default 2000)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  keep4_fixed bigint := 0;
  journeyman_fixed bigint := 0;
begin
  with candidates as (
    select id, content
    from puzzles
    where format = 'keep4'
      and exists (
        select 1 from jsonb_array_elements(content->'players') elem
        where coalesce(elem->>'headshot', '') = ''
      )
    limit batch_size
  ),
  rebuilt as (
    select c.id,
      jsonb_set(c.content, '{players}',
        (select jsonb_agg(
           case when coalesce(elem->>'headshot', '') = '' and coalesce(ps.headshot, '') <> ''
                then jsonb_set(elem, '{headshot}', to_jsonb(ps.headshot))
                else elem end
           order by ord)
         from jsonb_array_elements(c.content->'players') with ordinality as t(elem, ord)
         left join player_seasons ps on ps.id = elem->>'id')
      ) as new_content
    from candidates c
  ),
  changed as (
    select r.id, r.new_content
    from rebuilt r
    join puzzles p on p.id = r.id
    where r.new_content is distinct from p.content
  )
  update puzzles p set content = c.new_content
  from changed c
  where p.id = c.id;
  get diagnostics keep4_fixed = row_count;

  with candidates as (
    select id, content
    from puzzles
    where format = 'journeyman'
      and coalesce(content->>'headshot', '') = ''
    limit batch_size
  ),
  matched as (
    select c.id, ps.headshot
    from candidates c
    join player_seasons ps
      on ps.id = regexp_replace(c.content->>'id', '-journeyman$', '-career')
    where coalesce(ps.headshot, '') <> ''
  )
  update puzzles p
     set content = jsonb_set(p.content, '{headshot}', to_jsonb(m.headshot))
    from matched m
   where p.id = m.id;
  get diagnostics journeyman_fixed = row_count;

  return jsonb_build_object('keep4_fixed', keep4_fixed, 'journeyman_fixed', journeyman_fixed);
end;
$$;

revoke all on function public.repoint_puzzle_headshots(int) from public, anon, authenticated;
grant execute on function public.repoint_puzzle_headshots(int) to service_role;
