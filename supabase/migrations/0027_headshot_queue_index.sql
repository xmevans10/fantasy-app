-- Queue seeding must not scan the entire catalog on every pass. Production's
-- sequential scan timed out; index only the external URLs the seed can consume.
create index if not exists player_seasons_unhosted_headshot_idx
on public.player_seasons (headshot) include (sport)
where coalesce(headshot, '') <> ''
  and headshot not like '%/storage/v1/object/public/player-headshots/%';
