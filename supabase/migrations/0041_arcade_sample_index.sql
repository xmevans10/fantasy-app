-- Match the bounded arcade sample's season-only filter before scanning ordered ids.
-- NFL has enough weekly rows that filtering them after an index scan can exceed anon's 3s limit.
create index if not exists player_seasons_arcade_sample_idx
  on public.player_seasons (sport, id)
  where not career and week is null;
