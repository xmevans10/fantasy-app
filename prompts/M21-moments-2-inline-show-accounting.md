# M21-2 — Fix inline-moment show accounting (a moment can be burned unseen)

**Agent type:** `balliq-swift-feature`
**Depends on:** M21-1 (green suite). Runs in parallel with M21-3, M21-4, M21-5.
**Repo:** `/Users/xanderevans/Documents/fantasy-app`

---

## Goal

A moment must only be counted as "shown" when it was actually put in front of the player. Today
the second ask can be consumed invisibly, and a `moment_shown` analytics row can be written for
something nobody saw.

## Background — read this before you read any code

**Moments** are post-onboarding prompts. Three exist: `claimUsername`, `favoriteTeam(Sport)`,
`addFriend`. The rules live in `BallIQ/Features/Onboarding/Moments.swift`:

- A moment is retired after `MomentState.maxShows` (**2**) shows, ever, whatever the player did.
- At most one moment per app session; at least 48h between any two.
- Show **#1** renders as a sheet (`MomentSheet`, presented from `ContentView`).
- Show **#2** de-escalates to a card in Home's inline prompt slot (`MomentInlineCard`), the same
  slot `pushPrimerCard` occupies.

## The bug, precisely

`MomentPresenter.present(_:container:trigger:context:record:)` in
`BallIQ/Features/Onboarding/MomentPresenter.swift`:

```swift
style = state.showCount(moment) == 0 ? .sheet : .inline
self.context = context
pending = moment
guard record else { return }
shownThisSession = true
state.markShown(moment)                                             // ← burns the show
container.track(.momentShown, context.properties(...))              // ← logs the impression
```

`markShown` and the `moment_shown` event both fire **at arm time**, before anything renders.

For `style == .sheet` that is fine: `ContentView` presents it immediately and unconditionally, so
arming and appearing are the same instant for practical purposes.

For `style == .inline` it is wrong. The card renders only if **both**:
1. the player is on the **Home** tab (`selectedTab == 0`) — `MomentInlineCard` is rendered inside
   `HomeView`'s scroll content and nowhere else; and
2. Home is not already showing `pushPrimerCard`, which wins the slot via the `else if` in
   `HomeView.body`.

Neither is guaranteed. `evaluate(trigger:)` fires from `ContentView`'s `scenePhase` watcher and
its `.task` — a player who foregrounds the app on the **Versus** tab arms an inline moment, never
sees it, and it is gone forever. Since `maxShows` is 2 and show #1 already happened, that means
the player's *final* ask is silently spent, and the warehouse records an impression that never
occurred (inflating `moment_shown` and deflating the apparent `shown → accepted` rate).

## What to change

Split "armed" from "shown". Arming stays where it is; the counting and the analytics write move
to the moment the surface actually appears.

**Required behavior:**

1. `MomentState.markShown` and the `.momentShown` track call must happen **when the surface
   appears**, not when the moment is armed.
   - Sheet: `MomentSheet` appearing (an `.onAppear` or `.task` on it) is the trigger.
   - Inline: `MomentInlineCard` appearing on Home is the trigger.
2. It must fire **exactly once** per armed moment, never twice. A `MomentSheet` `.onAppear` can
   re-fire on some transitions — this repo has been bitten by exactly that before, twice: see the
   `trackedStep` guard in `OnboardingView.body`'s `.task(id:)`, and the `recordedOpen` guard in
   `RootView.openApp()`, both added after **duplicate rows were found in the production `events`
   table**. Guard this the same way, with a flag on the presenter, not on the view.
3. `shownThisSession` must still be set at **arm** time, not at appear time. It exists to stop a
   second moment being armed in the same session; deferring it would let a second one arm while
   the first is still on screen.
4. If an inline moment is armed and never appears, the player must be able to get it again on a
   later trigger — i.e. its `showCount` must be unchanged.
5. Do not change the sheet's behavior in any observable way. Its arm-to-appear gap is ~one frame.

**Suggested shape** (you may choose differently if you justify it in your report): give
`MomentPresenter` a `func markShown(container:)` that is idempotent per armed moment (guard on a
private `hasRecordedCurrent` flag reset in `present`/`clear`), and call it from the surfaces.

## A second, related decision you must make

Consider whether an armed-but-never-seen inline moment should stay `pending` indefinitely. It
currently blocks any other moment arming for the rest of the session (`guard pending == nil`).
Decide whether to leave it pending or clear it, state your choice and your reasoning in your
report. Either is defensible; silently not thinking about it is not.

## File ownership (absolute)

You own exactly:
- `BallIQ/Features/Onboarding/Moments.swift`
- `BallIQ/Features/Onboarding/MomentPresenter.swift`
- `BallIQTests/MomentEngineTests.swift`

You may add an `.onAppear`/`.task` **call** in `MomentSheet.swift` and `HomeView.swift` **only if
unavoidable** — another agent (M21-3) owns `MomentSheet.swift` and may be editing it right now.
**Strongly prefer** a design where the hook is a single line you can describe precisely in your
report for the orchestrator to apply, rather than editing those files yourself. If you must
touch them, keep it to the minimum possible lines and say so loudly in your report.

## Tests to add (in `MomentEngineTests.swift`)

Existing file has 30 passing tests and a `MomentState(defaults:)` injection pattern — copy it
(`UserDefaults(suiteName:)` in `setUp`, `removePersistentDomain` in both `setUp` and `tearDown`).
These tests are **hosted** (they run inside the real BallIQ.app process), so writing `moments.*`
through `.standard` corrupts the real app's state. Do not.

Add coverage for:
- Arming an inline moment does **not** increment `showCount`.
- After the surface reports appearing, `showCount` **is** incremented, exactly once.
- Reporting appearance twice for the same armed moment increments only once.
- A moment armed inline, never shown, is still eligible on a later evaluation (unchanged
  `showCount`, and not retired).
- `shownThisSession` still blocks a second arm in the same session even when the first was never
  shown.

`MomentPresenter` is `@MainActor` — mark the new test methods `@MainActor` and construct it with
the injected `MomentState`. It needs a `RepositoryContainer` for the `track` call; build one with
`RepositoryContainer.make(client: nil)` (local-only, so `analytics` is nil and tracking is a
silent no-op — which is exactly what you want in a unit test).

## Verification (mandatory)

```bash
cd /Users/xanderevans/Documents/fantasy-app
xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/build-agent-m21-2 build

xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'platform=iOS Simulator,id=448665F0-289F-47A6-BB48-8EFC0FB58A58' \
  -derivedDataPath /tmp/build-agent-m21-2 test 2>&1 | tail -30
```

Full suite must be green — not just your file. Report the test count before and after.

## Do not

- Do not install or launch on a simulator. Test destinations only.
- Do not change `maxShows`, the 48h `cooldown`, the threshold constants, or the priority order.
  Those are product decisions already made and unit-tested; this task is about *accounting*.
- Do not add a `moment_dismissed` event. Dismissal is deliberately derived as
  `moment_shown − moment_accepted` — see the comment in `AnalyticsClient.swift` and the note in
  `docs/ANALYTICS.md`.
- Do not `git commit` or `git push`.
