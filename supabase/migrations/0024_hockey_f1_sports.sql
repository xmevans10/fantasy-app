-- M31: hockey + F1 join the sport set.
--
-- No DDL is needed for the sport itself: `player_seasons.sport`, `puzzles.sport`, the
-- `*_history.sport` columns and `teams.sport` are all plain `text` with no CHECK
-- constraint, so a new sport is a new string. What DOES need changing is the one place a
-- sport list is baked into a function BODY, where a missing entry fails silently rather
-- than erroring: the Grid membership-index cache refresher (0014) loops over a literal
-- array, so without this hockey and F1 would never get a cached index and their Grid
-- boards would time out under anon exactly the way `schema-index-drift` describes.
--
-- Deliberately NOT touched here: 0016's bot-ladder seed, whose
-- `(array['nfl',...])[1 + ((r - 1) % 5)]` is a ONE-TIME seed of 30 already-populated rungs.
-- Widening it now would reshuffle which sport every existing rung tests, which is a live
-- content change rather than a wiring fix. The Python side (`tools/ingest/ladder.py`'s
-- SPORTS) already knows about both new sports for future board-pool builds.

create or replace function public.refresh_grid_membership_index_cache()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sport text;
begin
  foreach v_sport in array array['nfl','nba','baseball','soccer','tennis','hockey','f1'] loop
    insert into public.grid_membership_index_cache (sport, version, payload, computed_at)
    values (v_sport, 1, public.grid_membership_index_compute(v_sport, 1), now())
    on conflict (sport, version) do update
      set payload = excluded.payload, computed_at = excluded.computed_at;

    insert into public.grid_membership_index_cache (sport, version, payload, computed_at)
    values (v_sport, 2, public.grid_membership_index_compute(v_sport, 2), now())
    on conflict (sport, version) do update
      set payload = excluded.payload, computed_at = excluded.computed_at;
  end loop;
end;
$$;
