-- Golf joins the sport set.
--
-- Same shape as 0024 (hockey + F1): no DDL for the sport itself, since every `sport` column
-- is plain `text` with no CHECK constraint. The one place a sport list lives inside a function
-- BODY is the Grid membership-index cache refresher, where a missing entry fails silently, so
-- it is widened here. 0016's bot-ladder seed is deliberately left alone for the reason 0024
-- gives: it is a one-time seed of already-populated rungs.
--
-- Golf puzzles stay unminted until `tools/ingest/validate.WIRE_SAFE_SPORTS` opens for it, so
-- until then this computes an index nothing reads. That is harmless and means opening the gate
-- needs no further migration.

create or replace function public.refresh_grid_membership_index_cache()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sport text;
begin
  foreach v_sport in array array['nfl','nba','baseball','soccer','tennis','hockey','f1','golf'] loop
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
