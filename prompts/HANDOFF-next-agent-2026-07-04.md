# Playbook — handoff for the next agent (as of 2026-07-04)

**Read this whole file first**, then [README.md](README.md) for shared architecture, build/verify
commands, and hard constraints. This file supersedes
[HANDOFF-fable-milestones.md](HANDOFF-fable-milestones.md) — that file is now stale (it describes
M12/M13/M15 as open; all three shipped their app-side work on 2026-07-02, per the status table at
the top of README.md). Keep this file as the current orientation point; retire it in turn once its
contents are done or absorbed elsewhere.

## What just happened (M17 close-out, this session)

M17 (puzzle grain + community career-grain creation) is now **fully shipped, including its
production hand-off** — not just the app code:
- `catalog_rows()` includes career rows; `CatalogSeason` (Swift) decodes `career`/`firstYear`/
  `lastYear`; `Keep4Theme.isCreatable` admits `grain=="career"`; `CreateKeep4View` scopes search to
  career-only when a career template is active and bakes the real grain at publish.
- **The live Supabase migration landed**: `player_seasons` got `headshot`/`career`/`first_year`/
  `last_year` columns (`headshot` was a separate pre-existing gap, fixed in the same pass — the
  create-flow catalog's remote `select` never actually requested it before this).
- **The full pipeline was re-run against production** (`python -m tools.ingest.main --upsert
  --catalog`) to populate career rows and backfill headshots on the existing season rows.
  Confirmed live as of 2026-07-04: **21,927 season rows (21,884 with headshots) + 3,323 career
  rows (100% with headshots)**. Re-verify before assuming this is still fresh:
  ```sql
  select career, count(*), count(*) filter (where headshot <> '') as with_headshot
  from public.player_seasons group by career;
  ```
- 93 Python tests + 129 Swift tests green (one pre-existing, documented content-drift failure,
  unrelated — see "known issues" below). Verified end-to-end in the iPhone 15 simulator against
  the **live, now-populated** catalog: the NBA career template returns real results with correct
  multi-year subtitles (e.g. "LeBron James LAL · 2004-2026"), a season template shows no
  regression. Career search is no longer the empty-fallback state described in the original M17
  work — that was only true before this session's DB push.

## New standing rule: DB ops execute directly, not just as a hand-off

**This is now written into `/Users/xanderevans/Documents/fantasy-app/CLAUDE.md`** (checked into
the repo, auto-loaded) — read it. Short version: the Supabase MCP tools in this environment
(`apply_migration`/`execute_sql`, project_id `nhccgufqwndtoasdbkhc`, org "ballknowledge") are
**confirmed authenticated and working as of 2026-07-04** — this is a change from the prior
handoff's note that they were "currently unauthorized/disconnected." Don't reflexively write
"needs the user to authorize the Supabase connector" as a hand-off anymore; check first
(`list_projects`), and if connected, just run the migration or query yourself. Data pushes go
through this repo's own `python -m tools.ingest.main --upsert [--catalog] [--write-fallback]`
using `tools/ingest/.env`'s `SUPABASE_SERVICE_ROLE_KEY` (present in this environment). Reserve
actually asking first for destructive ops (drop/delete/truncate, revoking RLS other rows depend
on, key rotation) — additive schema changes and merge-duplicate upserts are fair game to just run.

**Concretely, this unblocks several long-standing "unapplied — hand-off" items** that earlier
milestone files (M11, M12, M13, M15) all deferred for exactly this reason. Verified against the
live DB just now (2026-07-04) — none of these are applied yet:
- `profiles.is_admin` column + review RLS (M12's schema.sql section) — moderation queue UI already
  exists (`ModerationQueueView`) and is gated on this column client-side, but the column itself
  isn't live, so no one can actually be flagged admin today.
- `weekly_play_counts` RPC (M13's schema.sql section) — Community's "This Week" trending sort has
  a client-side graceful fallback, but isn't using the real weekly-windowed ranking without this.
- `public.events` table + insert-only RLS (M15's schema.sql section) — `AnalyticsClient` exists in
  the app and is presumably already calling this table; **confirm whether it's silently failing
  every call** since the table doesn't exist yet. This is worth checking first — it may mean M15's
  analytics have been collecting nothing since it "shipped."
- `supabase/migrations/0001_schedule_edge_functions.sql` (M11) — still has `<PROJECT_URL>`/
  `<SERVICE_ROLE_OR_ANON_KEY>` placeholders (a real secret substitution, not just "apply the SQL"),
  and needs the `pg_cron` extension enabled (confirmed **not installed** on the live project as of
  2026-07-04: `select count(*) from pg_extension where extname='pg_cron'` → 0). Enabling extensions
  is itself worth double-checking is safe/expected before flipping it on.

None of the above were applied in this session — they were out of scope for the M17 ask that
prompted this handoff. But given the DB-ops rule above, applying all four is now a small, mostly
mechanical task for whoever picks this up next (or the current session, if the user asks) — much
smaller than when they were written, since "get the user to authorize Supabase" is no longer the
blocker. Read each milestone file's own schema.sql section before applying — M11's needs real
secret values substituted, not a blind copy-paste.

## Remaining real feature work

Per README.md's status table, only two milestones have substantive app-side work left:

### [M5 — Monetization + breadth](M5-monetization-breadth.md)
StoreKit 2 Pro subscription + format packs, three new formats (Over/Under, Draft & Spin, The Grid),
8-week season structure. Breadth/scoring pieces already shipped; **monetization itself hasn't been
started**. Has a real external hand-off (App Store Connect product config, paid-apps agreement) —
start the buildable parts (StoreKit 2 client code against a local `.storekit` config, the new
formats, season math) without waiting on that.

### [M14 — Accessibility & localization](M14-accessibility-and-localization.md)
VoiceOver pass shipped. **Spanish localization is untouched** — a separate, standalone task that
doesn't block or depend on anything else. Good candidate to run in parallel with M5.

## Known issues (don't re-discover these)

- `test_content_drift.py::test_bundled_wr_grades_match_current_formula` fails on purpose — bundled
  `keep4_puzzles.json`'s "Elite WR receiving seasons" theme has drifted ~23 points from the current
  `grade.py` formula for one golden player. Pre-existing, tracked, not something recent work broke.
  Regenerating the bundle (`--write-fallback`) fixes it but is out of scope unless the user asks.
- The bundled catalog fallback (`BallIQ/Data/player_seasons.json`) is intentionally
  season-only (M17 decision) — don't "fix" this by adding career rows to it; career creation is
  live-catalog-only by design.
- `DebugLaunch.createTemplateKey` (`-screenshotCreateTheme <key>`) now exists for non-interactive
  verification of any Create-flow theme template via
  `xcrun simctl launch <sim> com.balliqfantasy.app -screenshotCreate -screenshotCreateTheme <key>` —
  reuse this instead of re-inventing UI automation for template-specific screenshots.

## Build/verify (unchanged)

- Build: `xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' -derivedDataPath build build`
- Test: same with `test` (129 Swift tests as of this handoff)
- Python: `.venv/bin/python -m pytest tools/ingest/tests -q` (93 passing, 1 pre-existing expected failure)
- Screenshot UI non-interactively via `-screenshotGame`/`-screenshotResult`/`-screenshotWhoAmI[Result]`/
  `-screenshotCreate[Theme <key>]`/`-screenshotCommunity`/`-screenshotBrowse`/etc. — see
  [DebugLaunch.swift](../BallIQ/DebugLaunch.swift) for the full list.
