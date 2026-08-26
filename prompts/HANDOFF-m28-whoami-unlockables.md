# Handoff — M28 Who Am I? visual pass, M29 unlockables

Scoped 2026-08-26. **Revised the same day** after every claim in the first draft was measured
against the live app and the live database — three of its prescriptions were wrong and are
corrected here. The research write-up behind the corrections, with screenshots and charts, is
the artifact "Empty Board, Empty Case".

Read `CLAUDE.md` and `AGENTS.md` first. `docs/BALLIQ_SPEC.md` §1 is the product-theme context.
The `dev-taste` skill resolves anything this doc leaves open — but **Part A is written so that
it shouldn't have to.** Build Part A exactly as written.

| | status |
|---|---|
| **Part A — M28** | Implementation-grade. Exact files, exact code, exact verification. Build it. |
| **Part B — M29** | Scoped, corrected, **not** implementation-grade. Its badge list must be re-derived before anyone writes a row. Do not start it in the same build as Part A. |

---

## 0. Setup — do this before touching code

```bash
cd /Users/xanderevans/Documents/fantasy-app && git status
```

Branch `m27-puzzle-blitz`, at `95a5f13`. `main` is production — do not merge without asking.

⚠️ **The tree is not clean, and none of it is M28.** As of 2026-08-26 10:30 a parallel
workstream (StoreKit entitlement claims, the paywall sign-in prompt, Over/Under, and the
`claim-entitlement` edge function) has uncommitted changes in ~15 files plus five untracked
ones. Two consequences:

- **`BallIQ/Localizable.xcstrings` is already modified by that work.** A6 mutates the same file.
  Re-read it immediately before running A6's script, and keep your string additions in their own
  commit so the two sets of keys stay reviewable apart.
- **The 844 below is stale by design.** That work adds test files. Take your own baseline (0.2)
  rather than trusting the number, and compare against *that*.

None of it touches Who Am I?, `Theme.swift`, or the ingest pipeline, so there is no conflict with
Part A's own files.

### 0.1 🔴 Claim a simulator before you touch it — this Mac is shared

**Multiple Claude Code sessions share these simulators** (8 devices, ~6 live sessions as of
2026-08-26). Driving a booted device another session is using corrupts both runs in a way that
does not look like contention: taps land in the other session's app state, and a relaunch reads
as a crash. AGENTS.md §7.1 already records an hour lost to the single-session version of this.

There is a lock protocol at **`/tmp/balliq-sim-locks/README.md`** — read it. Claim before **any**
`simctl` or simulator-MCP call:

```bash
D=<UDID>; ME=<your-session-name>
if ln -s "$ME" /tmp/balliq-sim-locks/$D 2>/dev/null; then echo GOT; else echo "HELD BY $(readlink /tmp/balliq-sim-locks/$D)"; fi
```

`ln -s` is atomic and fails if the lock exists — do **not** substitute `test -f` then write.
Release the moment you're done: `rm -f /tmp/balliq-sim-locks/$D`. If a device is held, take a
free one from the README's list of 8 rather than queueing; message the holder only if you need
that specific device. A lock whose session is gone from `ListAgents` is stale — message the
holder before removing it, never just delete it.

The roles below are what this doc's commands assume. **They are conventions, not reservations**
— if one is locked, claim a comparable free device and substitute its UDID, **with one
exception**: A8.4's dead-space measurement is calibrated to the 6.9" `1320×2868` frame. Its
numbers (1,533 px before, ~214 px after, one row = 226 px) do not transfer to any other screen
size. If `Sprout-ProMax` is held, either wait for it or ask the holder — do not substitute a
plain iPhone 17 or an SE and compare against these figures. Every other capture is
size-agnostic.

| purpose | name | udid |
|---|---|---|
| **Tests** — never screenshot on this one | `BallIQ-Test-iPhone17` (iOS 26.5) | `448665F0-289F-47A6-BB48-8EFC0FB58A58` |
| **Screenshots, 6.9"** — the store/measurement device | `Sprout-ProMax` (iPhone 17 Pro Max, iOS 26.5) | `36BBF35E-B7CF-4A0B-AEEE-10C60692AAE6` |
| **Screenshots, smallest** — the tightest layout | `Sprout-SE` (iOS 26.5) | `20CA3EDA-AD16-4066-ABFB-48A91BB6FD65` |

Tests and screenshots must still be on **different** devices even when both are free — that
constraint predates the lock protocol and is about your own two workloads colliding, not other
sessions'.

⚠️ **As of 2026-08-26 13:28, session `fantasy-app-d1` holds `448665F0` for an FTUE cold-install
analysis.** Check the lock before assuming it's yours.

⚠️ **`BallIQ.app` was left installed on `36BBF35E` by the research pass that produced this doc.**
Whoever claims it first: `uninstall` **and** `defaults delete` (see A8.3) before trusting any
fresh-state capture.

Quit Xcode before driving any simulator — its auto-reinstall kills the app mid-session.

### 0.2 Baseline — take your own, then compare against it

Run both **now**, before editing anything, so that if something is red later you know it was you.
The numbers below were measured on a clean `95a5f13` at 10:22 on 2026-08-26; the in-flight work
described above has since added tests, so treat them as the shape to expect, not as targets.

Claim the test device first (§0.1) — `xcodebuild ... test` boots and drives it like anything else:

```bash
TEST_SIM=448665F0-289F-47A6-BB48-8EFC0FB58A58
ln -s "<your-session-name>" /tmp/balliq-sim-locks/$TEST_SIM 2>/dev/null \
  && echo GOT || echo "HELD BY $(readlink /tmp/balliq-sim-locks/$TEST_SIM)"

xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination "id=$TEST_SIM" -derivedDataPath build test 2>&1 | tail -20
```

Expected: `Executed 844 tests, with 12 tests skipped and 0 failures` → `** TEST SUCCEEDED **`,
about 45s once built.

🔴 **The skip count depends on which runtime you claimed, and both numbers are correct:**

| runtime | skipped | why |
|---|---|---|
| **iOS 26.5** (`BallIQ-Test-iPhone17`, `Sprout-*`) | **12** | `PurchaseFlowTests`' 7 methods `XCTSkipUnless` themselves — `SKTestSession` silently drops writes on this runtime (AGENTS.md §7.1) — plus 5 others |
| **iOS 18.3** (`BallIQ-18-3`, `BallIQ-SK-iOS18`) | **5** | the purchase suite actually runs here, 7/7 |

So `5 skipped` is not a regression and `12 skipped` is not a bug — it tells you which runtime you
are on. Do not "fix" either. And note AGENTS.md's standing rule: skipped tests are not coverage,
so anything touching purchases must be run on 18.3 before shipping. M28 touches none, so 26.5 is
the right default here.

Hold this lock for the whole task — you re-run this suite after every step — and release it at
the end. If it's held, claim another iOS 26.5 device and use that UDID everywhere below instead.

⚠️ **One session saw the suite die early; another saw it green. Establish which you have.**
On 2026-08-26 a run on a *shared* iOS 26.5 device died with `Failed to load test bundle` after
`PaywallSignInPromptTests.testRenderEverySignInStateForVisualReview` — one of the in-flight
files above. But the session that owns that work reports the full suite green on `BallIQ-18-3`
the same afternoon: **873 tests, 0 failures, 5 skipped**. And the crash did not reproduce on a
clean `95a5f13` at 10:22, which is where 844/12/0 comes from.

Two green data points and one failure on the contended device makes simulator contention the
leading explanation, not broken code — which is the whole reason §0.1 exists.

This is exactly why 0.2 says take your own baseline. If the suite dies in the same place before
you have changed anything, that is ambient: record where it stops, and from then on compare
**which tests ran and their results**, not the totals. Do not debug the Paywall tests — they
belong to another session. If it dies somewhere new *after* you start editing, that one is
yours.

```bash
/tmp/balliq-venv/bin/python -m pytest tools/ingest/tests/ -q 2>&1 | tail -3
```

Expected: `499 passed`. If the venv is gone:
`python3 -m venv /tmp/balliq-venv && /tmp/balliq-venv/bin/pip install pytest`

Run **both** suites after each numbered step below, not once at the end (AGENTS.md §7).

---

# Part A — M28: make Who Am I? look like the best format in the app

## A0. The problem, measured

Measured on `Sprout-ProMax`, 2026-08-26, on the frames at `1320×2868`. Largest contiguous run
of untouched page background:

| revealed clues | largest empty block | share of screen |
|---|---|---|
| 1 (the state a player opens on) | 1,533 px | **53.5%** |
| 3 | 1,047 px | 36.5% |
| 6 | 105 px | **3.7%** |

**The consequence that governs the whole design:** the space you are filling shrinks 15× as the
board is played, and the 6-clue state has essentially no slack. Any *fixed* element added to
this screen — a large points meter, a hero numeral — fits at clue 1 and overflows at clue 6 by
roughly 1,400 px. The first draft of this doc proposed exactly that, and it does not work.

The empty region is not a hole to plug. It is the five clue slots the player has not bought.
So: **render all six slots from the first frame.** Bought clues look as they do today; unbought
clues are locked rows carrying their price. Zero dead space by construction, no reflow when a
clue is bought, and the 6-clue end state stays exactly the layout that ships today.

## A0.1 🔴 The one rule that cannot be broken

**Nothing on the play board may reveal information about the subject before the player buys it.**

This kills two tempting ideas:

- **Team colours anywhere on the play board.** `teams` is one of the clue families; painting the
  chrome in the subject's club colours answers a clue the player hasn't bought — and on a board
  where "Last team" is clue 5, it answers it from clue 1. Club colour belongs on the *result*
  screen only (A5). This is greppable, and step A8 greps for it.
- **A locked row showing its label.** "Last team" printed on locked slot 5 tells you slot 5 is a
  team clue. Locked rows carry **position and price only.**

Position and price are pure functions of the clue index and the difficulty tier, and the tier is
already printed in the header (`HARD · 1.6x points`). So the whole price ladder is derivable
from what ships today — it leaks nothing. (Note the client already holds all six clues in memory
and always has; `revealedCount` is a display convention. A5 is not weakening anything.)

---

## A1. New file — `BallIQ/Models/ClueFamily.swift`

The `.xcodeproj` uses synchronized file groups (`objectVersion 77`), so a new `.swift` file
under `BallIQ/` is picked up automatically. **Do not edit the pbxproj.**

### Why family and not `ClueKind` — this is the corrected part

The first draft keyed chip colour off `ClueKind` because `Clue.dimension` is nil on legacy
content and would "leave half the archive uncoloured." Measured against all 916 live `whoami`
rows in production on 2026-08-26:

- **864 of 916 boards (94%) carry `dimension` on every clue.** Not half.
- The 52 that don't are not a mixed bag — **every one is the identical legacy six**
  (`era, position, teams, statLine, fact, jersey`, one each, in that order). One shape, one
  fallback, fully covered.
- And `kind` does not do the job anyway. `tools/ingest/whoami_clues.py` maps its 32 dimensions
  onto six wire-compatible kinds, lopsidedly. Keyed off `kind`, **70 of 916 boards get three or
  more identical chips**, 15 get four, and `nfl-whoami-barry-sanders` gets **five of six
  identical** — a stack of identical rectangles, which is the exact thing this change exists to
  fix.
- Keyed off `family`, **0 of 916 boards exceed two of any colour**, because `select_clues` caps
  each family at 2 while breadth allows. The spread is enforced by the generator, not hoped for.

`family` is not on the wire and does not need to be. Derive it on the client.

### The file

```swift
import SwiftUI

/// The angle a Who Am I? clue comes from — the taxonomy the clue pipeline actually selects
/// against (`tools/ingest/whoami_clues.py`'s `Dimension.family`), ported to the client so the
/// board can colour its clue chips by something that means anything.
///
/// **Why this and not `ClueKind`.** `ClueKind` is a wire-compatibility contract, not a
/// taxonomy: the pipeline maps 32 dimensions onto its six fixed values so already-shipped App
/// Store builds can still decode, and the mapping is lopsided. Measured against all 916 live
/// boards on 2026-08-26, keying chip colour off `kind` puts three or more identical chips on 70
/// boards and five identical chips on `nfl-whoami-barry-sanders`. `family` is capped at two per
/// board by `select_clues`, so it never does that — 0 of 916.
///
/// **`family` is deliberately NOT on the wire.** It is derived here from `Clue.dimension`, with
/// `Clue.kind` as the fallback for content minted before dimensions existed (52 of 916 boards,
/// every one of them the identical legacy six). Adding a `family` field to the JSON would mean
/// touching the clue contract, which is the thing the pipeline bends over backwards to avoid.
///
/// `byDimension` is a hand-port of the Python registry and would drift silently on the next
/// dimension added — `test_clue_families_match_the_swift_map` in
/// `tools/ingest/tests/test_whoami_clues.py` reads this file back and fails if it does. That's
/// the same posture as `test_point_multipliers_match_the_swift_table`.
enum ClueFamily: String, CaseIterable {
    case career, bio, draft, team, production, story

    /// The family a clue belongs to. Never fails: an unrecognised dimension (a new one the
    /// pipeline shipped before this map was updated) falls through to the `kind` mapping, which
    /// is total.
    static func of(_ clue: WhoAmIPuzzle.Clue) -> ClueFamily {
        if let dimension = clue.dimension, let family = byDimension[dimension] { return family }
        return fallback(clue.kind)
    }

    /// Every legacy `ClueKind`, mapped to the family its own dimension carries in the registry.
    /// `jersey` lands on `.bio` because that's where the `jersey` dimension actually sits.
    private static func fallback(_ kind: ClueKind) -> ClueFamily {
        switch kind {
        case .era:      return .career
        case .position: return .bio
        case .jersey:   return .bio
        case .teams:    return .team
        case .statLine: return .production
        case .fact:     return .story
        }
    }

    /// All 32 dimensions in `whoami_clues.DIMENSIONS`, keyed to their `family` column.
    private static let byDimension: [String: ClueFamily] = [
        "era": .career, "longevity": .career, "debut": .career, "finale": .career,
        "position": .bio, "weight": .bio, "height": .bio, "born": .bio,
        "ageAtDebut": .bio, "frame": .bio, "jersey": .bio, "college": .bio,
        "conference": .bio,
        "draftClass": .draft, "undrafted": .draft, "draftRound": .draft,
        "draftTeam": .draft, "draftPick": .draft,
        "league": .team, "nationality": .team, "franchiseCount": .team, "oneTeam": .team,
        "firstTeam": .team, "lastTeam": .team, "teams": .team,
        "peakYear": .production, "bestSeason": .production, "statLine": .production,
        "accolades": .story, "initials": .story, "fact": .story, "nickname": .story,
    ]

    /// Chip fill. Existing `Theme.swift` role tokens only — DESIGN.md keeps the palette small,
    /// and six new hex constants would be six new things to re-audit for contrast.
    ///
    /// **`dangerFill`/`dangerText` are deliberately excluded**, and no family may ever take
    /// them: the wrong-guess counter directly below this list is `Color.dangerText`, and red on
    /// a clue chip would read as "you got that one wrong".
    var chipFill: Color {
        switch self {
        case .career:     return .accentFill    // electric blue — the dominant
        case .bio:        return .proFill       // purple
        case .draft:      return .goldFill      // trophy gold
        case .team:       return .successFill   // green
        case .production: return .warningFill   // hot orange
        case .story:      return .voltFill      // lime — the sharp accent
        }
    }

    /// Legible ink on `chipFill`. Each is the `on*` token Theme.swift already pairs with that
    /// fill, so contrast is inherited rather than re-guessed.
    var onChip: Color {
        switch self {
        case .career:     return .onAccent
        case .bio:        return .onPro
        case .draft:      return .onGold
        case .team:       return .onSuccess
        case .production: return .onWarning
        case .story:      return .onVolt
        }
    }
}
```

**One judgement call, flagged rather than hidden:** `successFill` green and `warningFill` orange
carry semantic weight elsewhere in the app (correct / streak flame). They do not collide *on
this screen* — the clue list has no correctness signalling, and the only semantic colour on the
play board is `dangerText` in the guess bar, which is why red is excluded above. If the A8
screenshots read wrong, swapping two cases here is a one-line change. Do not swap in `danger`.

---

## A2. New pure function — `WhoAmIScoring.cost(toUnlock:difficulty:)`

**File:** `BallIQ/Models/WhoAmIPuzzle.swift`. Add inside `enum WhoAmIScoring`, directly after
`maxScore(difficulty:)`:

```swift
    /// What unlocking clue number `n` costs, for `2...clues.count`. Clue 1 is always shown, so
    /// `cost(toUnlock: 1)` is 0.
    ///
    /// This is the whole price ladder the board renders now, not just the next step —
    /// `WhoAmIGameView.nextCueCost` is one call into it. Derived from `value(cluesUsed:)`
    /// rather than from `perClue` directly so the difficulty multiplier is applied exactly
    /// once, the same way the header's "Worth N pts" already does it.
    static func cost(toUnlock n: Int, difficulty: WhoAmIPuzzle.Difficulty?) -> Int {
        guard n > 1 else { return 0 }
        return value(cluesUsed: n - 1, difficulty: difficulty)
             - value(cluesUsed: n, difficulty: difficulty)
    }
```

Then **replace** `nextCueCost` in `WhoAmIGameView.swift` (currently lines 52–56) so there is one
formula, not two:

```swift
    private var nextCueCost: Int {
        guard !allRevealed else { return 0 }
        return WhoAmIScoring.cost(toUnlock: revealedCount + 1, difficulty: puzzle.difficulty)
    }
```

This is a pure refactor — algebraically identical to what's there. **The displayed number must
not change.** The test in A7 pins that.

For reference, a HARD (1.6×) board's ladder is `1600, 1280, 960, 640, 320, 160`, so the unlock
costs are `−320, −320, −320, −320, −160`. That matches the `Next clue · −320 pts` visible in the
current screenshots — if your first render disagrees, you have a bug, not a design question.

---

## A3. Colour the clue chip by family

**File:** `BallIQ/Features/WhoAmI/WhoAmIGameView.swift`, `clueRow(_:)` at line 216.

Replace the opening of the function and the chip's two colour lines. Current:

```swift
    private func clueRow(_ clue: WhoAmIPuzzle.Clue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(clue.order)")
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(Color.accentText)
                .frame(width: 26, height: 26)
                .background(Color.accentBg)
                .clipShape(Circle())
```

New — note `let` before `return`, because a `ViewBuilder` body cannot hold a bare statement:

```swift
    private func clueRow(_ clue: WhoAmIPuzzle.Clue) -> some View {
        let family = ClueFamily.of(clue)
        return HStack(alignment: .top, spacing: 12) {
            Text("\(clue.order)")
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(family.onChip)
                .frame(width: 26, height: 26)
                .background(family.chipFill)
                .clipShape(Circle())
```

Everything below that line in `clueRow` is unchanged, including
`.accessibilityElement(children: .combine)`.

**Do not add an SF Symbol to the chip.** The chip carries the clue number, which is load-bearing
ordering information, and the row's label text (`Longevity`, `Draft class`) already
differentiates the clue non-visually — so colour is a redundant cue here, not the only one, and
WCAG 1.4.1 is satisfied without a second glyph.

---

## A4. The clue ladder — render all six slots

**File:** `BallIQ/Features/WhoAmI/WhoAmIGameView.swift`.

### A4.1 The loop, in `playBoard` (lines 126–134)

Replace:

```swift
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(puzzle.clues.prefix(revealedCount)) { clue in
                        clueRow(clue)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(16)
            }
```

with:

```swift
            ScrollView {
                VStack(spacing: 10) {
                    // Identity is POSITION, not `Clue.id` — a locked slot and the clue that
                    // replaces it are the same row, so buying a clue animates in place instead
                    // of inserting. Position also matches how `revealedCount` is used
                    // everywhere else in this file (it was `prefix(revealedCount)`).
                    ForEach(Array(puzzle.clues.enumerated()), id: \.offset) { index, clue in
                        if index < revealedCount {
                            clueRow(clue)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        } else {
                            lockedRow(position: index + 1)
                        }
                    }
                }
                .padding(16)
            }
```

### A4.2 The new row, next to `clueRow` in the same file

```swift
    /// An unbought clue slot. Rendered from the first frame so the board is the same shape at
    /// clue 1 as at clue 6 — at the opening state 53.5% of this screen used to be empty page
    /// background and at the close only 3.7% was, so there was never one fixed thing that could
    /// fill it. The five unbought clues are that thing.
    ///
    /// Carries the position and the price and **nothing else**. The clue's own label would leak
    /// its dimension ("Last team" on slot 5 answers slot 5), which is the one thing this screen
    /// may never do. Position and price are pure functions of the clue index and the difficulty
    /// tier, and the tier is already printed in the header, so this reveals nothing new.
    ///
    /// Deliberately **not tappable**: the "Next clue" button stays the only purchase path, so
    /// clues can't be bought out of order — `revealedCount` means "the first N clues", and every
    /// score derived from it assumes exactly that.
    private func lockedRow(position: Int) -> some View {
        let cost = WhoAmIScoring.cost(toUnlock: position, difficulty: puzzle.difficulty)
        return HStack(alignment: .top, spacing: 12) {
            Text("\(position)")
                .font(.custom(FontName.condBlack, size: 14))
                .foregroundStyle(Color.textDisabled)
                .frame(width: 26, height: 26)
                .background(Color.surfaceMuted)
                .clipShape(Circle())
            // Two lines, mirroring `clueRow`'s label+text stack on purpose: it makes a locked
            // row exactly as tall as a one-line revealed row, so the ladder is even and buying
            // a clue never jumps the rows below it.
            VStack(alignment: .leading, spacing: 2) {
                Text("Locked")
                    .font(.label11)
                    .foregroundStyle(Color.textMuted)
                // Inside a blitz this is a share of the board's own maximum, never points —
                // same rule as the header and the Next clue button. See `BlitzBoardValue`.
                Text(blitz == nil
                     ? String(localized: "−\(cost) pts")
                     : BlitzBoardValue.cost(cost,
                                            of: WhoAmIScoring.maxScore(difficulty: puzzle.difficulty)))
                    .font(.body14)
                    .foregroundStyle(Color.textDisabled)
            }
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(blitz == nil
            ? String(localized: "Clue \(position), locked, costs \(cost) points")
            : String(localized: "Clue \(position), locked"))
    }
```

Notes an implementer will otherwise wonder about:

- `lock.fill` + `Color.textMuted` is this app's existing locked vocabulary (`CareerSections`,
  `SportFilterBar`, `GameSetupScreen`). **Do not invent a dashed border** — there is no
  `StrokeStyle(dash:)` anywhere in the codebase and this is not the place to add the first one.
- `Color.surfaceMuted` (no `cardSurface()`, no shadow) is what makes a locked row read as a
  recessed slot rather than a card. `cardSurface()` on a locked row makes the ladder look like
  six real clues.
- A community-authored puzzle can carry fewer than six clues. Nothing above assumes six.
- **A board with *more* than six clues would price the extras at zero**, and the row would read
  `−0 pts`. This cannot happen today — `CreateWhoAmIView` is hardcoded to exactly six kinds, and
  all 916 production boards carry exactly six — but nothing in the decode path caps it, so it is
  worth knowing why it's safe rather than discovering it later. The cause is pre-existing and
  not something this change introduces: `WhoAmIScoring.perClue` has six entries and
  `value(cluesUsed:)` clamps its index, so clue 7 is already worth the same as clue 6 today. The
  ladder just makes that visible. **The real invariant is `perClue.count >= clues.count`**; if
  the pipeline ever raises `whoami_clues.CLUE_COUNT` above 6, `perClue` has to grow in the same
  change, and scoring is wrong with or without the ladder. A7.2 pins it.

---

## A5. Answer card in club colours (result screen only)

### A5.1 `BallIQ/Models/WhoAmIPuzzle.swift` — expose the matched row

`WhoAmIAnswerPhoto.headshot(from:for:)` (line 123) already finds the right catalog row and then
throws everything away except the URL. The result screen needs that row's `teamAbbr`. Split it,
**keeping the existing filter exactly as-is** so `headshot` stays byte-identical:

```swift
    /// The catalog row this puzzle's answer resolves to, under the conservative rules above.
    /// `headshot(from:for:)` is a thin wrapper over this, so the two can never disagree about
    /// *which* player matched — the result screen paints the reveal in this row's club colours
    /// (M28 A5) and must be looking at the same player as the photo.
    ///
    /// Note this inherits the `headshot != nil` filter, so a subject with no photo also gets no
    /// club colour. That's deliberate: a second, looser match would resolve a team for players
    /// the strict rules rejected, and a *wrong* club colour on the reveal is worse than the
    /// neutral blue it falls back to.
    static func match(from rows: [CatalogSeason], for puzzle: WhoAmIPuzzle) -> CatalogSeason? {
        let accepted = Set(([puzzle.answer.canonical] + puzzle.answer.aliases)
            .map(AnswerMatcher.normalize))
        let span = eraSpan(of: puzzle)
        return rows
            .filter { row in
                guard let headshot = row.headshot, !headshot.isEmpty,
                      accepted.contains(AnswerMatcher.normalize(row.name)) else { return false }
                guard let span else { return true }
                let lo = row.firstYear ?? row.seasonYear
                let hi = Swift.max(lo, row.lastYear ?? row.seasonYear)
                return (lo...hi).overlaps(span)
            }
            .max { $0.seasonYear < $1.seasonYear }   // latest row → most recent photo
    }

    static func headshot(from rows: [CatalogSeason], for puzzle: WhoAmIPuzzle) -> String? {
        match(from: rows, for: puzzle)?.headshot
    }
```

### A5.2 `BallIQ/Features/WhoAmI/WhoAmIResultView.swift`

Replace the `answerHeadshot` state (line 27) with the row, and derive both from it:

```swift
    /// The catalog row the answer resolved to — supplies both the headshot and the club palette
    /// the reveal is flooded with. nil when no confident match exists (see `WhoAmIAnswerPhoto`),
    /// in which case the card stays on `accentFill` exactly as it shipped.
    @State private var answerRow: CatalogSeason?

    private var answerHeadshot: String? { answerRow?.headshot }
    private var answerPalette: TeamPalette? {
        guard let answerRow else { return nil }
        return TeamColors.palette(sport: puzzle.sport, abbr: answerRow.teamAbbr,
                                  league: answerRow.league)
    }
    private var answerFill: Color { answerPalette?.primary ?? .accentFill }
    private var onAnswerFill: Color { answerPalette?.onPrimary ?? .onAccent }
```

In `.task` (line 67–71), replace the assignment:

```swift
            answerRow = WhoAmIAnswerPhoto.match(from: rows, for: puzzle)
```

In `answerCard` (lines 96–116), swap the four hardcoded accent references:

| line | from | to |
|---|---|---|
| 99 | `tint: Color.onAccent` | `tint: onAnswerFill` |
| 102 | `.foregroundStyle(Color.onAccent.opacity(0.75))` | `.foregroundStyle(onAnswerFill.opacity(0.75))` |
| 105 | `.foregroundStyle(Color.onAccent)` | `.foregroundStyle(onAnswerFill)` |
| 111 | `.background(Color.accentFill)` | `.background(answerFill)` |

`TeamColors.palette(sport:abbr:league:)` already does the perceptual-luma check for
`onPrimary`, so contrast is handled — do not hand-pick a text colour.

**Leave `WhoAmIShareCardView` alone.** It deliberately takes only `sport`/`clueCount`/`result`
so it is structurally impossible for the share image to leak the answer. Club colour is
answer-identifying. Do not thread the palette into it.

---

## A6. Strings — four new keys

`BallIQ/Localizable.xcstrings` is an ~847-key catalog with `en` + `es`. **Do not hand-edit it,
and do not round-trip it through `json.dump()`** — these are two different mistakes and the
second one looks safe:

- Xcode writes this file with **`" : "` separators** (space, colon, space). There are 4,175 of
  those and **zero** `": "`. Any `json.dump()` rewrites every one.
- Key order is **ICU collation**, not codepoint order. `—`, `…`, `·` sort before `%` here;
  Python's `sorted()` cannot reproduce it, and 71 keys have non-alphanumeric initials.

Doing both turns a 4-key addition into roughly **4,300 insertions and 4,400 deletions** — which
matters more than usual right now, because two other sessions have this file open (see §0).

Use the splice below. It parses to see what already exists, but **edits as text**, so every
untouched byte stays untouched. It is idempotent — re-running adds nothing.

Verified 2026-08-26: stripping these four keys from the live catalog and re-adding them with
this script reproduces the file **byte-for-byte** (`diff` empty).

```python
#!/usr/bin/env python3
"""Add localized strings to Localizable.xcstrings WITHOUT reserializing the file.

Xcode writes this catalog with `" : "` separators and ICU-collated key order. Any
`json.dump()` round-trip changes both — a 4-key addition comes out as a ~4,300-line diff,
which is exactly what it must not do (three sessions have this file open). So: parse to
check what's already there, but edit as text, splicing whole blocks in and leaving every
untouched byte alone. Idempotent — re-running is a no-op.
"""
import json, sys

P = 'BallIQ/Localizable.xcstrings'

# key -> (spanish, anchor key, 'before'|'after')  — anchors must already exist.
# Position is cosmetic: Xcode re-collates on its next save. Validity is what matters.
NEW = [
    ("Clue %lld, locked, costs %lld points",
     "Pista %lld, bloqueada, cuesta %lld puntos", "Clue %lld of %lld", "after"),
    ("Clue %lld, locked", "Pista %lld, bloqueada", "Clue %lld of %lld", "after"),
    ("Locked", "Bloqueada", "Locked character, unlocks at rung %lld", "before"),
    ("−%lld pts", "−%lld pts", "@%@", "after"),
]

def block(key, es):
    k = json.dumps(key, ensure_ascii=False)
    v = json.dumps(es, ensure_ascii=False)
    return (f'    {k} : {{\n'
            f'      "localizations" : {{\n'
            f'        "es" : {{\n'
            f'          "stringUnit" : {{\n'
            f'            "state" : "translated",\n'
            f'            "value" : {v}\n'
            f'          }}\n'
            f'        }}\n'
            f'      }}\n'
            f'    }},\n')

def span(src, key):
    """(start, end) offsets of `key`'s whole block, including its trailing `,\\n`."""
    marker = f'\n    {json.dumps(key, ensure_ascii=False)} : {{'
    i = src.index(marker) + 1
    depth, j = 0, i
    while True:
        c = src[j]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                j += 1
                if j < len(src) and src[j] == ',': j += 1
                if j < len(src) and src[j] == '\n': j += 1
                return i, j
        j += 1

src = open(P, encoding='utf-8').read()
added = 0
for key, es, anchor, where in NEW:
    if key in json.loads(src)['strings']:
        print('present, skipping:', key); continue
    s, e = span(src, anchor)
    at = s if where == 'before' else e
    src = src[:at] + block(key, es) + src[at:]
    added += 1
    print(f'added: {key!r}  ({where} {anchor!r})')

if added:
    json.loads(src)                      # refuse to write invalid JSON
    open(P, 'w', encoding='utf-8').write(src)
print(f'{added} added')
```

Run it from the repo root, then confirm the churn is small — single digits of insertions, zero
deletions:

```bash
python3 tools/xcstrings_add.py && git diff --stat BallIQ/Localizable.xcstrings
```

(The script above is also checked in at `tools/xcstrings_add.py`, so you can run it directly
rather than pasting it.)

If `git diff --stat` reports thousands of changed lines, you reserialized the file: `git
checkout BallIQ/Localizable.xcstrings` **only if you have no other work in it** (§0 warns that
another session might), and re-run the splice.

The key for an interpolated string is its format string, so `String(localized: "−\(cost) pts")`
keys as `−%lld pts`. That leading character is U+2212 MINUS SIGN, matching the existing
`Next clue · −%lld pts` entry — **not** an ASCII hyphen. Copy it, don't retype it.

Anchor positions in the script are **cosmetic** — Xcode re-collates on its next save. What
matters is that the result is valid JSON, which the script asserts before writing.

Then extend `BallIQTests/LocalizationTests.swift` in the shape its existing tests already use:

```swift
    /// M28's clue ladder added a screen's worth of locked-slot copy at once; a whole feature's
    /// keys going missing from the catalog is invisible in English and total in every other
    /// locale.
    func testClueLadderCopyIsLocalized() {
        XCTAssertEqual(es("Locked"), "Bloqueada")
    }
```

---

## A7. Tests to add

### A7.1 New file — `BallIQTests/ClueFamilyTests.swift`

```swift
import XCTest
import SwiftUI
import UIKit          // `UIColor` for the resolved-colour comparison below
@testable import BallIQ

final class ClueFamilyTests: XCTestCase {

    private func clue(_ order: Int, _ kind: ClueKind, dimension: String? = nil) -> WhoAmIPuzzle.Clue {
        WhoAmIPuzzle.Clue(order: order, kind: kind, text: "t", dimension: dimension, label: nil)
    }

    /// Resolved RGBA, so two tokens can be compared without relying on `Color: Equatable`
    /// (which compares provenance, not appearance).
    private func rgba(_ c: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f,%.3f,%.3f,%.3f", r, g, b, a)
    }

    func testDimensionWinsOverKind() {
        // 16 dimensions ride on `.fact`; the dimension is what actually says which angle it is.
        XCTAssertEqual(ClueFamily.of(clue(1, .fact, dimension: "draftClass")), .draft)
        XCTAssertEqual(ClueFamily.of(clue(2, .fact, dimension: "weight")), .bio)
        XCTAssertEqual(ClueFamily.of(clue(3, .fact, dimension: "accolades")), .story)
    }

    func testLegacyClueWithNoDimensionFallsBackToKind() {
        XCTAssertEqual(ClueFamily.of(clue(1, .era)), .career)
        XCTAssertEqual(ClueFamily.of(clue(2, .position)), .bio)
        XCTAssertEqual(ClueFamily.of(clue(3, .teams)), .team)
        XCTAssertEqual(ClueFamily.of(clue(4, .statLine)), .production)
        XCTAssertEqual(ClueFamily.of(clue(5, .fact)), .story)
        XCTAssertEqual(ClueFamily.of(clue(6, .jersey)), .bio)
    }

    /// A dimension the pipeline ships before this map learns about it must still colour, not
    /// crash or blank.
    func testUnknownDimensionFallsBackToKind() {
        XCTAssertEqual(ClueFamily.of(clue(1, .fact, dimension: "somethingNewIn2027")), .story)
    }

    /// The real production board that motivated keying off family instead of kind: by `kind`
    /// it is five identical chips out of six.
    func testBarrySandersBoardNeverRepeatsAFamilyMoreThanTwice() {
        let board = [clue(1, .era,  dimension: "era"),
                     clue(2, .fact, dimension: "weight"),
                     clue(3, .fact, dimension: "draftClass"),
                     clue(4, .fact, dimension: "ageAtDebut"),
                     clue(5, .fact, dimension: "draftPick"),
                     clue(6, .fact, dimension: "accolades")]
        let byKind = Dictionary(grouping: board, by: { $0.kind }).values.map(\.count).max()
        XCTAssertEqual(byKind, 5, "fixture drifted — this board is the 5-identical-kinds case")

        let byFamily = Dictionary(grouping: board, by: ClueFamily.of).values.map(\.count).max()
        XCTAssertEqual(byFamily, 2)
    }

    func testEveryFamilyHasItsOwnChipColour() {
        let fills = Set(ClueFamily.allCases.map { rgba($0.chipFill) })
        XCTAssertEqual(fills.count, ClueFamily.allCases.count)
    }

    /// The wrong-guess counter on the same screen is `dangerText`. A clue chip in the danger
    /// family would read as "you got that one wrong".
    func testNoFamilyUsesTheDangerTokens() {
        let banned = Set([rgba(.dangerFill), rgba(.dangerText)])
        for family in ClueFamily.allCases {
            XCTAssertFalse(banned.contains(rgba(family.chipFill)),
                           "\(family) took a danger token")
        }
    }
}
```

### A7.2 Append to `BallIQTests/WhoAmIScoringTests.swift`

```swift
    /// `cost(toUnlock:)` must stay algebraically identical to the header delta it replaced —
    /// this is the pin on A2's refactor.
    func testUnlockCostIsTheDropInBoardValue() {
        // Spelled out rather than inferred from the literal — a mixed `[nil, .easy, …]` array
        // doesn't always infer to `[Difficulty?]`. nil is "unrated", which is its own tier
        // (1.0×), not a synonym for medium.
        let tiers: [WhoAmIPuzzle.Difficulty?] = [nil, .easy, .medium, .hard]
        for difficulty in tiers {
            XCTAssertEqual(WhoAmIScoring.cost(toUnlock: 1, difficulty: difficulty), 0)
            for n in 2...WhoAmIScoring.perClue.count {
                XCTAssertEqual(
                    WhoAmIScoring.cost(toUnlock: n, difficulty: difficulty),
                    WhoAmIScoring.value(cluesUsed: n - 1, difficulty: difficulty)
                        - WhoAmIScoring.value(cluesUsed: n, difficulty: difficulty),
                    "tier \(String(describing: difficulty)), clue \(n)")
            }
        }
    }

    /// The ladder a HARD board actually renders. Locked in as literals so a scoring tweak can't
    /// silently change what the board advertises.
    func testHardBoardPriceLadder() {
        let ladder = (2...6).map { WhoAmIScoring.cost(toUnlock: $0, difficulty: .hard) }
        XCTAssertEqual(ladder, [320, 320, 320, 320, 160])
    }

    /// Every clue on the longest board the scoring table can price must cost something — a
    /// locked row reading `−0 pts` means the board outran `perClue`.
    ///
    /// Deliberately written against `perClue.count` rather than the literal 6, so that raising
    /// the pipeline's `CLUE_COUNT` without extending `perClue` fails here instead of shipping a
    /// ladder of free clues. Every fixture in these tests is a six-clue board built by hand, so
    /// nothing else in the suite would notice.
    func testEveryPricedClueCostsSomething() {
        for n in 2...WhoAmIScoring.perClue.count {
            XCTAssertGreaterThan(WhoAmIScoring.cost(toUnlock: n, difficulty: nil), 0, "clue \(n)")
        }
    }
```

### A7.3 Append to `tools/ingest/tests/test_whoami_clues.py`

This is the drift guard. Same shape as `test_point_multipliers_match_the_swift_table` above it.

```python
def test_clue_families_match_the_swift_map():
    """`ClueFamily.byDimension` is a hand-port of DIMENSIONS' family column. Read it back out
    of the Swift source so adding a dimension without updating the client fails here rather
    than silently dropping that clue onto its `kind` fallback colour."""
    import pathlib
    import re
    swift = (pathlib.Path(__file__).resolve().parents[3]
             / "BallIQ" / "Models" / "ClueFamily.swift").read_text(encoding="utf-8")
    body = re.search(r"byDimension: \[String: ClueFamily\] = \[(.*?)\n    \]", swift, re.S)
    assert body, "couldn't find ClueFamily.byDimension"
    found = dict(re.findall(r'"(\w+)":\s*\.(\w+)', body.group(1)))
    expected = {d.key: d.family for d in DIMENSIONS}
    assert found == expected
```

No import changes needed: that module already does
`from tools.ingest.whoami_clues import (CLUE_COUNT, DIMENSIONS, POINT_MULTIPLIER, …)`, and
`Dimension`'s fields are `key, kind, label, reveal, family, build` — both verified 2026-08-26.

---

## A8. Verification — run all of it

### A8.1 Both suites

You should still hold the test-device lock from 0.2. If not, re-claim before running.

```bash
xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination "id=$TEST_SIM" -derivedDataPath build test 2>&1 | tail -20
/tmp/balliq-venv/bin/python -m pytest tools/ingest/tests/ -q 2>&1 | tail -3
```

Expect **your 0.2 baseline + your new tests** executed, the **same skip count as your baseline**,
**0 failures**, and your Python baseline + 1. A skip count that moved means you changed something
you didn't mean to.

### A8.2 The leak grep — must print nothing

```bash
grep -n "TeamColors\|TeamIdentityIndex\|teamAbbr\|TeamPalette" BallIQ/Features/WhoAmI/WhoAmIGameView.swift
```

Silence is the pass condition. Any hit means club colour reached the play board, which is A0.1's
red line. (`WhoAmIResultView.swift` *should* have hits — that's A5.)

### A8.3 Screenshots — 6.9", three states

Two traps this repo has already paid for, both of which produce a *plausible-looking wrong
screenshot* rather than an error:

- `simctl uninstall` does **not** clear UserDefaults — cfprefsd caches the prefs plist by
  bundle id, so the app can relaunch with old state. Delete the domain explicitly, below.
- The shell here is **zsh, which does not word-split unquoted parameters.** Wrapping the launch
  in a helper like `snap() { xcrun simctl launch "$SIM" com.balliqfantasy.app $2 }` passes
  `"-screenshotWhoAmI -screenshotWhoAmIClues 3"` as one malformed argument; the DebugLaunch
  flags then never match and every capture silently lands on Home. Pass flags as separate
  literal words, as below, and eyeball the first capture before trusting a batch.

```bash
SIM=36BBF35E-B7CF-4A0B-AEEE-10C60692AAE6
# Claim it first (§0.1). If this prints HELD BY, take a free device from the README instead.
ln -s "<your-session-name>" /tmp/balliq-sim-locks/$SIM 2>/dev/null \
  && echo GOT || echo "HELD BY $(readlink /tmp/balliq-sim-locks/$SIM)"

xcrun simctl uninstall $SIM com.balliqfantasy.app
xcrun simctl spawn $SIM defaults delete com.balliqfantasy.app 2>/dev/null
xcrun simctl install $SIM build/Build/Products/Debug-iphonesimulator/BallIQ.app
for n in 1 3 6; do
  xcrun simctl terminate $SIM com.balliqfantasy.app 2>/dev/null
  xcrun simctl launch $SIM com.balliqfantasy.app -screenshotWhoAmI -skipStoreKit -screenshotWhoAmIClues $n
  sleep 6
  xcrun simctl io $SIM screenshot after-${n}clue.png
done

rm -f /tmp/balliq-sim-locks/$SIM      # release as soon as the captures are on disk
```

### A8.4 The dead-space measurement — this is the exit criterion, not a vibe

Same script that produced A0's numbers.

```bash
python3 - <<'EOF'
from PIL import Image
cream = (244, 241, 233)          # Color.surface0 light, #F4F1E9
for n in (1, 3, 6):
    im = Image.open(f'after-{n}clue.png').convert('RGB')
    w, h = im.size
    runs, start = [], None
    for y in range(h):
        row = [im.getpixel((x, y)) for x in range(0, w, 8)]
        f = sum(1 for p in row if max(abs(p[i]-cream[i]) for i in range(3)) <= 3) / len(row)
        if f >= 0.99:
            start = y if start is None else start
        else:
            if start is not None and y - start > 20: runs.append(y - start)
            start = None
    if start is not None and h - start > 20: runs.append(h - start)
    big = max(runs) if runs else 0
    print(f'{n} clues: largest empty block {big}px ({100*big/h:.1f}% of screen)')
EOF
```

**Pass:** at 1 clue the largest empty block is **under 300 px**, down from 1,533 px. At 3 and 6
clues it can only be smaller than at 1.

**The number to expect is ~214 px, and it is a prediction, not a measurement** — nobody has
rendered this yet. The arithmetic, so you can tell a pass from a near-miss:

| | px |
|---|---|
| scroll viewport on this device | 1,816 |
| one row (measured on the shipping build) | 226 |
| 6 rows + 5×10pt gaps + 16pt padding top and bottom | 1,602 |
| → trailing empty | **214** |

If you measure meaningfully more than ~214 px, the likely cause is a locked row rendering
**shorter** than a revealed one — check that `lockedRow`'s two-line `VStack` matches `clueRow`'s
`label11` + `body14` structure exactly. That is the whole reason A4.2 builds it that way instead
of using a single line and a fixed height.

If it lands just over 300 px for a reason you've confirmed is only geometry, raise the `VStack`
spacing from 10 to 12 rather than padding a row to a magic height, and say so in the PR.

On `Sprout-SE` the viewport is far shorter, so the ladder will overflow and scroll at 1 clue.
That is expected, not a failure — the criterion above is for the 6.9" device.

### A8.5 The states most likely to break (AGENTS.md §5)

- **Smallest device, fullest board** — the tightest layout in the app:
  `SIM=20CA3EDA-AD16-4066-ABFB-48A91BB6FD65` with `-screenshotWhoAmIClues 6`. All six rows
  present, guess bar not overlapped, no clipped text. **Claim and release this device too** —
  every bullet in this section drives a simulator.
- **Dark mode** — `xcrun simctl ui $SIM appearance dark`, then re-shoot the 1-clue state. Every
  chip fill legible against `surface1` night, locked rows distinguishable from the page.
- **The result reveal in club colours** — `-screenshotWhoAmIResult`. Confirm the answer card is
  the subject's club colour and the text on it is legible. Then find a subject with **no**
  catalog headshot and confirm the card falls back to blue rather than rendering an unreadable
  card.
- **A legacy board** — the `dimension`-nil fallback path, the one A1's first draft got wrong.
  Verified reachable on 2026-08-26:

  ```bash
  SIM=36BBF35E-B7CF-4A0B-AEEE-10C60692AAE6      # claim it first, as in A8.3
  xcrun simctl terminate $SIM com.balliqfantasy.app
  xcrun simctl launch $SIM com.balliqfantasy.app -skipStoreKit \
    -openURL "balliq://play/nfl-whoami-brett-favre-daily-20260722"
  ```

  This board is a **double edge case, which is why it's the one to use**: its clues carry no
  `dimension` (so every chip resolves through `ClueFamily.fallback`), *and* it is unrated
  (`difficulty` nil → no tier chip in the header, 1.0× multiplier). Expect `Worth 1,000 pts`,
  `Clue 1 of 6`, first clue `Era — Played from 1991 to 2010`, and a locked ladder of
  `−200, −200, −200, −200, −100`. All six chips coloured, five distinct families (`jersey` and
  `position` both map to `.bio`) — no grey chips.

Attach before/after pairs to the PR.

---

## A9. Definition of done

- [ ] `ClueFamily.swift` exists; no pbxproj edit was needed.
- [ ] Both suites green against your own 0.2 baseline: 0 failures, skip count unmoved.
- [ ] A8.2's grep prints nothing.
- [ ] A8.4 reports under 300 px at 1 clue (expect ~214 px), down from 1,533 px.
- [ ] Six chips on a live board show at most two of any one colour.
- [ ] A legacy (`dimension`-nil) board renders six coloured chips.
- [ ] The 6-clue layout is unchanged from `95a5f13` apart from chip colour.
- [ ] Result card floods in club colours; falls back to blue with no confident match.
- [ ] Share card still takes only `sport`/`clueCount`/`result`.
- [ ] `Locked` resolves to `Bloqueada` in `es`.
- [ ] VoiceOver reads a locked row as "Clue 4, locked, costs 320 points".
- [ ] **Every simulator lock you took is released** — `ls /tmp/balliq-sim-locks/` shows nothing
      pointing at your session name. Other sessions are queued behind these.

## A10. Do not

1. Put a clue's **label** on a locked row, or any team colour anywhere on the play board.
2. Make locked rows tappable, or allow buying clues out of order.
3. Add a case to `ClueKind`, or add `family` to the JSON. `ClueKind` is decoded by shipped
   builds with **no unknown-case fallback** — a seventh value fails the whole array decode and
   silently drops those users to the 24-entry bundled pool.
4. Give any family a `danger` token.
5. Introduce new hex colour constants, or the codebase's first dashed border.
6. Hand-edit `Localizable.xcstrings`.
7. Run tests and screenshots on the same simulator.
8. Start Part B in this build. B5 (themes) and A4 touch the design-system surface from
   opposite ends.

---

# Part B — M29: unlockables (badges, flair, themes)

**Status: scoped, not implementation-grade.** The mechanism below is sound. The *contents* are
not — they were written against an imagined playerbase and measured against the real one on
2026-08-26, where they award almost nothing. Re-derive B4's shelf before writing a single row.

## B1. Earned, not sold — unchanged

v1 unlockables are earned through play only. Nothing is purchasable.

1. `BALLIQ_SPEC.md` §1 Theme 5 — outcomes reward playing well. A cosmetic economy where the
   best-looking profile belongs to whoever paid inverts "prove you know ball". A badge's whole
   value is that it is *evidence*.
2. §9.3 deprioritised monetization-funnel work in favour of growth and engagement. A cosmetics
   storefront is funnel work wearing a hat.
3. Pro already exists. Selling cosmetics beside it dilutes what Pro means.

**Where Pro does belong:** more equipped slots (3 badges shown vs 1) and early access to a
season's shelf. Never an exclusive badge — that makes a badge a receipt instead of a trophy.

## B2. Awarded server-side — schema unchanged, one source correction

A client that can grant itself a badge will. Award server-side, from counters that already
exist. **All six of these were verified present in production on 2026-08-26:**

| table | rows today | carries |
|---|---|---|
| `game_results` | 43 | per-format play, `perfect`, `score`, `streak_after`, `mode` |
| `arcade_scores` | 1 | `(game, sport)` bests |
| `ratings` | 60 | current rating per sport |
| `rating_history` | 73 | tier climbs |
| `profiles` | 15 | `favorite_teams`, `primary_sport`, `username`, `avatar` |
| `ladder_attempts` | 10 | `rung`, `won` |

🔴 **Correction:** the first draft listed `profiles` as carrying "streak, favourite teams." It
carries `favorite_teams`, but **there is no streak column.** `profiles` is exactly
`id, username, avatar, favorite_teams, primary_sport, is_admin, created_at`. Streak lives on
`game_results.streak_after`, so any streak predicate is a max over that table, not a profile
read. Writing it the other way produces a rule that silently matches nothing.

`blitz_scores` does **not** exist (confirmed: PostgREST `PGRST205`). Any Blitz badge needs it
first — sportless, with a duration column, since a 1-minute and a 5-minute best are different
records. See `LocalBlitzStore`'s doc comment in `BallIQ/Models/Blitz.swift` for why blitz can't
ride on `arcade_scores`.

```sql
create table if not exists public.unlock_definitions (
  id          text primary key,          -- 'perfect_grid_nfl'
  class       text not null check (class in ('badge','flair','theme')),
  name        text not null,
  description text not null,
  rule        jsonb not null,            -- machine-checkable predicate, see B3
  season      text,                      -- null = evergreen
  sort        int  not null default 0
);

create table if not exists public.user_unlocks (
  user_id   uuid not null references auth.users(id) on delete cascade,
  unlock_id text not null references public.unlock_definitions(id),
  earned_at timestamptz not null default now(),
  primary key (user_id, unlock_id)
);
```

RLS on `user_unlocks`: world-readable (badges are public proof; the share card needs them),
writable **only** by `service_role` or a `security definer` award RPC — no insert/update/delete
policy for `authenticated` at all. That mirrors `public.entitlements`, which answers "can a
modified client grant itself Pro" structurally rather than procedurally. Copy that posture.

🔴 **Do not put equipped state on `profiles`.** The first draft said to, with "a trigger or RPC
asserting the user actually owns what they equip." That is the weak version, and the schema
makes it weaker than it sounds:

```sql
create policy "profiles update own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);
```

It's a blanket `for update` — so **any column added to `profiles` is user-writable the moment it
exists**, defended only by whatever trigger someone remembers to write. Equipping is a grant if
you can equip what you don't own, so that puts the trust boundary on a trigger that fails open.

Give equipped state its own table and let a foreign key do the enforcing:

```sql
create table if not exists public.user_equipped (
  user_id   uuid not null references auth.users(id) on delete cascade,
  slot      text not null check (slot in ('badge','flair','theme')),
  ordinal   int  not null default 0,
  unlock_id text not null,
  primary key (user_id, slot, ordinal),
  -- Load-bearing: equipping something you don't own is an FK violation, not a policy decision.
  foreign key (user_id, unlock_id)
    references public.user_unlocks(user_id, unlock_id) on delete cascade
);
```

The payoff is that users can then safely hold write policies on their own rows — the constraint
does the enforcement, so there is nothing for a convenience upsert to erode later. Revoking an
unlock also un-equips it for free via `on delete cascade`.

Two halves, and only one of them is security: **ownership is structural** (the FK above);
**slot count is procedural** — how many badges Pro lets you show has to be checked somewhere,
because entitlement is dynamic. That's fine, because over-equipping is cosmetic overreach, not a
forged grant. Don't conflate them and don't spend the FK's guarantee trying to cover both.

**Concurrency:** `user_unlocks`' `primary key (user_id, unlock_id)` already makes a double-grant
to one user impossible — good. But any *globally* limited unlock ("first 100 to clear rung 20",
early access to a season's shelf) is a different race: a read-then-write "has anyone claimed
this?" check passes for two concurrent requests. Enforce it with a unique constraint and map
`23505` to a refusal rather than reasoning about interleavings. (Lesson borrowed from the
entitlement-claim work landing in this same tree, where exactly that check was the bug.)

Mirror every migration into `supabase/schema.sql` in the same change.

## B3. Generated, not hand-maintained — unchanged

`rule` is a small declarative predicate the award RPC evaluates — e.g.
`{"kind":"perfect_board","format":"grid"}` or `{"kind":"streak_at_least","days":7}`. One
evaluator, N rows. A new badge becomes a data push through `tools/ingest`, not an app release.

Award on write (the existing `submit_*` RPCs already run at the moment the evidence appears)
plus a backfill pass. Which brings us to the thing that has to change.

## B4. 🔴 The first shelf awards one badge, to one account

Run against production with the service role on 2026-08-26 — so RLS is not hiding rows:

| badge as first drafted | what production holds | awards |
|---|---|---|
| Perfect Grid | **zero** `grid` rows in `game_results` | 0 |
| Blitz PB tiers | `blitz_scores` doesn't exist | 0 |
| Streak 7 / 30 / 100 | longest streak ever recorded is **5** | 0 |
| First Gold | one player at 1,259 clears the 1,200 cut | **1** |
| First Platinum | top rating 1,259; Platinum starts at 1,400 | 0 |
| Ladder rung 10 / 20 / 30 | highest rung ever cleared is **5** | 0 |
| One-club loyalty | 2 of 15 profiles have set a favourite team at all | 0 |

The whole database is 43 game results across 6 distinct players and 15 profiles.

Every threshold in the first draft describes **mastery**. Mastery badges are the second shelf.
The exit criterion — "an existing account with real history logs in to a non-empty trophy case"
— is unreachable with them, and B3's own warning about the feature shipping dead is exactly what
would happen.

**Rebuild the first shelf from what actually fires in a player's first week:**

- **First rep, per format** — one Who Am I?, one Journeyman, one Keep4, one Grid, and so on.
  Seven formats, seven badges, and the completionist pull is "try the format you haven't
  touched", which is engagement work rather than a participation trophy.
- **Perfect anything, not perfect Grid** — `game_results.perfect` is already true on 9 rows
  across several formats. One evaluator, real awards on day one.
- **Streak 3 / 7 / 14**, not 7 / 30 / 100. The top of the live distribution is 5.
- **Set every threshold off the live distribution**, not off a round number. The
  `catalog-replay-harness` precedent applies directly — replay each predicate against real rows
  before writing the `unlock_definitions` row.

Keep for the second shelf, unchanged: Perfect Grid, ladder rungs, tier climbs, one-club loyalty.

Worth confirming rather than assuming: **The Grid has never been completed by a signed-in
account**, despite `GridGameView` calling `logSession(format: .grid, …)` on finish
(`BallIQ/Features/Grid/GridGameView.swift:438`). It is Pro-gated and there are 15 profiles
total, so low usage is the boring and likely explanation — but check before designing a badge
around it.

Flair v1 stands: avatar ring colour plus a short earned title under the username, both on
`ProfileShareCardView` — the surface that actually leaves the app, which puts M29 inside §9.3's
priority rather than beside it.

## B5. 🔴 Themes — bigger than scoped, and the blocker may not be real

The call to defer themes is right. The numbers supporting it were low. Counting every reference
to the 58 colour tokens declared in `Theme.swift`, excluding the declarations themselves:

| surface | as first scoped | measured 2026-08-26 |
|---|---|---|
| all colour tokens | 551 sites / 63 files | **1,241 sites / 82 files** |
| accent family only ("the cheap 80%") | "~6 tokens" | **412 sites / 64 files** |

Reproduce with:

```bash
awk '/^extension Color \{/,/^\}/' BallIQ/DesignSystem/Theme.swift \
  | grep -oE "static let [a-zA-Z0-9]+" | sed 's/static let //' | sort -u > /tmp/ct.txt
PAT=$(paste -sd'|' /tmp/ct.txt)
grep -rEo "(Color)?\.($PAT)\b" BallIQ --include="*.swift" | grep -v Theme.swift | wc -l
```

The accent-only subset was offered as the cheap option because it is "~6 tokens instead of 61."
Token count is not the cost — **call sites are**, and those six tokens are referenced 412 times
across 64 files, 78% of the files a full refactor would touch. It does not dodge the blast
radius.

**Before committing to either number, run one spike.** The first draft's stated blocker was that
`static let` resolves at type level, so there is no runtime seam. `Theme.swift` may already contradict that:
its own `Color.dynamic(light:dark:)` wraps `UIColor { traits in … }` — a closure UIKit calls at
*resolve* time, not declaration time. If that closure can read a mutable palette instead of only
the trait collection, a theme swap costs **zero call-site changes**.

Unverified: whether SwiftUI re-resolves those colours when the palette changes, or caches them
per trait collection. Do not assert it either way without evidence. The experiment is small —
render one view through `ImageRenderer` in a hosted test (the `ScoringGalleryTests` pattern),
mutate the palette, render again, compare pixels. Half a day against a six-week question, and it
should run *before* anyone signs up for 1,241 call sites.

## Sequencing

1. **M28** — Part A above. Self-contained, no schema.
2. **M29a** — `blitz_scores`, the award RPC, equipped-slot enforcement, and a first shelf
   re-derived per B4.
3. **M29b** — the `Color.dynamic` spike first; the theme work only if the spike says it's real.

Do not start B5's refactor and A4 in the same build — they touch the design-system surface from
opposite ends.
