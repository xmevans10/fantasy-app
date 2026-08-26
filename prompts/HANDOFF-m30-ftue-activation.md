# Handoff — M30: FTUE activation fixes

Scoped 2026-08-26 from a cold-install audit on a locked simulator, cross-checked against every
row in the production `events` table. The research write-up, with screenshots, the funnel
numbers and the principle scorecard, is the artifact **"Playbook's First Ninety Seconds"**.

Read `CLAUDE.md` and `AGENTS.md` first. `docs/BALLIQ_SPEC.md` §1 is the product context. The
`dev-taste` skill resolves anything left open — but **Part A is written so it shouldn't have
to.** Build Part A exactly as written.

| | status |
|---|---|
| **Part A — A1…A7** | Implementation-grade. Exact files, exact call sites, exact verification. Build it. |
| **Part B — B1** | Scoped, **not** implementation-grade. Needs content curation before code. Separate build. |

**Out of scope: anything StoreKit.** The audit found the live paywall showing no prices
(260 `product_load_failed`, all "store returned no products for 4 ids", production receipts,
through 2026-08-24). That is almost certainly the Paid Apps Agreement, not app code — see
the `paid-apps-agreement-gates-iap` memory. It is being handled separately. **Do not touch
`StoreService`, `Entitlements`, `PaywallView`'s purchase path, or the `claim-entitlement`
edge function.** A4 touches `PaywallView` *call sites* only, to pass a trigger argument.

---

## 0. Setup

```bash
cd /Users/xanderevans/Documents/fantasy-app && git status
```

Branch `m27-puzzle-blitz`, `main` is production — do not merge without asking.

⚠️ **The tree is not clean and none of it is M30.** As of 2026-08-26 a parallel StoreKit
entitlement-claim workstream and an M28 Who Am I? workstream both have uncommitted changes.
Consequences:

- `BallIQ/Localizable.xcstrings` is being edited by **two** other sessions. A3 and A5 add keys
  to it. Re-read it immediately before editing, keep your keys in their own commit, and make
  the edit as a **surgical text insertion** — Xcode writes `"key" : value` (space before the
  colon) and orders keys by ICU collation; a Python `json.dump` round-trip reformats all ~6,700
  lines. That has already happened once this week and had to be reverted by hand.
### 0.3 🔴 Branch point — the remote is stale, and three files collide

**Do not branch from `origin/m27-puzzle-blitz`.** As of 2026-08-26 that ref points at `95a5f13`,
six commits behind the local branch HEAD (`6885f34`). The Puzzle Blitz work is committed but
**unpushed**. Branching from origin — or from `main` — gets you a pre-Blitz `HomeView` and
`Keep4GameView`, and you would write against code that does not have the seams described below.

Verify before you start:

```bash
git log --oneline -1                       # expect 6885f34 or later
git log --oneline -1 origin/m27-puzzle-blitz   # if this is 95a5f13, the push hasn't happened
```

If the remote is still behind, **ask the user before pushing** — do not push a peer's commits on
your own initiative.

Three files overlap with the Blitz branch:

| file | overlap | risk |
|---|---|---|
| `Localizable.xcstrings` | ~386 lines | append-only, low **if** nobody rewrites it |
| `Keep4GameView.swift` | ~42 lines | textual, in `finish()` — see below |
| `HomeView.swift` | ~10 lines | should auto-merge; different regions |
| `OnboardingView.swift` | — | clear |
| `RepositoryContainer.swift` | — | clear |
| `AnalyticsClient.swift` | — | clear |

**`Keep4GameView.finish()`** now opens with an early return for Blitz:

```swift
if let blitz {
    result = r
    blitz.finishRound(format: .keep4, ..., cleared: ...)
    return          // returns BEFORE the complete()/ranked: path entirely
}
```

This is the reason A1.1 forbids implementing the window by editing `ranked:` at call sites: a
Blitz round never reaches that argument, so a call-site implementation would silently leave
Blitz outside the rule. Gating inside `complete()` and counting on `ranked` sidesteps the
early return completely — A1 should not need to touch `finish()` at all. Your only edit in this
file is A3's `modePicker` visibility, which is in a different region.

**`Localizable.xcstrings` merge discipline.** Append as **text**, immediately before the
trailing anchor:

```
  },
  "version" : "1.1"
}
```

Match Xcode's `"key" : value` spacing (space before the colon), then re-parse to prove the file
is still valid JSON. **Never `json.dump` the parsed file** — Python reorders keys by a different
collation and reformats, turning a six-line addition into a ~4,300-line diff that conflicts with
everything. Two sessions appending at the same anchor produce adjacent-line adds that git
merges cleanly; one rewrite produces a merge magnet. This has already gone wrong once this week.

- Confirm the overlap set yourself with `git diff --stat` before you start; it will have moved.

### 0.1 🔴 Claim a simulator before you touch it — this Mac is shared

Multiple Claude Code sessions share these simulators (8 devices, ~6 live sessions). Driving a
device another session is using corrupts both runs in a way that **does not look like
contention**: your taps land in their app state, and their `xcodebuild test` reinstall reads as
a mid-game crash in your run. This cost the audit a full pass before it was diagnosed.

Protocol: **`/tmp/balliq-sim-locks/README.md`** — read it. Claim before **any** `simctl` or
simulator-MCP call:

```bash
D=<UDID>; ME=<your exact ListAgents name>
if ln -s "$ME" /tmp/balliq-sim-locks/$D 2>/dev/null; then echo GOT; else echo "HELD BY $(readlink /tmp/balliq-sim-locks/$D)"; fi
```

`ln -s` is atomic and fails if the lock exists — do **not** substitute `test -f` then write.
Release with `rm -f /tmp/balliq-sim-locks/$D` the moment you're done. Label the lock with your
exact `ListAgents` name (a descriptive alias makes your live lock look stale to everyone else
and cannot be addressed with `SendMessage`). If a device is held, take a free one from the
README's list of 8 rather than queueing.

### 0.2 Cold-install recipe — `simctl uninstall` is not enough

`uninstall` alone leaves UserDefaults cached by `cfprefsd`, so the app relaunches with
`hasOnboarded = 1` and lands on Home instead of onboarding. Every FTUE verification below
requires the full four-step reset:

```bash
xcrun simctl terminate $D com.balliqfantasy.app 2>/dev/null
xcrun simctl uninstall  $D com.balliqfantasy.app
xcrun simctl spawn      $D defaults delete com.balliqfantasy.app
xcrun simctl install    $D <derivedData>/Build/Products/Debug-iphonesimulator/BallIQ.app
```

Then launch with **no `-screenshot*` flags** and drive real taps via the simulator MCP
(402×874 points on iPhone 17). The DebugLaunch hooks capture *states*; they skip the
transitions this milestone is about. Splash holds ~1.0s, so the sport step lands ~1.8–2.5s.

---

## Why this milestone exists — the measured funnel

All from the production `events` table, 2026-07-27 → 2026-08-26:

```
app_opened (first_open=true)        125
onboarding_step_viewed · sport      230
onboarding_step_viewed · how_to_play 93   ← −60%
first_game_started                   64
first_game_completed                 11   ← −83%
paywall_viewed                      258   ← 23× the first-win count
```

⚠️ These are **event counts, not users**. `events` has `id`, `user_id`, `event_name`,
`properties`, `created_at` and **no anonymous install id**, so signed-out sessions cannot be
joined. A7 fixes that. Until it ships, do not quote these as conversion rates.

---

# Part A — implementation-grade

## A1. First three games are unrated placement games 🔴 highest value

**The defect.** `RatingEngine.startingRating` is `1000` (`Progression.swift:85`).
`Tier.silver` is `1000...1199`, `Tier.bronze` is `0...999` (`Tier.swift:11–12`). A new player is
seated on the **exact first point of Silver**, so any rating loss at all is a visible tier
demotion. `expectedPerformance` is `0.5 + (rating − 1000)/2000`, i.e. break-even is a 50%
expected score on a blind 8-card sort. The median first-timer loses.

Measured on a real cold install: 2/8 → −10 → 990 → **BRONZE**, on the first game ever played.

**The change.** Do not apply rating deltas until the player has completed 3 games. Keep XP,
streak, and the career-log row exactly as they are — only the rating is withheld.

### A1.1 `BallIQ/RepositoryContainer.swift`

`complete(...)` at line 485 already has the seam you need. Its `ranked: false` branch does
precisely the right thing:

```swift
let current = await localRating.rating(for: sport)
change = RatingChange(old: current, new: current)   // unranked: no rating movement
```

Add a placement gate that folds into the existing `ranked` decision. The volume authority is
`gameLog` (`RepositoryContainer.swift:40`, `LocalGameLogRepository`) — **not** `progressSnapshot`,
because XP is also written by `RemoteSync.pull()`, so a returning player signing in on a new
device would otherwise look like they had played hundreds of games. `MomentPresenter.context`
already reads volume this way (`await container.gameLog.all()`); follow it.

### 🔴 The counting rule — read this whole section before writing the gate

Two wrong answers have already been proposed for this. Both fail, in opposite directions, and
the reason is one invariant:

> **The counter must be orthogonal to the field the rule writes.**

**Wrong answer 1 — count every row.** `MomentPresenter` uses a bare `rows.count`. Copy that and
unranked rows close the window: a player who opens Puzzle Blitz first burns three protected
games on boards that were never going to move their rating, then meets their first real daily
unprotected.

**Wrong answer 2 — count rows where `ranked == true`, and have the gate force `ranked: false`.**
This never terminates. The counter is filtering on the very field the rule sets, so it can only
be incremented by a row the rule refuses to create:

```
game 1  ranked rows = 0 → 0 < 3 → force ranked:false → row written ranked:false
game 2  ranked rows = 0 → 0 < 3 → force ranked:false
…forever — rating never moves again, for anyone
```

The only producers of `ranked: true` are the daily paths (`HomeView.swift:517,540,562` and
`BrowseView.swift:201,214,227`). Nothing else can rescue the count. **This would ship a
permanently unrated app.**

**Wrong answer 3 — count `mode == .daily` instead.** Tempting, because `PlayMode` is set
independently of `ranked`. It leaks badly, in the arcade formats:

```
DraftSpinView.swift:642   mode: isDailyDraft ? .dailyDraft : .daily
DraftSpinView.swift:650   ranked: false          ← always, by design
OverUnderGameView.swift:394  let ranked = !container.hasCompletedToday(dailyID)
OverUnderGameView.swift:396  mode: .daily         ← hard-coded, every run
```

So every arcade Draft & Spin run and every Over/Under replay-of-the-day writes
`mode: .daily` with `ranked: false`. Draft & Spin is the second-highest-volume format in
production (357 `game_started` rows). Three arcade spins would consume the entire window —
reintroducing wrong answer 1's failure by a different route.

### ✅ The rule to implement

Separate the two concepts that the wrong answers conflate:

| concept | where it lives | meaning |
|---|---|---|
| `ranked` (the argument, and `GameResult.ranked`) | written unchanged | **was this a rated surface?** |
| a new local, e.g. `applyRating` | never persisted | **does rating move *this time*?** |

```swift
// Read BEFORE this session's row is written — see the ordering note below.
let ratedSoFar = await gameLog.all().filter(\.ranked).count
let inPlacement = ratedSoFar < 3
let applyRating = ranked && !inPlacement
```

There are **exactly three** `if ranked` gates to switch to `applyRating`, and **one** call that
must keep the original `ranked`:

```
:514  if ranked {                          → localRating.apply       switch to applyRating
:525  if ranked, let season = currentSeason  → season ladder         switch to applyRating
:538  if ranked {                          → sync.pushRating         switch to applyRating

:554–555  recordGameResult(… ranked: ranked …)   ← MUST stay `ranked`. Do not touch.
```

🔴 **That last line is the whole mechanism.** Changing `ranked: ranked` to
`ranked: applyRating` at `:555` re-creates the deadlock exactly, and it would look like a
consistency tidy-up to anyone reading the diff. Leave a comment there saying why it differs
from the three gates above it.

**`ranked` is passed through to `GameResult` untouched**, so a daily played during placement is
still recorded as the rated surface it was, the counter increments, and the window closes after
three. Orthogonal by construction: the field the counter reads is not the field the rule writes.

`logSession` (`:573`, Grid practice) is a **second entry point** into the career log and already
hard-codes `ranked: false` at `:577`. It correctly neither consumes a slot nor gets rated —
**leave it alone**; it needs no gate.

This also answers Blitz, community and archive replays in general rather than by a format list —
they pass `ranked: false`, so they neither consume a slot nor get rated, now or for any
unranked surface added later.

⚠️ **Ordering is load-bearing and invisible.** In `complete()` the rating is applied at
`:515` and the row is built at `:599` / appended at `:607`, so a gate at the natural spot reads
a count that excludes the current game — which is what you want. Put a comment on it. If anyone
later moves the gate below the append, every threshold silently shifts by one.

⚠️ **One consequence to verify, not hide.** `CareerStats.swift:114` does `rows.filter(\.ranked)`
for recent form, so placement games will now appear there with a `ratingDelta` of 0. Check
whether that dilutes the recent-form figure and, if it does, filter that call site on
`ratingDelta != 0` or an explicit flag rather than changing what `ranked` means. The other
consumer, `RemoteSync.swift:127`, just mirrors the field to the server and is unaffected.

Requirements:

- A new install completing rated games 1, 2, 3 gets `RatingChange(old: n, new: n)` for each.
- Rated game 4 onward rates normally.
- **No call site's `ranked:` argument changes.** The gate lives entirely inside `complete()`.
  Do not implement this by editing `ranked:` at the six game views — that would both miss the
  paths that early-return before reaching it and collide with in-flight work (see 0.3).
- The **season** ladder (`localSeasonRating.apply`) must be gated by the same condition — it is
  the same Elo engine on a parallel row, and leaving it live would demote the player on a
  surface the placement gate claims to protect.
- `sync.pushRating` must not fire for a placement game.
- The count must be read **once** per `complete()` call and reused, not re-read after the
  append — `gameLog.append(result)` happens at line 607, after the rating decision, so read
  early and be explicit about it in a comment.
- An explicitly `ranked: false` call site (community puzzles, deep-linked replays) stays
  unranked regardless. Placement only ever *removes* rating movement, never adds it.

Expose the state so views can render it — a computed property on the container reading the
same source, e.g. `placementGamesRemaining: Int` (0 once complete). **Naming warning:**
`Keep4GameView` already has a local `placement` (the board's keep/cut card placement, see
`Keep4GameView.swift:240` `if placement.isEmpty`). Do not reuse that word inside that file;
`ratingPlacement` or `placementGames` avoids the collision.

### A1.2 Result screens — say what is happening

Every result view that renders a rating delta must render the placement state instead when one
is active. Do not silently show `0`; an unexplained zero is worse than the loss it replaces.

Copy: **"Placement 1 of 3"** with a sub-line to the effect of *"Your rating starts after three
games."* This is a familiar convention and it converts a loss into anticipation — that is the
whole point of the change, so do not soften it into a hidden no-op.

Result views to update (`RewardsRow` is shared — check whether one edit covers them all before
touching six files):

```
BallIQ/Features/Keep4/Keep4ResultView.swift
BallIQ/Features/WhoAmI/WhoAmIResultView.swift
BallIQ/Features/Journeyman/…ResultView
BallIQ/Features/OverUnder/OverUnderResultView.swift
BallIQ/Features/DraftSpin/…ResultView
BallIQ/Features/Grid/…ResultView
```

### A1.3 Home's rank widget — the Bronze/Silver contradiction

`HomeView.swift:142–143` renders `RankWidget(sport: rankSport, rating: container.rating(for: rankSport))`
— a **per-sport** rating. `ProfileView` renders the **global** rating. On a fresh install these
disagree: Home said `BRONZE 990` while Profile said `SILVER 1,000` in the same session, ninety
seconds in. Both are individually correct; together they tell the player two different tiers.

Fix the first-session case: while placement is active, `RankWidget` shows the placement state
("2 more to place") rather than a tier and a number. Do the same in `ProfileView`. Once
placement completes both show real values and the underlying per-sport/global distinction
stands — that part is intended and should be *labelled*, not removed.

Also verify the progress bar: at 990 in Bronze (`0...999`) it renders ~99% full, which reads as
"about to be promoted" when it means "ten points below where you started."

### A1.4 Tests — `BallIQTests/`

Extend the rating tests with locked values:

- 3 rated completions → `ratingChange.old == ratingChange.new` each time, and the rating after
  game 3 equals `RatingEngine.startingRating`.
- Rated game 4 moves the rating.
- **Unranked rows never consume a slot.** Ten `ranked: false` completions followed by three
  rated ones must still leave the third rated game unrated and the fourth rated. This is the
  test that locks the Blitz/community/replay behaviour — name it so.
- 🔴 **The window terminates.** A test that plays *four* rated games and asserts the fourth
  moved the rating. Without it, the non-terminating variant in "wrong answer 2" passes every
  other test in this list — each of games 1–3 is correctly unrated — while shipping an app
  whose rating never moves again. Assert on game 4 explicitly.
- **`GameResult.ranked` is preserved.** After three rated placement games, `gameLog.all()`
  contains three rows with `ranked == true` and `ratingDelta == 0`. If a row comes back
  `ranked: false`, the gate is writing the field it counts and the window will never close.
- Season rating is untouched for rated games 1–3.

⚠️ These tests are **hosted** (they run inside the real app process). Any test that writes
UserDefaults or the game log must inject its own store — writing through `.standard` lands in
the real app container and corrupts the next manual launch's funnel. `ActivationState` and
`MomentState` both take an injectable `UserDefaults` for exactly this reason; follow that
pattern.

---

## A2. The sport step must say what the app is 🔴 largest single leak

**The defect.** 230 sport-picker views produced 93 rules-screen views. Three in five installs
end at a question they have no context for. `OnboardingView.sportStepContent` shows a wordmark,
"WHICH SPORT DO YOU KNOW BEST?", five rows, and one line of body copy that explains the choice
is *reversible* — addressing a hesitation the player has not reached yet.

**The change.** `BallIQ/Features/Onboarding/OnboardingView.swift`, `sportStepContent`.

1. One line above the sport list saying what a round actually is. Concrete and mechanical, not
   a tagline — the splash already carries "prove you know ball". Something in the register of
   *"Eight real seasons. Keep the four that scored most."*
2. A single **non-interactive** sample card beneath the heading. `Keep4CardView` already renders
   exactly this; the how-to-play step has ~600px of unused height proving there is room. Use a
   hardcoded, recognisable season — this is illustrative, not a live fetch, and must not block
   or fail.
3. Keep the reversibility line, but demote it below the list.

⚠️ **Layout constraint, do not lose this.** `sportStep` uses a bare `ScrollView` via
`fitsOrScrolls`. It must **not** be replaced with `ViewThatFits` or
`GeometryReader { ScrollView { … } }` — both render a measurement pass that on iPad draws a
**ghost duplicate** of each step's secondary button, clipped, at the top of the screen. That
shipped once and was bisected on 2026-07-28; the note is in the file. Verify on
`BallIQ-Shots-iPad13` before you call this done.

Verify the step still fits an SE-class screen (`Sprout-SE`) with the card added.

---

## A3. Keep Pro out of session one

**The defect, measured.** A brand-new player meets the paid tier three times before their
first session ends:

1. `NORMAL / HARD · PRO` segmented control above **card 1 of 8** — `Keep4GameView.swift:241`
   (`modePicker`, defined at :297, gated at :307 `gatedMode`).
2. `Browse all puzzles · PRO` on Home — `HomeView.swift:351` (`browseRow`).
3. `The Grid · Pro` in the formats grid on Home.

None are wrong to exist. All three are wrong to show in session one, when the player has no
basis for judging whether the paid tier fits them.

**The change.**

- `Keep4GameView`: hide `modePicker` entirely until the player has completed at least one game.
  The existing `if placement.isEmpty { modePicker }` becomes a compound condition — remember the
  naming collision from A1.1. Do **not** disable it in place; a visibly disabled Pro control is
  a worse version of the same problem.
- `HomeView`: hold `browseRow` and the Grid tile until 3 completed games (same `gameLog` count
  as A1). The formats grid should not show a gap — reflow it.
- Read the count from one shared helper, not three re-derivations. AGENTS.md §4.

**Do not** change what Pro costs, what it includes, or `Entitlements`. This is placement only.

---

## A4. Give every paywall call site a real trigger

**The defect.** 200 of 258 `paywall_viewed` events (78%) carry `trigger: other` — the default in
`PaywallView.init` (`PaywallView.swift:22,30`). The dominant path to the paywall is the one path
that cannot be seen.

**The change.** Two call sites construct `PaywallView()` with no trigger:

```
BallIQ/ContentView.swift:101          → debug paywall sheet (-screenshotPaywall)
BallIQ/Features/Store/PaywallView.swift:564 → #Preview
```

Neither of those explains 200 production events, so **find the real source before writing
code.** Start by querying which properties accompany those rows:

```sql
select properties, count(*) from events
where event_name='paywall_viewed' and properties->>'trigger'='other'
group by 1 order by 2 desc limit 20;
```

Then audit every presentation path — `HomeView.swift:212` passes a `paywallTrigger` **variable**,
so check every assignment to it; an unset default there would produce exactly this signature.

Once located: give it a named `PaywallTrigger` case, adding one to the enum if no existing case
fits (`PaywallTrigger` is at the bottom of `AnalyticsClient.swift`). Raw values are **schema** —
the queries in `docs/ANALYTICS.md` group by them. Add cases, never rename them.

**Exit criterion:** after a cold install + a driven pass through every gate, no
`paywall_viewed` row carries `trigger: other` except the debug sheet.

---

## A5. Ask for notifications at the first win, not the first streak

**The defect.** `PushPrimer.shouldOffer` (`ActivationFunnel.swift`) requires `streak > 0`, which
requires a completed game. Only 11 installs have ever completed one. Of 125 first opens, **120**
ended with push still `not_determined`. The retention machinery is sound; it sits downstream of
a threshold almost nobody crosses.

**The change.** Gate on `ActivationState.has(.firstGameCompleted)` instead of `streak > 0`.

⚠️ **Two callers must not disagree.** `HomeView` renders the card and `MomentPresenter`
suppresses every moment while it is pending (`MomentContext.pushPrimerPending`). The condition
lives in `PushPrimer.shouldOffer` precisely so it cannot drift — change it **there only**, and
leave both call sites reading through it. A second copy would let Home show the card *and* a
moment sheet open over it, which is the one outcome both rules exist to prevent (AGENTS.md §4).

Leave `shouldOfferPushPrimer` / `pushPrimerAnswered` alone — the OS prompt can only be shown
once per install, and a second ask would be a dead button.

Update the card copy if it references a streak the player may not have yet.

---

## A6. Community: hide the tab until it has content

**The defect.** `community_puzzles` holds **zero rows** in production. One `puzzle_published`
event has ever been recorded. A fifth of the tab bar greets a brand-new player with
*"NO COMMUNITY PUZZLES YET — Be the first, tap + to cook one up."* Authoring a puzzle is the
highest-commitment action in the app and it is the only thing this tab offers someone who has
played one game.

**The change** — pick one and say which in the commit message:

- **(a) Hide the tab** when the feed is empty, in `ContentView`'s `TabView` (tag 3). Cheapest,
  reversible, and correct today. Watch the `selectedTab` tags: `DebugLaunch.autoOpenCommunity`
  sets `selectedTab = 3` and Profile is `4` — a conditionally-absent tab must not shift Profile's
  index or every debug flag and the Stats auto-push break.
- **(b) Seed the table** with a dozen good boards and leave the tab up.

(a) is the recommendation. Do **not** ship the empty state as-is.

**Then surface the Ladder instead.** The Versus bot ladder — 30 opponents, playable signed-out,
same board as you — is the strongest second-session hook in the app and is currently three taps
deep behind an auto-presenting "How it works" sheet. Do not rebuild it; just make sure that
sheet is not the first thing a new player meets on that tab.

---

## A7. Add an install id to every event 🔴 makes everything above measurable

**The defect.** `events` has no anonymous install identifier, so the signed-out majority is
unjoinable and no per-user funnel exists. Separately, `game_started` and `game_completed` write
**different `format` vocabularies**:

```
game_started:   keep4      draftspin   whoami   overunder   grid  journeyman  blitz
game_completed: keep4Normal draftSpin  whoAmI   overUnder   grid  journeyman  blitz
```

Any per-format completion rate joined on that key silently reads **0%** for the first four.

**The change.**

1. One stable hashed UUID per install, generated once, stored in UserDefaults, sent on **every**
   event alongside `user_id`. `AnalyticsClient.log` (`AnalyticsClient.swift`) and
   `RepositoryContainer.track` (`:624`) are the two seams. Add the column to the `events` table
   and to `supabase/schema.sql` in the same change — `schema.sql` is the source of truth and must
   never drift from production (CLAUDE.md).
   - It must survive sign-in/sign-out, and must **not** be derived from the IDFA or any device
     identifier — a random UUID in UserDefaults is the whole requirement.
   - Guest→account migration: an install id already in the table keeps its rows; do not rewrite
     history.
2. Reconcile the `format` vocabularies. `game_started`'s values are the ones that match
   `GameFormatKind`'s existing raw values in most places — **check before choosing**, pick one
   side, and note in `docs/ANALYTICS.md` that rows before the cutover use the old spelling. Do
   not rewrite historical rows.

---

## A8. Verification — all of Part A

Claim a device (0.1), do the full cold-install reset (0.2), then drive the **real** flow with
taps, no debug flags:

1. Launch → sport step. **Screenshot.** Confirm A2's thesis line and sample card, and that the
   step fits without scrolling on iPhone 17.
2. Repeat on `BallIQ-Shots-iPad13` — confirm **no ghost duplicate** of "Skip for now" at the top
   of the screen (A2's warning).
3. Repeat on `Sprout-SE` — confirm the sport step still fits or scrolls cleanly.
4. Tap a sport → rules → PLAY. **Screenshot card 1.** Confirm the `HARD · PRO` control is
   **absent**.
5. Play all 8 cards. **Screenshot the result.** Confirm "Placement 1 of 3", no red rating delta,
   XP and streak still shown.
6. Confirm Home shows **no** `Browse all puzzles · PRO` row and **no** Grid tile, and that the
   rank widget shows placement state — not `BRONZE 990`.
7. Confirm the notification primer appears (A5) after this first completed game.
8. Confirm the Community tab is absent (A6a) **and** that Profile is still reachable and that
   `-screenshotProfile` / `-screenshotStats` still land on the right tab.
9. Play games 2 and 3. Confirm placement copy counts down and rating stays flat.
10. Play game 4. Confirm the rating moves and the rank widget shows a real tier.
11. Query the live `events` table for this run's install id and confirm the row sequence:
    `app_opened → onboarding_step_viewed ×3 → first_game_started → first_game_completed`,
    every row carrying the new install id, and no `paywall_viewed` with `trigger: other`.

Then: `xcodebuild -scheme BallIQ … test` green, and **release your simulator lock**.

---

# Part B — scoped, not implementation-grade

## B1. A curated easy first board per sport

**The defect.** The first-ever board served to a new NFL player on 2026-08-26 was
*"2020s Day-3 RB steals (round 5+)"* — identifying the top four fantasy seasons among eight
late-round running backs. That is a question for someone who already plays fantasy seriously.
There is no easy-first-board concept anywhere in the minting pipeline: `OnboardingView
.loadFirstPuzzle()` takes whatever `keep4Puzzle(for:date:)` returns for today.

Combined with A1 this is the mechanism the whole audit turns on — an expert board scored
against a 50% break-even, shown to someone forty seconds into the app. A1 removes the scoring
half. B1 removes the difficulty half.

**Why this is not implementation-grade.** "Easy" has to be *derived*, not asserted. It needs:

- A definition. Candidate: eight well-known names with **wide grade separation**, so the top 4
  are separable by reputation alone. The `catalog-replay-harness` (see memory) tests theme
  viability against `player_seasons` in ~1 minute instead of a 25-minute provider pull — use it
  rather than guessing.
- A curation pass per sport, reviewed by a human. Do not ship an auto-generated "easy" set.
- A serving path: served **only** to the guided first game. The daily pool stays exactly as it
  is — this is not a difficulty change to the dailies.
- A decision on the second game. Home currently offers Who Am I? tagged **HARD** in red as a new
  player's second card. Whether that tag is honest or discouraging is a `dev-taste` call.

Do not start B1 in the same build as Part A.

---

## Definition of done

- [ ] A1–A7 built, all A8 steps verified with screenshots on a **locked** simulator
- [ ] `xcodebuild … test` green; new locked-value tests for placement
- [ ] `supabase/schema.sql` updated in the same change as A7's column
- [ ] `docs/ANALYTICS.md` notes the install id and the `format` cutover
- [ ] `Localizable.xcstrings` keys added surgically, in their own commit
- [ ] Simulator lock released
- [ ] Nothing under `Store/` or `StoreService`/`Entitlements` modified
