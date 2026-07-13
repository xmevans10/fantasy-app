# Handoff — continue BallIQ development (2026-07-12, session C)

You are the orchestrator agent for this repo. Read `CLAUDE.md`, `AGENTS.md`, and skim
`docs/BALLIQ_SPEC.md` §7–§9 first. This supersedes `HANDOFF-next-agent-2026-07-12b.md`
(that session's M19/M20 work is fully landed and pushed, commit `b60c829`). This session
did two things: a harness overhaul, and deep research (no code yet) toward a broader
soccer data provider. **The tree has uncommitted changes — see §0.**

## 0. FIRST ACTION — review and commit the harness overhaul

Uncommitted as of this handoff:
- `CLAUDE.md` (modified) — the App Store Connect/TestFlight section was extracted into a
  skill (see below); a new short section points at the two custom subagents.
- `.claude/agents/balliq-swift-feature.md` (new) — Sonnet subagent for scoped SwiftUI
  feature/bugfix work with disjoint file ownership (encodes the repeated brief from
  `HANDOFF-next-agent-2026-07-12.md` §2: pbxproj rule, RepositoryContainer-only rule,
  design-system vocabulary, own-DerivedData verification bar).
- `.claude/agents/balliq-data-provider.md` (new) — Sonnet subagent for ingest-provider
  work (stdlib-runtime/refresh-split rule, caching via `providers.http`, M16 headshot
  contract, the "grading is a sacred invariant, don't add scored stat keys without being
  asked" guardrail, pytest verification bar).
- `.claude/skills/testflight-release/SKILL.md` (new) — the release/signing content moved
  out of CLAUDE.md so it only loads when release work is actually happening.

**Why hooks/settings.json were NOT touched:** the auto-mode permission classifier blocked
writing a `.claude/hooks/*` script and a checked-in `.claude/settings.json` as
"self-modification" of agent-controlling config that the user hadn't explicitly
authorized for that exact change. The user then explicitly said to skip hooks entirely
(keep the pbxproj rule as advisory prose only) but did authorize the subagents + skill
above. If you want deterministic hooks (e.g. actually blocking pbxproj edits rather than
just telling agents not to), that needs the user's explicit sign-off again, in-session —
don't infer it from this note.

Review the diff, then commit (user has not seen these applied yet — this is new).

## 1. Soccer data: research complete, no code written yet

The user asked to broaden soccer's historical depth. Prior handoffs scoped this as "use
the `worldfootballR_data` mirror, Big-5, 2017/18+" — that turned out to be worth
revisiting. Live-verified findings this session (don't re-derive, but don't blindly
trust without re-checking if much time has passed):

- **`worldfootballR_data`'s tracked `data/` folder is a dead 2022-11 snapshot.** The same
  repo's **GitHub Releases** assets (`releases/download/fb_big5_advanced_season_stats/
  big5_player_*.rds`) are current (Sept 2025 for `standard`/`shooting`, Oct 2024 for
  `keepers`/`defense`/etc.) and cover **2010–2026** for box-score stats
  (`big5_player_standard.rds`, `big5_player_keepers.rds` — real saves/clean-sheets, not
  just goals/assists), narrowing to **2018+** only for Opta-tracking-dependent metrics
  (`passing`, `defense`, `possession`, `gca`). If you go this route, fetch from Releases,
  not the repo's `data/` directory.
- **The user then redirected to ESPN via the `soccerdata` Python package** (explicitly:
  "use soccerdata", twice). Verified live:
  - `soccerdata.ESPN` hits `site.api.espn.com/apis/site/v2/sports/soccer/...` — the same
    public, keyless, undocumented-but-stable JSON API family this repo already trusts
    for NBA (`providers/espn_nba.py` uses `site.web.api.espn.com`). Not a ToS-risk
    scrape; same category as existing precedent.
  - Big-5 league floor confirmed live: **~2001-02** (`eng.1`, `ger.1`, `fra.1` verified
    with real match data; `esp.1`/`ita.1` similar). That's ~10 years deeper than
    `transfermarkt_soccer.py`'s existing `MIN_SEASON = 2012`.
  - `espn.read_lineup(match_id=...)` returns genuine per-player-per-match goalkeeper box
    score: `saves`, `shots_faced`, `goals_conceded` (verified: real non-null values for
    keepers, NaN for outfield players, in a live-fetched 2003 EPL match). This is real
    depth beyond `transfermarkt_soccer.py`'s clean_sheets (which is *itself* derived from
    scoreline, same underlying signal, just less granular).
  - **No bulk per-season endpoint exists** — confirmed by reading `soccerdata`'s own
    source (`espn.py` only has `read_schedule`/`read_matchsheet`/`read_lineup`, no
    season-stats reader). Discovery is 3-tier per (league, season): one `read_schedule()`
    call (itself ~1 + ~40 matchday calls internally) lists ~380 match ids, then one
    `read_lineup(match_id=...)` per match. **Big-5 × ~24 seasons × ~380 matches ≈ tens of
    thousands of API calls — a multi-hour one-time backfill**, same category as this
    repo's existing "MLB back to 1901" precedent, not something to run synchronously in
    one turn.
  - Quirk to design around: `read_lineup`'s `position` column is the **on-field kickoff
    role** ("Center Right Defender", "Right Back", ...) and is literally the string
    `"Substitute"` for anyone who didn't start that match — not usable per-match for
    bench players. Resolve each player's GK/DF/MF/FW bucket **once, globally**, from the
    mode of their non-`"Substitute"` labels across all their matches, then keyword-bucket
    (`"goalkeeper"→GK`, `"back"/"defen"→DF`, `"midfield"→MF`, else `→FW`).
  - `goals_conceded` in the lineup row is a **team** stat (shared by every player on that
    side, that match) — use it directly for `clean_sheets` (== 0), no scoreline lookup
    needed (unlike `transfermarkt_soccer.py`, which derives it from `games.csv`).
  - `team` in the lineup dataframe is the full display name ("Manchester City"), not a
    code — reuse `transfermarkt_soccer._short_code(name)` (already handles boilerplate
    stripping, already produces MCI/MUN/RMA/etc.) rather than writing a second version.
  - No portrait/headshot field anywhere in the ESPN payloads checked — resolve via the
    shared `providers.wikimedia.headshot(name, context="soccer")`, same M16 contract as
    every other provider (drop the player if no confident match).
  - **Scoring-invariant decision already made, don't relitigate without cause**: v1
    output should keep the **existing** stat shape (`appearances`, `goals`, `assists`,
    `clean_sheets` — same `CSV_FIELDS` as `transfermarkt_soccer.py`) so it merges under
    the current soccer scoring formula with zero `grade.py`/`GradeFormula.swift`/
    `ScoringRule.swift` changes. The real `saves`/`shots_faced` depth is genuinely richer
    than what's scored today — note it as a fast-follow (a scoring-formula change is a
    "sacred invariant" per AGENTS.md §4/SPEC §4, needs synchronized cross-file changes +
    locked-value tests, and is a product decision, not just a data-pipeline one) rather
    than silently expanding scope.
- **`soccerdata` is pip-installed in `.venv`** (confirmed: `import soccerdata` resolves)
  but **not yet added to `requirements.txt`**. Follow the existing optional-dependency
  convention exactly (see the commented-out `pyarrow`/`pyespn` lines in
  `tools/ingest/requirements.txt`): lazy `import soccerdata` inside `refresh()` only,
  commented-out `# soccerdata>=1.13` line with the same "refresh-only, lazily imported"
  framing, `load_seasons()` stays stdlib-only.
- **`tools/ingest/data/soccer_transfermarkt_seasons.csv` already covers full-squad
  2012+** (74,921 rows, wired into `main.py`, real clean sheets derived from scoreline).
  A new `espn_soccer.py` is additive depth (pre-2012 history + genuine save stats), not a
  replacement — merge it the same way `transfermarkt_soccer.load_seasons()` is merged in
  `main.py`'s soccer block (dedup by `player_id`, existing/more-curated sources win).

### Suggested next steps
1. Use the **`balliq-data-provider` subagent** (new this session, see §0) to build
   `tools/ingest/providers/espn_soccer.py` — the design above is essentially a full spec;
   paste this section into its brief along with `transfermarkt_soccer.py`'s `_short_code`
   signature and `wikimedia.headshot`'s signature.
2. Validate on a small scope first (one league, 2-3 recent seasons) before committing to
   the full ~24-season × 5-league historical backfill — confirm aggregation correctness
   and headshot resolution, THEN kick off the full backfill (likely backgrounded, given
   the multi-hour runtime).
3. Wire into `main.py`, update `requirements.txt`, write `tests/test_espn_soccer.py`
   (pure aggregation functions, no pandas — mirror `test_transfermarkt_soccer.py`'s style).

## 2. Prioritized backlog (carried over, still open)

1. **Human/TestFlight QA of M19+M20 signed-in surfaces** (agent can't do real
   Apple/Google sign-in): friends flow, FRIENDS leaderboard, onboarding claim sheet.
2. Soccer data depth — in progress, see §1 above.
3. **M14 Spanish localization** — untouched, pure app-code, parallelizes by feature folder.
4. **M5 Phase F** — 8-week rating seasons (SPEC §8/§9).
5. External hand-offs still pending (user, not agent): APNs key material, Paid
   Applications agreement / ASC products for M5 Phase B.

## 3. Method (unchanged, now with named subagents)

Same orchestration pattern as before: recon yourself, orchestrator owns shared plumbing
(migrations via Supabase MCP + mirror to schema.sql, `RepositoryContainer`, shared
views), dispatch **`balliq-swift-feature`** / **`balliq-data-provider`** subagents (new
this session — see §0) instead of hand-writing the brief from scratch, integration pass +
screenshots yourself, report verified vs. assumed.

Gotchas from prior sessions, still true: `simctl uninstall` does NOT clear UserDefaults
(cfprefsd caches by bundle id — `defaults delete` before fresh-install screenshots);
`site.web.api.espn.com`/`site.api.espn.com` are trusted keyless public APIs already used
in this pipeline, not a scraping risk.
