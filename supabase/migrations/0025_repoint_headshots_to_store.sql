-- Widen `repoint_puzzle_headshots` so every minted board points at OUR headshot store.
--
-- 0015 built this as a BLANK-filler: "only overwrites a blank slot with a non-blank
-- replacement". That was the right conservative rule for the bug it fixed, but it leaves a
-- second, larger class untouched — a board frozen with a raw provider CDN URL is not blank, so
-- it is skipped forever. Measured live 2026-09-06: 247 boards (171 keep4, 76 journeyman) carry
-- at least one hotlinked headshot — wikimedia, static.www.nfl.com or a.espncdn.com.
--
-- Why that matters beyond tidiness: those URLs are outside our control and some of them are
-- the league's GENERIC PLACEHOLDER, which returns HTTP 200 with a real image, so no liveness
-- check ever flags it. A user reported exactly this — Randall Cunningham's Journeyman board
-- rendering the faceless NFL helmet silhouette while a real photo of him sat in our Storage
-- bucket the whole time (`.../player-headshots/nfl/292f94833ae306fbafd8.jpg`).
--
-- Two changes, both strictly improvements:
--   1. The predicate becomes "blank OR not from our store" instead of "blank".
--   2. A replacement is only ever accepted if it IS from our store, so this can never
--      downgrade a good value, and a board already pointing at our store is never touched.
--
-- Plus a fallback the old join could not express: journeyman resolved only against the
-- player's `-career` row, and 5,196 career rows across the catalog are photo-less while the
-- same player's SEASON rows carry a real photo (`career._best_headshot` derives the career
-- headshot from the provider gather, which for pre-2000 NFL players has no photo at all, so
-- it writes '' back every night). Now it falls back to that player's newest season row.

create or replace function public.repoint_puzzle_headshots(batch_size int default 2000)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  keep4_fixed bigint := 0;
  journeyman_fixed bigint := 0;
  store_marker constant text := '/storage/v1/object/public/player-headshots/';
begin
  -- Best store-hosted photo per player, keyed by the id stem shared across that player's
  -- season rows and their career row (`nfl-randall-cunningham-1998` / `-career`).
  create temp table _best_shot on commit drop as
  select regexp_replace(id, '-(career|[0-9]{4}(-wk[0-9]{2})?)$', '') as stem,
         (array_agg(headshot order by season_year desc nulls last))[1] as headshot
  from player_seasons
  where position(store_marker in coalesce(headshot, '')) > 0
  group by 1;
  create index on _best_shot (stem);

  -- ── keep4: one photo per player slot ────────────────────────────────────────────────────
  with candidates as (
    select id, content
    from puzzles
    where format = 'keep4'
      and exists (
        select 1 from jsonb_array_elements(content->'players') elem
        where position(store_marker in coalesce(elem->>'headshot', '')) = 0
      )
    limit batch_size
  ),
  rebuilt as (
    select c.id,
      jsonb_set(c.content, '{players}',
        (select jsonb_agg(
           case when position(store_marker in coalesce(elem->>'headshot', '')) = 0
                     and coalesce(b.headshot, '') <> ''
                then jsonb_set(elem, '{headshot}', to_jsonb(b.headshot))
                else elem end
           order by ord)
         from jsonb_array_elements(c.content->'players') with ordinality as t(elem, ord)
         left join _best_shot b
           on b.stem = regexp_replace(elem->>'id', '-(career|[0-9]{4}(-wk[0-9]{2})?)$', ''))
      ) as new_content
    from candidates c
  ),
  changed as (
    select r.id, r.new_content
    from rebuilt r join puzzles p on p.id = r.id
    where r.new_content is distinct from p.content
  )
  update puzzles p set content = c.new_content
  from changed c where p.id = c.id;
  get diagnostics keep4_fixed = row_count;

  -- ── journeyman: one photo per board ─────────────────────────────────────────
  with candidates as (
    select id, content
    from puzzles
    where format = 'journeyman'
      and position(store_marker in coalesce(content->>'headshot', '')) = 0
    limit batch_size
  ),
  matched as (
    select c.id, b.headshot
    from candidates c
    join _best_shot b
      on b.stem = regexp_replace(c.content->>'id', '-journeyman$', '')
    where coalesce(b.headshot, '') <> ''
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
