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
| Live submission `72babc8f-7976-4043-acfe-4145112f1cca` | `WAITING_FOR_REVIEW`, **exactly 1 item** (the version — no IAPs riding along). Superseded `69da482e-…`, which now reads `COMPLETE`. |
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

Do **not** cancel `72babc8f` to re-cut a build unless the user explicitly asks. Cancelling costs
1.7.0 its place in the review queue, and per the `testflight-release` skill a cancel sets *every*
item on the submission to `REMOVED` — on 2026-07-27 that silently un-shipped all four IAPs and
the subscription group, and re-adding them is ASC-UI-only. This submission currently has 1 item,
so the IAP blast radius is nil today, but **re-count with
`GET /v1/reviewSubmissions/72babc8f-.../items` before ever cancelling.**

---

## Tasks, in order

### 1. Push the branch (do first — none of this work exists off this machine)

Use the PAT in gitignored root `.env`, not `gh`'s OAuth token — the repo has
`.github/workflows/ingest.yml` and `gh`'s token lacks `workflow` scope:

```bash
source .env && git push "https://x-access-token:${GITHUB_TOKEN}@github.com/xmevans10/fantasy-app.git" m27-puzzle-blitz
```

Ask the user before merging to `main` — `main` is production.

### 2. ~~Delete two stray empty review submissions~~ — DONE, resolved themselves

`e27a2d4a-…` and `e31794d3-…` now 404. Apple superseded the whole submission record set: the
submission carrying 1.7.0 is now **`72babc8f-7976-4043-acfe-4145112f1cca`** (the old
`69da482e-…` reads `COMPLETE`). 1.7.0 itself is still `WAITING_FOR_REVIEW` with exactly one item,
so the one-open-submission constraint above is unchanged — only the id moved.

### 3. ~~Headshot cleanup~~ — DONE 2026-08-26, nothing to do

Left here as the record, not as work. The catalog fix landed in an earlier session
(`main.apply_headshot_ledger`); the residue it left in minted puzzles — 33 rows / 241 cards,
including tomorrow's NFL daily — was swept 2026-08-26. Both surfaces now read **0** rows on
`static.www.nfl.com`.

The sweep applied the ledger's per-card decision rather than blanking everything: rehosted photo
where the catalog had one (173 cards), `''` for the monogram where it didn't (68). Integrity
verified across all 32 keep4 boards — card counts, blind-sort order and every non-headshot field
unchanged. Pre-sweep content is in `public.puzzle_headshot_backup_20260826` if a restore is ever
needed; that table can be dropped once 1.7.x is out and nobody has complained.

**The mechanism is still unfixed**, and that is the real follow-up: `apply_headshot_ledger` runs
over the `RawSeason` list at the top of an ingest run, so it only reaches puzzles minted in that
run. Any puzzle minted before a future placeholder is detected will freeze the bad URL again —
this class of bug recurs on the next batch of retired players the CDN gives up on.

**Recommended fix: re-check at serve time, not another sweep** (reasoning from `fantasy-app-d1`,
and better than the framing this handoff originally carried). The failure is that *a URL which was
good at mint time stops being good later*. Applying the ledger to `puzzles.content` is the
narrower change but keeps the same freeze-at-mint shape — it only moves when the freeze happens,
so the next CDN retirement re-creates the problem. Only a check after mint catches it. The cost is
a per-serve lookup, which `TeamIdentityIndex` already demonstrates is affordable at this scale.

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

**Sequence matters:** the catalog is clean now, so most boards are safe — but 33 puzzles still
carry frozen helmet URLs (task 3). Before capturing any board with a headshot on it, spot-check
that specific puzzle id against the query in task 3. Journeyman is safe unconditionally (crests
only, no headshot).

Capture with `-screenshotPro` on a 6.9" simulator — **claim a lock first, see below**. Upload via
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

## 🔴 Simulator locks — claim before ANY simctl or simulator-MCP call

Up to six Claude sessions share this Mac's eight simulators. On 2026-08-25 three of us drove
`448665F0` at once: an FTUE cold-install run got steered into a game board it never tapped, and a
test suite died mid-run with "Unable to initialize test bundle" plus two unattributable failures
that were about to be bisected as a real regression. All ambient, all wasted time.

Protocol is in `/tmp/balliq-sim-locks/README.md`. Claim atomically:

```bash
D=<UDID>; ME=<your-session-name>
ln -s "$ME" /tmp/balliq-sim-locks/$D 2>/dev/null && echo GOT || echo "HELD BY $(readlink /tmp/balliq-sim-locks/$D)"
```

Release with `rm -f /tmp/balliq-sim-locks/$D`. Use `ln -s`, never `test -f` + write — only the
symlink is atomic.

**This handoff deliberately does not name a device.** An earlier draft called `448665F0` "the test
device" and that alone routed a second session's `xcodebuild` onto an already-busy simulator.
Take whichever of the eight is free; there are more devices than sessions, so prefer a free one
over queueing. A lock naming a session that `ListAgents` doesn't return *may* be stale, but check
its age first — a few-minutes-old lock is far more likely a live session using a descriptive alias
than an abandoned one. Message the holder before removing anything.

Also: `simctl uninstall` does **not** clear UserDefaults on this project (cfprefsd caches the
plist by bundle id). A genuine clean-install needs
`simctl spawn <sim> defaults delete com.balliqfantasy.app` as well.

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

## ⚠️ Known collision with M30 (FTUE activation)

`fantasy-app-d1` has scoped `prompts/HANDOFF-m30-ftue-activation.md` off its FTUE audit. Three of
its six files overlap this branch:

| File | Overlap |
|---|---|
| `Keep4GameView.swift` | Textual only, resolved. M30's gate moved inside `complete()`, so no `ranked:` argument changes and this branch's early `return` in `finish()` is untouched. M30's other edit hides `modePicker` (referenced at ~line 241, inside `header`); this branch's `close()` change is at ~line 188 — same function, 53 lines apart, auto-merges under git's default context. Don't let anyone reformat `header` wholesale. |
| `HomeView.swift` | Different regions (a `@State`, a `launch(_:)` case, a `fullScreenCover`, a `DebugLaunch` branch). Should auto-merge. |
| `Localizable.xcstrings` | Both append. Trivial *if* both append at the trailing anchor as text; catastrophic if either rewrites the file (see the convention above). |

`OnboardingView.swift`, `RepositoryContainer.swift` and `AnalyticsClient.swift` are clear.

**Resolved with M30's author:** blitz rounds must not consume the first-three-games grace
window, and the clean expression is a rule over `GameResult.ranked` rather than a per-format
exclusion — that answers Blitz, community, archive and Versus at once and stays correct for the
next unranked surface. The gate lives inside `RepositoryContainer.complete()`, so **no call site's
`ranked:` argument changes** and this branch's early `return` in `Keep4GameView.finish()` is
untouched. The overlap is textual only.

⚠️ **If you implement that window, do not count `ranked` rows.** The obvious form —
`gameLog.all().filter(\.ranked).count` — never terminates: it filters on the field the rule
sets, so game 1 is forced unranked, writes `ranked: false`, the count stays 0, and *every*
subsequent game is unranked forever. Verified by grep that nothing else writes a `ranked: true`
row from outside the gate: the only producers are the daily paths (`HomeView` daily cards,
`BrowseView` canonical-today, and the game views' `ranked` prop defaulting true). Everything else
— Blitz, Browse archive, Versus, ladder, Draft & Spin, community — is hard-coded `false`.

**Counting `mode == .daily` instead does NOT work** — that was this handoff's first suggestion and
it leaks. `mode` is a *surface* label, not a rating-eligibility label: `DraftSpinView:642` writes
`mode: isDailyDraft ? .dailyDraft : .daily` next to a hard-coded `ranked: false` at :650, so every
free-play spin lands as `.daily` + unranked; and `OverUnderGameView:396` hard-codes `mode: .daily`
on *every* run while `ranked` varies at :394, so unranked replays count too. Draft & Spin is the
second-highest-volume format in production, so three arcade spins would silently consume the whole
window.

**The working shape (credit `fantasy-app-d1`)** separates two things the data model already
distinguishes — *was this a rated surface* (`ranked`, persisted) versus *does rating move this
time* (local, not persisted):

```swift
let ratedSoFar  = await gameLog.all().filter(\.ranked).count
let inPlacement = ratedSoFar < 3
let applyRating = ranked && !inPlacement
```

`applyRating` gates exactly three sites in `complete()` — and there are exactly three:

```
:514  if ranked {  → localRating.apply        (all-time rating)
:525  if ranked, let season = currentSeason { (season ladder)
:538  if ranked {  → sync.pushRating          (server mirror + history)
```

🔴 **`:554`'s `recordGameResult(… ranked: ranked …)` must keep receiving the ORIGINAL `ranked`,
never `applyRating`.** That is the entire mechanism: the placement daily is still recorded as the
rated surface it was, so the counter increments and the window closes. Swapping that one argument
looks like a tidy-up and silently restores the permanent-deadlock.

Consumers of `GameResult.ranked` verified — only `RemoteSync.swift:127` (mirrors to server) and
`CareerStats.swift:114` (`consistencyScore`). Neither means "rating moved"; `ratingDelta`
(`GameResult.swift:57`) is that signal. `consistencyScore` reads `performance`, not rating, so
including placement games is benign.

**`logSession` (:573) is a second entry point into the career log — leave it alone.** It
hard-codes `ranked: false` at :577 and has six call sites, all the duel/ladder/practice paths, not
just Grid practice:

```
WhoAmIGameView:421   Keep4GameView:401   JourneymanGameView:345, :748   GridGameView:438, :454
```

Every one is correct as-is: a duel never moves rating (the Versus info sheet's standing promise),
so those rows must not increment the placement counter. It is, however, the obvious place for
someone to "helpfully" add a matching gate. Don't. The consequence of getting it wrong is benign in
one direction and a deadlock in the other, which is exactly the asymmetry that makes it worth a
comment rather than trust.

Also read the count **before** `recordGameResult` writes the current row — rating applies at :515,
the row is appended around :599–607, so the natural gate position excludes the current game. That
is correct but invisible, and breaks silently if the gate moves.

**Test it at game four.** Games 1–3 behave identically under the working and deadlocked designs, so
every obvious assertion passes either way. Only "play four rated games, assert the fourth moves the
rating" separates them.

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
