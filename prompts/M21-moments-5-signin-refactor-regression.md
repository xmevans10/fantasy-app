# M21-5 — Prove the SignInButtons extraction is behavior-preserving (App Review sensitive)

**Agent type:** `balliq-swift-feature`
**Depends on:** M21-1 (green suite). Runs in parallel with M21-2, M21-3, M21-4.
**Repo:** `/Users/xanderevans/Documents/fantasy-app`

---

## Goal

The provider sign-in block was extracted into one shared component and two shipped screens were
migrated onto it. Prove that migration changed nothing a user or an App Review tester can see —
except the one behavior it deliberately fixed.

**This is the highest-risk change in M21.** Sign in with Apple is the thing this app has been
scrutinised on: v1.3 was **rejected twice**, and `ProfileView` also hosts the Guideline 5.1.1(v)
account-deletion flow that Apple asks for a screen recording of. A regression here is a rejected
build, not a bug report.

## What changed and why

There were **two** hand-rolled copies of the same provider sign-in block, and they had drifted:

- `OnboardingView.authButtons` — Apple button (52pt) + Google button, errors shown as an inline
  `Text`, and on success it called `finishOrClaimUsername()`.
- `ProfileView.accountCard` — Apple button (50pt) + Google button, errors raised as an `.alert`.
  Its **Google** path had been explicitly fixed to surface failures, carrying this comment:

  > *Was `try?`, which is why a rejected token looked like the button did nothing at all: the
  > flow completed, GoTrue 400'd, and the error went straight in the bin. A sign-in that fails
  > has to say so.*

  …while its **Apple** path, six lines above, still read:

  ```swift
  try? await container.auth.signInWithApple(…)   // ← swallowed everything
  ```

A third copy was about to be written for `MomentSheet` (the `claimUsername` moment needs sign-in
when the player is signed out). Per AGENTS.md §4 the block was extracted instead:
`BallIQ/DesignSystem/SignInButtons.swift`, parameterised by `surface` (analytics), `height`
(52 for Onboarding, 50 for Profile — carried purely so the extraction doesn't restyle two shipped
screens), `onError`, and `onSignedIn`. All three sites now use it.

**The one intended behavior change:** Profile's Apple path no longer swallows failures. It now
raises the same "Sign-in failed" alert its Google path already did.

## What you must verify

### 1. Pixel parity on the two migrated screens

Screenshot **before and after** — AGENTS.md §5 is explicit that a green build proves nothing
visual. You get "before" by stashing:

```bash
cd /Users/xanderevans/Documents/fantasy-app
git stash push --include-untracked      # → pre-M21 tree
# build, install, screenshot  → /tmp/m21-5/before-*.png
git stash pop                            # → M21 tree
# build, install, screenshot  → /tmp/m21-5/after-*.png
```

⚠️ **`git stash pop` is mandatory and must succeed.** The tree holds an entire unreviewed feature
with **no commit to recover it from**. After popping, confirm with `git status --short` that you
see 5 untracked (`??`) and 11 modified (`M`) files. If the pop conflicts, **STOP and report** —
do not attempt to resolve it.

Capture, signed out, in light and dark:
- **Onboarding, account step** — `-screenshotOnboardingStep account`. Note this only has an
  effect on a genuinely fresh install: `hasOnboarded` gates whether onboarding renders at all,
  and **`simctl uninstall` alone does not clear it** (cfprefsd caches the domain). Also run
  `xcrun simctl spawn <UDID> defaults delete com.balliqfantasy.app`.
- **Profile, signed out** — `-screenshotProfile`, scrolled to the ACCOUNT card at the bottom.

Compare before/after for: button heights (52 vs 50 — they differ *between* screens by design and
must not have converged), corner radius, vertical spacing between the two buttons, the Google
button's `GoogleGMark` size (Onboarding was 18pt, Profile 17pt — the shared component uses 17;
**flag it if Onboarding's mark visibly changed**, and say whether you think it matters), and
where the "Not now" / surrounding copy sits relative to the buttons.

Device: `Sprout-ProMax` (`36BBF35E-B7CF-4A0B-AEEE-10C60692AAE6`). **Do not** use
`BallIQ-Test-iPhone17` (M21-1/M21-2 are running test suites on it) or `Sprout-SE` (M21-3 owns it).
**Quit Xcode before driving simulators** — its auto-reinstall kills the app mid-session.

### 2. The Google button's conditional rendering

`GoogleSignIn.isConfigured` gates whether the Google button renders at all. Read
`BallIQ/Backend/GoogleSignIn.swift` and confirm the shared component's gate is equivalent to what
each screen did before. The original comments explain the stakes: *"a sign-in button that always
errors is worse than one fewer option, and a reviewer tapping it would be looking at a Guideline
2.1 bug."* If `isConfigured` is false in this build, say so — then the button is absent in your
screenshots and that is correct, not a missing element.

### 3. The analytics `surface` values are unchanged

`sign_in_completed.properties->>'surface'` is a stable schema value that existing warehouse
queries group by (`docs/ANALYTICS.md`). Confirm by reading:
- Onboarding still reports `"onboarding"`
- Profile still reports `"profile"`
- The new moment site reports `"moment_claim_username"` (new value — that's fine, it's a new
  surface, but confirm it doesn't collide with an existing one; grep `docs/ANALYTICS.md`)

### 4. Ordering: sync before callback

`SignInButtons.finishSignIn` does `await container.syncIfSignedIn()` **before** calling
`onSignedIn()`. This ordering is load-bearing: `OnboardingView.finishOrClaimUsername()` reads
`container.identity.username` to decide whether to show `IdentityEditorSheet`, and a nil-because-
not-synced-yet identity would prompt a returning user to claim a name they already own. Confirm
by reading that the ordering holds on both the Apple and Google paths.

### 5. Cancellation is still silent

A user who backs out of Apple's sheet, or dismisses the Google OAuth browser, must see **no**
error. In the shared component: the Apple path's `case .failure` breaks without calling
`onError`, and the Google path checks `if !(error is CancellationError)`. Verify both by reading,
and — if you can trigger it in the simulator — by tapping the Apple button and cancelling.
Report which of those two you actually did.

### 6. Account deletion still works

`AccountDeletionUITests` covers this and passes. Run it explicitly anyway and say so — the
deletion button lives in the same `accountCard` you edited, inside the `if auth.isSignedIn`
branch, and the surrounding view has a comment explaining that the confirmation alert is attached
to the *whole screen* rather than the button precisely because deletion tears the button out of
the hierarchy. Confirm that structure is untouched.

```bash
xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'platform=iOS Simulator,id=36BBF35E-B7CF-4A0B-AEEE-10C60692AAE6' \
  -derivedDataPath /tmp/build-agent-m21-5 \
  -only-testing:BallIQTests/AccountDeletionUITests test
```

## File ownership (absolute)

You own exactly:
- `BallIQ/DesignSystem/SignInButtons.swift`
- `BallIQ/Features/Onboarding/OnboardingView.swift`
- `BallIQ/Features/Profile/ProfileView.swift`
- `BallIQTests/SignInButtonsTests.swift` (new — create if you add tests)

**Do not touch** `MomentSheet.swift` (M21-3 owns it) even though it is the third `SignInButtons`
call site. If the shared component's API needs to change, describe the required call-site edit in
your report for the orchestrator to apply.

## If you find a real regression

Fix it in the shared component, preserving both screens' existing appearance — that is what the
`height` parameter exists for; add another parameter if you genuinely need one. **Do not** "fix"
it by reverting a screen to its own private copy: two drifting copies is the bug this change
exists to remove, and it had already produced a real swallowed-error defect.

## Definition of done

1. Before/after screenshots for both screens, both themes, saved under `/tmp/m21-5/` and
   referenced by filename in your report.
2. An explicit statement, per screen, of whether anything is visually different — and if so,
   whether it is intentional (the 17pt vs 18pt Google mark) or a regression you fixed.
3. Items 2–6 above each answered, with a clear split between **what you ran** and **what you
   verified by reading**. Do not blur those two.
4. `git status --short` shows all 16 M21 files intact.
5. Full suite green:
   ```bash
   xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
     -destination 'platform=iOS Simulator,id=36BBF35E-B7CF-4A0B-AEEE-10C60692AAE6' \
     -derivedDataPath /tmp/build-agent-m21-5 test
   ```

## Do not

- Do not attempt a real Apple or Google sign-in with the user's credentials. You cannot, and you
  must not try. Verify the *presentation* and the *code paths*; the live round trip belongs to
  M21-6, which the user drives themselves.
- Do not `git commit`, `git push`, or leave anything stashed.
