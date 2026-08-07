# M21-1 — Get the full Swift test suite green again

**Agent type:** `balliq-swift-feature`
**Runs:** FIRST, alone. Every other M21 brief assumes a green baseline; do not dispatch
M21-2…6 until this one reports done.
**Repo:** `/Users/xanderevans/Documents/fantasy-app`

---

## Goal

`xcodebuild … test` exits `** TEST SUCCEEDED **` for the whole `BallIQTests` bundle.

Right now it exits `** TEST FAILED **`. **Nobody has identified which suite fails.** That
identification is the first and most important half of this task — do not skip to guessing at
fixes.

## Why this exists / what just landed

A feature called **Moments** was just added: post-onboarding prompts (claim a username, set a
favorite team, add a friend) that fire at earned moments and are governed by a pure decision
engine. The changed/added files are:

```
NEW  BallIQ/Features/Onboarding/Moments.swift          (Moment, MomentContext, MomentState, MomentEngine)
NEW  BallIQ/Features/Onboarding/MomentPresenter.swift  (@MainActor ObservableObject)
NEW  BallIQ/Features/Onboarding/MomentSheet.swift      (MomentSheet + MomentInlineCard + MomentCopy)
NEW  BallIQ/DesignSystem/SignInButtons.swift           (extracted shared provider sign-in)
NEW  BallIQTests/MomentEngineTests.swift               (30 tests, all passing)
MOD  BallIQ/BallIQApp.swift                            (+@StateObject MomentPresenter, +environmentObject)
MOD  BallIQ/ContentView.swift                          (+@EnvironmentObject MomentPresenter, +.task, +.sheet)
MOD  BallIQ/Features/Home/HomeView.swift               (+@EnvironmentObject MomentPresenter, inline card, onDismiss hooks)
MOD  BallIQ/RepositoryContainer.swift                  (+acceptedFriends, +didSyncProfile/isProfileLoaded)
MOD  BallIQ/Backend/AnalyticsClient.swift              (+momentShown/.momentAccepted/.momentCompleted)
MOD  BallIQ/DebugLaunch.swift                          (+forcedMoment / -screenshotMoment)
MOD  BallIQ/Features/Onboarding/ActivationFunnel.swift (+currentDayIndex, +PushPrimer enum)
MOD  BallIQ/Features/Onboarding/OnboardingView.swift   (auth block replaced by SignInButtons)
MOD  BallIQ/Features/Profile/ProfileView.swift         (auth block replaced by SignInButtons)
```

`** BUILD SUCCEEDED **` is confirmed. `MomentEngineTests` (30 tests) all pass. So the failure
is somewhere else in the bundle.

**It is NOT yet known whether the failure was caused by these changes or pre-dates them.**
Establishing that is part of the job. Do not assume either way.

## What has already been ruled out (don't re-do this)

- `MomentEngineTests` — all 30 pass.
- `AccountDeletionUITests`, `ActivationFunnelTests` — observed passing in the run's log.
- Every suite alphabetically from `ScoringKindTests` onward — observed passing. **The failure
  is alphabetically earlier than `ScoringKindTests`.**
- `LocalizationTests` — asserts only pre-existing catalog keys (`Home`, `KEEP`, `My Team`,
  `Search titles`…), none of which this work touched. Reading it is cheap; re-deriving that it
  is safe is not a good use of your time.
- No test constructs `ContentView`, `HomeView` or `RootView`, so the newly-required
  `MomentPresenter` `@EnvironmentObject` (a *runtime* crash when missing, not a compile error)
  has no test call site. `ProfileView(` **is** constructed in `AccountDeletionUITests`, and that
  suite passed.

## Step 1 — Identify the failure (do this before touching any code)

Run the suite and capture the result properly. Use your own DerivedData path so you don't
collide with anyone else:

```bash
cd /Users/xanderevans/Documents/fantasy-app
xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'platform=iOS Simulator,id=448665F0-289F-47A6-BB48-8EFC0FB58A58' \
  -derivedDataPath /tmp/build-agent-m21-1 \
  -resultBundlePath /tmp/m21-1.xcresult \
  test 2>&1 | tee /tmp/m21-1-test.log
```

Notes that will save you time:
- That simulator id is `BallIQ-Test-iPhone17` (iOS 26.5), already booted. `xcrun simctl list
  devices available` if it's gone; **do not** use `name=iPhone 15,OS=17.5` from the older docs —
  that runtime is not installed on this machine.
- The run takes ~8 minutes. Do not kill it — a partial run leaves a corrupt `.xcresult` with no
  `Info.plist`, which is exactly why the previous attempt couldn't be diagnosed after the fact.
- The log is extremely noisy (`CHHapticPattern` errors, `IOSurface` warnings — all benign and
  pre-existing). Filter, don't read it raw:

```bash
grep -E "Test Case '.*' failed|XCTAssert|error:|Test Suite '.*' failed" /tmp/m21-1-test.log | head -40
```

Or read the structured result:

```bash
xcrun xcresulttool get test-results tests --path /tmp/m21-1.xcresult
```

**Deliverable of this step:** the exact suite name, test-case name, assertion message, and file/
line. Write it down in your report verbatim. If the suite passes on this run — i.e. the failure
does not reproduce — say so plainly and stop; a flaky/environment failure is a completely
different (and much less urgent) problem than a real regression, and reporting "fixed" for
something that never reproduced would be worse than reporting "could not reproduce".

## Step 2 — Determine whether it's a regression

Once you have the failing test, decide whether these changes caused it. The cheapest honest way:

```bash
git stash push --include-untracked
# re-run ONLY the failing suite:
xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'platform=iOS Simulator,id=448665F0-289F-47A6-BB48-8EFC0FB58A58' \
  -derivedDataPath /tmp/build-agent-m21-1 \
  -only-testing:BallIQTests/<FailingSuiteName> test
git stash pop
```

⚠️ **`git stash pop` is mandatory and must succeed.** The working tree contains a whole
unreviewed feature and there is no commit to recover it from. Verify with `git status --short`
that all 16 files from the list above are back (5 untracked `??`, 11 modified `M`) before you do
anything else. If `stash pop` conflicts, STOP and report — do not try to resolve it yourself.

If stashing makes you nervous, the safe alternative is to reason from the failure itself: if the
assertion is in a file and about behavior that none of the 16 files above can reach, it
pre-dates this work.

## Step 3 — Fix

**If it is a regression from this work:** fix it at the cause, not by weakening the test. The
most likely shapes, given what changed:

- **`RepositoryContainer` construction** — `didSyncProfile`/`acceptedFriends` were added as
  `@Published private(set)`. A test that builds a container and asserts on published state, or
  one that counts `objectWillChange` emissions, could see new behavior.
- **`syncIfSignedIn` now sets `didSyncProfile = true` at the very end**, after
  `recomputeEntitlements()`. If a test drives that path and asserts on ordering or on a signed-out
  early return (which deliberately does **not** set the flag), check that.
- **`refreshFriendBadge` now also computes `acceptedFriends`** from the same `edges` array.
  `FriendsPartitionTests` / `FriendsLeaderboardTests` are the neighbours here.
- **`OnboardingView`/`ProfileView` lost their local `currentNonce` state and their
  `AuthenticationServices` import**, and their sign-in now routes through `SignInButtons`. A
  test that renders either view offscreen could be affected.
- **`PushPrimer.shouldOffer` replaced the inline condition in `HomeView.refreshPushPrimer`.**
  `HomeDailyLoopTests` is the neighbour.

**If it pre-dates this work:** fix it anyway if the fix is small, contained, and obviously
correct. If it is not — if it needs a design decision, or the fix would sprawl outside the
failing suite's own file — **do not fix it**. Report exactly what it is, that it pre-dates M21,
and what fixing it would involve. A pre-existing failure is the user's call to schedule, not
yours to absorb into this task.

## File ownership (absolute)

You own:
- `BallIQTests/**` — but **only** the failing suite's file, and only if the correct fix is
  genuinely in the test rather than in the source.
- **At most one** source file under `BallIQ/`, if and only if Step 1 identified it as the cause.

You do **not** own, and must not touch, anything in the M21 file list above unless your
diagnosis specifically implicates it. Do not "tidy" anything. Do not add tests beyond what is
needed to prove your fix. If you notice something else worth fixing, put it in your report.

## Definition of done

1. You can name the failing suite, test, and assertion — or state that it did not reproduce.
2. You have said, with evidence, whether it is an M21 regression or pre-existing.
3. Full suite exits `** TEST SUCCEEDED **` (or: the failure pre-dates M21, you correctly left
   it alone, and you say so — in which case done means "diagnosed and reported", not "green").
4. `git status --short` shows the 16 M21 files intact plus whatever you deliberately changed.
5. Report the test count before and after.

## Do not

- Do not `git commit`, `git push`, or `git checkout`/`git restore` anything.
- Do not install or launch the app on a simulator. Test destinations only. Screenshots belong to
  M21-3, and two agents fighting over a booted device is how that goes wrong.
- Do not delete or `XCTSkip` a failing test to make the suite green. That is not green.
