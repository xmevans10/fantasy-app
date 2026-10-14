-- Hold golf out of user-created content until the release gate opens.
--
-- `tools/ingest/validate.WIRE_SAFE_SPORTS` keeps golf out of every MINTED table, but
-- `community_puzzles` is written by clients directly, so a build that knows `Sport.golf` could
-- publish a golf board the moment it ships. Installed builds that predate golf decode the
-- community feed as one array of `Sport`, and a single unknown sport fails the whole fetch.
-- The client hides golf from its create pickers too; this is the server-side backstop so a
-- client bug cannot reopen the hole.
--
-- `versus_challenges` needs no equivalent: `puzzle_id` references `puzzles`, which holds no golf
-- rows while the mint gate is closed.
--
-- TO RELEASE GOLF: drop this constraint in the same change that adds golf to WIRE_SAFE_SPORTS.

alter table public.community_puzzles
  drop constraint if exists community_puzzles_sport_released;
alter table public.community_puzzles
  add constraint community_puzzles_sport_released check (sport <> 'golf');
