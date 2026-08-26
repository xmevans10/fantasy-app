# Handoff — M27 follow-ups + next ASC build

You are picking up the BallIQ/Playbook repo at `/Users/xanderevans/Documents/fantasy-app`
immediately after M27 (Puzzle Blitz) shipped. Read `CLAUDE.md` and `AGENTS.md` first; load the
`testflight-release` skill before touching App Store Connect.

---

## State as of 2026-08-25 (verified live, not assumed)

**Git** — branch `m27-puzzle-blitz`, clean tree, **4 commits ahead of `main`, never pushed**:

```
73067d4  Add the Playbook social kit and audit the App Store screenshots
dcb1c14  Record the 1.7.0 release and the two traps that delayed it
8b6ef7c  Declare the Blitz debug flags in DebugLaunch's release half; cut 1.7.0 build 40
0ab8bbf  Add Puzzle Blitz — one clock, every format, one score at the end
```

**App Store Connect** — app id `6785275045`, bundle `com.balliqfantasy.app`:

| Thing | State |
|---|---|
| Version `1.7.0` (`ccba424b-e2f8-4c31-b71d-321eac841c97`) | **`WAITING_FOR_REVIEW`** — in Apple's queue since 2026-08-25 16:50 UTC |
| Build 40 | `VALID`, attached to 1.7.0 |
| Live submission `69da482e-8283-4c6b-8c62-0f36d0d73550` | `WAITING_FOR_REVIEW`, **exactly 1 item** (the version — no IAPs riding along) |
| pbxproj | `MARKETING_VERSION = 1.7.0`, `CURRENT_PROJECT_VERSION = 40` |

1.7.0 ships M23 live duels + M25 no-timers + M27 Puzzle Blitz together. It had been stuck in
`INVALID_BINARY` since 2026-08-24 because build 39 carried `CFBundleShortVersionString` 1.6.0
against a 1.7.0 version record — fixed by bumping the pbxproj, which is why the marketing
version moved in commit `8b6ef7c`.

---

## 🔴 The constraint that governs everything below

**Apple allows exactly one open review submission per app, and 1.7.0 is occupying it.**

You therefore **cannot** create and submit a new App Store version until 1.7.0 leaves the queue
(approved, rejected, or developer-rejected). You **can** upload builds to TestFlight freely.

Do **not** cancel `69da482e` to re-cut a build unless the user explicitly asks. Cancelling costs
1.7.0 its place in the review queue, and per the `testflight-release` skill a cancel sets *every*
item on the submission to `REMOVED` — on 2026-07-27 that silently un-shipped all four IAPs and
the subscription group, and re-adding them is ASC-UI-only. This submission currently has 1 item,
so the IAP blast radius is nil today, but **re-count with
`GET /v1/reviewSubmissions/69da482e-.../items` before ever cancelling.**

---

## Tasks, in order

### 1. Push the branch (do first — none of this work exists off this machine)

Use the PAT in gitignored root `.env`, not `gh`'s OAuth token — the repo has
`.github/workflows/ingest.yml` and `gh`'s token lacks `workflow` scope:

```bash
source .env && git push "https://x-access-token:${GITHUB_TOKEN}@github.com/xmevans10/fantasy-app.git" m27-puzzle-blitz
```

Ask the user before merging to `main` — `main` is production.

### 2. Delete two stray empty review submissions

`e27a2d4a-c7c2-4e7d-9137-03b70dbd008c` and `e31794d3-6148-4361-a25c-ef8e89232cba` are both
`READY_FOR_REVIEW` with **0 items** — litter from a 409 retry loop, never submitted. They are
safe to remove (verify 0 items first) and may otherwise interfere with creating the next
submission. `DELETE /v1/reviewSubmissions/<id>`.

### 3. Backfill the un-rehosted NFL headshots — the highest-value fix here

**~35% of NFL rows still render an anonymous helmet in the shipping app.** Measured 2026-08-25
against production:

| | rows | share |
|---|---|---|
| Rehosted to our Storage bucket | 83,580 | 62% |
| Still hotlinked to NFL's CDN | **46,936** | **35%** |
| …on the `/image/private/` path | 45,278 | 34% |
| Blank (renders the initials monogram — correct) | 1,228 | 1% |

Sampling 20 distinct NFL-CDN URLs: 11 returned a **byte-identical 382,225-byte file** — a
faceless black NFL helmet. All 11 were `/image/private/`. Of the 14 `/private/` URLs sampled, 11
were that file (79%). Extrapolated: ~36,000 rows / ~5,000+ players.

Run `tools/ingest/headshots.py` over the un-rehosted NFL rows. Its placeholder detection already
clears byte-identical stock graphics to `''`, which hands them to `PlayerHeadshotBadge`'s
initials monogram — a designed fallback, where the helmet reads as broken. Verify after with:

```sql
select count(*) filter (where headshot like '%static.www.nfl.com%') as still_hotlinked
from public.player_seasons where sport = 'nfl';
```

Supabase project `nhccgufqwndtoasdbkhc` (NOT the `pyprjebfwqfdnfeliigo` decoy). Data pushes go
through `python -m tools.ingest.main --upsert`; creds are in gitignored `tools/ingest/.env`.

### 4. Rename "Immaculate Grid" in-app

It's a Sports Reference product name and it currently headlines the Grid result card and the live
App Store screenshot `02_gridresult`. Suggested replacement: "PERFECT GRID" or "NINE FOR NINE".
Grep for it, change it, add the string to `BallIQ/Localizable.xcstrings` (append surgically —
see below), run the suite.

### 5. Replace all six App Store screenshots

Full analysis with a proposed 6-shot lineup: `marketing/APP-STORE-SCREENSHOT-AUDIT.md`.
Headlines: three of six show an anonymous helmet; the K4C4 caption says "Ten real seasons" when
K4C4 is **eight** cards; four of six show result screens rather than gameplay (Who Am I? promises
"SIX CLUES" over an image with zero clues); the Grid board's nine answers are all alphabetical
autofill (every one starts with "A"); Puzzle Blitz, Journeyman, Versus and Leagues appear nowhere.

**Sequence matters:** do task 3 first or the new screenshots will contain helmets too. The one
shot safe to capture today is Journeyman (crests only, no headshot).

Capture with `-screenshotPro` on a 6.9" simulator. Upload via
`POST /v1/appScreenshots` + the reservation/commit flow against the screenshot set. These land on
1.7.1 — they are **not** blocking the queued 1.7.0.

### 6. Release the next build to ASC

Once 1–5 are done **and 1.7.0 has left the review queue**:

1. Bump `CURRENT_PROJECT_VERSION` to 41 and `MARKETING_VERSION` to `1.7.1` in
   `BallIQ.xcodeproj/project.pbxproj` (all four occurrences of each).
2. **Archive with the Release configuration and read the errors** — a Debug build and the test
   suite both pass on code that fails `xcodebuild archive`. That exact trap cost a cycle here:
   `DebugLaunch` keeps parallel `#if DEBUG` / `#else` declarations and M27 added two flags to only
   the DEBUG half, so Release failed with "type 'DebugLaunch' has no member". Any new debug flag
   needs both halves.
3. Export/upload per the `testflight-release` skill (`-authenticationKeyPath` must be absolute —
   wrap in `$(pwd)/…`).
4. Poll the build to `processingState: VALID` (~3–15 min).
5. Create the 1.7.1 `appStoreVersion`, set `whatsNew`, attach the build, then
   `POST /v1/reviewSubmissions` + `POST /v1/reviewSubmissionItems` +
   `PATCH …/reviewSubmissions/<id> {"submitted": true}`.
   Expect `409 STATE_ERROR` for several minutes after attaching the build — it is backend
   propagation lag, not a real error. Retry on a ~60s loop. **Confirm with the user before the
   final submit**; that step is outward-facing and hard to reverse.

---

## Repo conventions you will trip over otherwise

- **`Localizable.xcstrings` must be edited surgically.** Do not `json.dump` the whole file —
  Python's serializer reorders keys and reformats, producing a ~4,300-line diff. Append new
  entries as text before the trailing `\n  },\n  "version" : "1.1"\n}` anchor, matching Xcode's
  `"key" : value` spacing, then re-parse to prove it's still valid JSON.
- **Never edit the pbxproj by hand for file adds.** The project uses synchronized file groups;
  new `.swift` files under `BallIQ/` compile automatically.
- **Run both suites after each logical change** (`xcodebuild … test`, `pytest tools/ingest/tests`).
  Baseline is **844 Swift tests, 12 skipped, 0 failures**. The 12 skips are the known
  `PurchaseFlowTests` StoreKit-on-iOS-26.5 issue documented in AGENTS.md §7.1 — not a regression.
- **Verify against production, not the bundled fallback.** `BallIQ/Data/player_seasons.json` is a
  deliberately trimmed ~500-row sample and will give you wrong coverage numbers.
- **Screenshots before and after any visual change**, on the state most likely to break.
- If a documented command, path or fact here turns out to be wrong, invoke the `context-repair`
  skill and fix the doc — don't just work around it.

## Also open, lower priority

- **Social kit has no video.** `marketing/social-kit/README.md` flags it: Reels/TikTok/Shorts are
  video-first and the kit is static only. Highest-leverage next asset is a 10–15s screen recording
  of a Puzzle Blitz run (`xcrun simctl io <udid> recordVideo`) — the clock ticking down while
  boards change is the app's most watchable moment.
- **No weekly leaderboard for Puzzle Blitz.** `arcade_scores` is keyed `(game, sport)` with a
  `check (game in ('over_under','grid'))`, and a blitz run spans sports, so bests are per-duration
  and on-device. A sportless `blitz_scores` table would unlock it.
- **Over/Under's 8-second par** in `BlitzFormat.parSeconds` is an estimate, not a measurement —
  the dial to turn if the format mix looks lopsided in real runs.
