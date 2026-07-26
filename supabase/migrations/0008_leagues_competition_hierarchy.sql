-- Applied live 2026-07-26 via the Supabase MCP. Idempotent — schema.sql stays the source of truth.
--
-- `leagues` was keyed (sport, league) where `league` is a COUNTRY label ("Germany"), so a country
-- could hold exactly ONE competition row. That is the structural reason "let me pick 2.
-- Bundesliga" was impossible: not a UI gap, a model gap — inserting Bundesliga and 2. Bundesliga
-- in one upsert fails with 21000 ("ON CONFLICT DO UPDATE command cannot affect row a second
-- time"). `country`/`tier`/`espn_slug` add the missing middle layer of the FIFA-style
-- Nation -> League -> Club hierarchy, and the PK widens to include `tier` so a full division
-- ladder fits. `league` deliberately stays the country label that `teams`/`player_seasons`
-- already join on, so nothing downstream has to move yet.
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
