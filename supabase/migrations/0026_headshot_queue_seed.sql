-- Seed the headshot work queue from the catalog, idempotently.
--
-- `headshot_assets` IS the work queue: `headshots.claim_pending` selects `status = 'pending'`
-- rows from it and never looks at `player_seasons` at all. That is deliberate and worth keeping
-- (18 concurrent deep-OFFSET scans over 380k catalog rows produced 57014 statement timeouts,
-- which is what the queue replaced) but it left the queue with no way to GROW. It was populated
-- once, by hand, and nothing since has put a newly-discovered player's headshot source into it.
--
-- So the pipeline had a silent hole exactly where it looks busiest: `headshot-backfill.yml`
-- resets errors, fans out eight shards, runs four backfills and a repoint every week, and every
-- one of those stages only ever reprocesses sources that were already known. A player ingested
-- after the one-time seed sat on a raw provider URL forever, invisible to the coverage summary
-- the convergence loop reads, because a row that is not in the ledger is not `pending` either.
-- The 7,590 unqueued sources found on 2026-09-07 were drained by hand; nothing stopped the next
-- 7,590 accumulating behind them.
--
-- Set-based and server-side for the same reason the claim is: this is one pass over the catalog
-- to find what is missing, not 380k rows pulled through PostgREST.
create or replace function public.headshot_queue_seed(dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  candidates bigint;
  inserted   bigint := 0;
begin
  -- One pass, one copy of the candidate set. `src` is every distinct source the catalog still
  -- points at that is not already rehosted and is not already in the ledger; `ins` enqueues it.
  -- A dry run evaluates `src` and inserts nothing, so the count it reports is the count a real
  -- run would enqueue.
  with src as (
    select p.headshot as source_url,
           min(p.sport) as sport,
           -- Stable 0..63 bucket so N parallel workers can take `bucket % N == i` and never
           -- overlap without coordinating. md5's first byte rather than `hashtext` only because
           -- it cannot return a value whose abs() overflows int4.
           (get_byte(decode(md5(p.headshot), 'hex'), 0) % 64)::smallint as shard
      from player_seasons p
     where coalesce(p.headshot, '') <> ''
       -- Rows cleared to '' are excluded above on purpose: '' is this pipeline's proven "there
       -- is no photo for this player" (see headshot_repoint), not a source awaiting a fetch.
       and p.headshot not like '%/storage/v1/object/public/player-headshots/%'
       and not exists (select 1 from headshot_assets a where a.source_url = p.headshot)
     group by p.headshot
  ), ins as (
    insert into headshot_assets (source_url, sport, status, shard)
    select source_url, sport, 'pending', shard from src where not dry_run
    -- `do nothing`, never `do update`: a source already in the ledger has a status that was
    -- earned (ok / placeholder / missing / error), and re-seeding must not reopen it.
    on conflict (source_url) do nothing
    returning 1
  )
  select (select count(*) from src), (select count(*) from ins)
    into candidates, inserted;

  return jsonb_build_object('dry_run', dry_run, 'candidates', candidates, 'enqueued', inserted);
end;
$$;

revoke all on function public.headshot_queue_seed(boolean) from public, anon, authenticated;
grant execute on function public.headshot_queue_seed(boolean) to service_role;
