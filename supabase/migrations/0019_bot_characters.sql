-- 0019 — bots become characters. Applied live to nhccgufqwndtoasdbkhc 2026-08-14.
--
-- They shipped as a name, an emoji and a skill number, which is a difficulty setting wearing a
-- hat. Four columns turn each into someone:
--
--   style          HOW they play, not how well — see BallIQ/Models/BotStyle.swift
--   style_line     that style stated to the player BEFORE the run
--   backstory      who they are
--   palette        their colourway, as a design-token key rather than a hex
--   voice          what they say, keyed by the moment
--   favorite_teams who they support, as {sport, abbr} pairs rendered by TeamAbbrChip
--
-- `style` is the load-bearing one and is NOT decoration: it changes `BotSolver`'s policy, so two
-- bots at identical `bot_skill` produce visibly different runs. That also means it feeds the
-- difficulty calibration — `tools/ingest/ladder.py` models each style and solves `bot_skill`
-- against it, and `BallIQTests/LadderCurveTests` re-measures with the real Swift solver.
--
-- The full content (six characters) is applied by the two migrations this file records; see the
-- live `bots` table for the authored copy, which is content rather than schema.
alter table public.bots
  add column if not exists style          text not null default 'consistent',
  add column if not exists style_line     text not null default '',
  add column if not exists backstory      text not null default '',
  add column if not exists palette        text not null default 'electric',
  add column if not exists voice          jsonb not null default '{}'::jsonb,
  add column if not exists favorite_teams jsonb not null default '[]'::jsonb;

alter table public.bots drop constraint if exists bots_style_domain;
alter table public.bots add constraint bots_style_domain check (style in
  ('overeager', 'methodical', 'consistent', 'deepCuts', 'slowBurn', 'prescient'));

comment on column public.bots.favorite_teams is
  'Ordered [{sport, abbr}] rendered as real crests by TeamAbbrChip. Characterisation, not data.';
