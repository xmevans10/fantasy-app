-- Bots know things, not just how to play (see BallIQ/Models/BotKnowledge.swift).
--
-- `style` (migration 0019) reshapes the BOARD's difficulty signal — a grade gap, a rarity star,
-- a clue index. None of those know which decade a card is from or which sport it belongs to, so
-- every character on the roster was equally sharp on 1974 and 2024, and equally at home in the
-- NBA and the Eredivisie. The written characters never were: Ray "couldn't tell you a single
-- advanced metric", Marisol "could not name three players on any other team", and Solomon's
-- style line promises he is "unbeatable on the forgotten decades, human on this one". This is
-- the column that makes those sentences true of the opponent the player actually faces.
--
-- `knowledge` is a GAMEPLAY property, exactly as `style` is: `BotSolver` reads it on every
-- decision and `tools/ingest/ladder.py` solves each rung's `bot_skill` against it. An empty
-- object is the identity — a bot without a profile plays precisely as it did before this
-- existed, which is what lets the column ship ahead of the ladder being re-calibrated.
--
-- Shape (all keys optional; unknown keys are ignored by the client's lenient decoder):
--   {"era_from": 1990, "era_to": 2008, "era_fade": 0.12,
--    "sports": {"nba": -0.1}, "other_sports": 0.2, "fame_bias": -0.25}
--
-- Written by `tools/roster/sync.py` from `tools/roster/roster.json`, which is the source of
-- truth and validates the shape before anything reaches this table. Do not hand-edit rows.
alter table public.bots
  add column if not exists knowledge      jsonb not null default '{}'::jsonb,
  -- The profile stated to the player BEFORE the duel, for the same reason `style_line` exists:
  -- a difficulty the player cannot anticipate is not a personality, it is an unexplained loss.
  add column if not exists knowledge_line text  not null default '';
