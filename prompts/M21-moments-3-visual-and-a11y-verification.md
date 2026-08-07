# M21-3 — Visual + VoiceOver verification of the three Moment surfaces

**Agent type:** `balliq-swift-feature`, **with an explicit exception**: this brief *does* install
and launch on simulators, which the agent definition normally forbids. You are the only M21 agent
allowed to. Devices are assigned below; stay on yours.
**Depends on:** M21-1 (green suite). Runs in parallel with M21-2, M21-4, M21-5.
**Repo:** `/Users/xanderevans/Documents/fantasy-app`

---

## Goal

Prove — with before/after screenshots, not assertions — that the three Moment surfaces render
correctly on the smallest iPhone and on iPad, in light and dark, with outlier content. Fix what
the screenshots show is wrong.

AGENTS.md §5 is the standard here: *"A green build proves the code compiles, not that it looks
right. When a shared component renders for multiple sports/kinds, check the one with the outlier
content, not just NFL."* This feature has never been rendered on a screen by anybody.

## What you are looking at

**Moments** are post-onboarding prompts, defined in `BallIQ/Features/Onboarding/Moments.swift`:

| Moment | Headline | Sticker tint | Destination |
|---|---|---|---|
| `claimUsername` | LOCK IN YOUR NAME | volt | `IdentityEditorSheet` (or sign-in first, if signed out) |
| `favoriteTeam(Sport)` | WHO DO YOU RIDE WITH? | that sport's `cardFill` | `TeamPicker` |
| `addFriend` | BETTER WITH A RIVAL | accent | `FriendsView` + a SHARE MY CARD secondary |

Two renderers, both in `BallIQ/Features/Onboarding/MomentSheet.swift`:
- `MomentSheet` — medium-detent sheet, presented from `ContentView`. This is show #1.
- `MomentInlineCard` — a card in Home's prompt slot. This is show #2.

Both build their words from one shared `MomentCopy` struct so they can't drift.

## ⚠️ The iPad trap — read this before you change any layout

`OnboardingView` carries a long doc comment recording a bisect from 2026-07-28. Summary:

> Using `ViewThatFits(in: .vertical)` to get "centered when it fits, scrolling when it doesn't"
> rendered a **ghost duplicate** of the step's secondary button — clipped, at the very top of the
> screen — on **iPad Air 11-inch only**, never on any iPhone, which is why it shipped. Replacing
> it with a bare `ScrollView` removed it; re-introducing the same layout via
> `GeometryReader { ScrollView { content.frame(minHeight: proxy.size.height) } }` brought it
> straight back. **The trigger is any layout-negotiating container, not `ViewThatFits` as such.**

`MomentSheet` is deliberately written as a bare `ScrollView` + `.scrollBounceBehavior(.basedOnSize)`
for this reason, and is deliberately **not** vertically centered. **Do not "fix" that.** If the
content looks high on iPad, that is the accepted trade — a visible duplicate button on a reviewed
build is worse. If you believe you have a centering approach that is safe, do not apply it;
describe it in your report.

## Devices

| Purpose | Simulator | UDID |
|---|---|---|
| Smallest iPhone | `Sprout-SE` | `20CA3EDA-AD16-4066-ABFB-48A91BB6FD65` |
| iPad (the ghost-button device class) | **you must create one** | see below |

`xcrun simctl list devices available` to confirm. All existing sims are iOS 26.5. There is no
iPad simulator on this machine; create the exact device class the bug was found on:

```bash
xcrun simctl list devicetypes | grep -i "iPad Air"
xcrun simctl create "M21-iPad-Air-11" \
  "com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M2" \
  "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
xcrun simctl boot "M21-iPad-Air-11"
```

(Adjust the devicetype identifier to whatever the first command actually prints.)

**Do not use** `BallIQ-Test-iPhone17` (`448665F0-…`) — M21-1 and M21-2 run their test suites on
it, and installing/launching underneath a running test is how you get a confusing failure that
isn't real.

**Quit Xcode before driving simulators.** Its auto-reinstall kills the app mid-session. This is
documented in `docs/BALLIQ_SPEC.md` §7 and it has bitten this repo before.

## How to reach each surface

The moments are unreachable from a cold install — they need a specific games-played count, a
streak, a sign-in state, and an unexpired 48h cooldown all at once. `DebugLaunch` has a hook that
bypasses every gate. It is already implemented; you do not need to add it.

```bash
BUILD=/tmp/build-agent-m21-3
xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
  -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath $BUILD build

APP=$(find $BUILD/Build/Products -name "BallIQ.app" -path "*iphonesimulator*" | head -1)
xcrun simctl install <UDID> "$APP"

# claim username
xcrun simctl launch <UDID> com.balliqfantasy.app -screenshotMoment claim_username -skipStoreKit
# favorite team (NBA by default)
xcrun simctl launch <UDID> com.balliqfantasy.app -screenshotMoment favorite_team -skipStoreKit
# favorite team, soccer — the 201-club outlier
xcrun simctl launch <UDID> com.balliqfantasy.app -screenshotMoment favorite_team -screenshotMomentSport soccer -skipStoreKit
# add friend
xcrun simctl launch <UDID> com.balliqfantasy.app -screenshotMoment add_friend -skipStoreKit

xcrun simctl io <UDID> screenshot /tmp/m21-3/<name>.png
```

- `-skipStoreKit` matters: without it, a simulator with no Apple ID raises the system
  "Sign in to Apple Account" sheet over every screenshot.
- `hasOnboarded` gates whether onboarding shows at all, and **`simctl uninstall` alone does not
  clear it** (cfprefsd caches the domain — use `xcrun simctl spawn <UDID> defaults delete
  com.balliqfantasy.app` as well). You generally want `hasOnboarded = true` here, i.e. an app
  that has been through onboarding once, so `ContentView` is on screen.
- The forced path deliberately does **not** record the show or write analytics
  (`present(…, record: false)`), so you can screenshot the same moment repeatedly.

Dark mode: `xcrun simctl ui <UDID> appearance dark` (and `light`).

## The matrix you must capture

For each of {`claim_username` signed-out, `claim_username` signed-in, `favorite_team` NBA,
`favorite_team` soccer, `add_friend`} × {light, dark} × {iPhone SE, iPad Air 11"}:

Every screenshot goes in `/tmp/m21-3/` with a name that says what it is
(`se-dark-favorite_team-soccer.png`). Reference them by filename in your report.

### What specifically to check

1. **iPad: no ghost duplicate** of "Not now" or "SHARE MY CARD" at the top of the sheet. This is
   the single most important check in this brief.
2. **iPhone SE: nothing clipped.** The SE is the shortest screen. `claim_username` **signed out**
   is the tallest variant — it renders `SignInButtons` (Apple + possibly Google, each 52pt) *plus*
   the sticker, headline, body and "Not now". Confirm the primary action is reachable at the
   `.medium` detent, and that dragging to `.large` works.
3. **`add_friend` is the other tall one** — it has a primary CTA *and* a SHARE MY CARD secondary
   *and* "Not now".
4. **Headline never truncates to an ellipsis.** `.display1` with `lineLimit(2)` and
   `minimumScaleFactor(0.6)`. "WHO DO YOU RIDE WITH?" is the longest.
5. **Body copy is not clipped** — it's `.fixedSize(horizontal: false, vertical: true)`, so it
   should wrap, not truncate. The longest string is `favoriteTeam`'s, which interpolates a sport
   name; check soccer (longest `displayName` among team sports).
6. **Sticker contrast in both themes.** The tint is `sport.cardFill` with `sport.onCardFill` on
   top for `favoriteTeam` — check all five sports resolve to a legible pair, especially in dark.
   Sports: `nfl`, `nba`, `baseball`, `soccer` (tennis is excluded by design — no clubs).
7. **The destinations open and come back.** Tap the CTA on each: `IdentityEditorSheet`,
   `TeamPicker` (soccer's is the 201-club searchable one — confirm it's usable as a sheet over a
   sheet), `FriendsView`. Confirm dismissing returns you to a sane state, not a stuck sheet.
8. **`MomentInlineCard`** — the show-#2 renderer. It is *not* reachable via `-screenshotMoment`
   (the forced path always lands on `.sheet` because `showCount` is 0). Capture it by rendering
   it directly in a gallery test instead — see below.

## The inline card: render it with a gallery test

This repo's established answer to "a view state a single screenshot can't reach" is a gallery
test that renders the view through a real window and writes a PNG to tmp. Copy the pattern from
`BallIQTests/ShareGalleryTests.swift` or `GridBoardGalleryTests.swift` (both print a
`<NAME>_GALLERY:` line with the path).

Note the constraint those files document: `ImageRenderer` cannot lay out a `NavigationStack`
offscreen ("no interface idiom"), so they snapshot through a real `UIWindow` — hosted tests run
inside the live app process, which has one. `MomentInlineCard` has no `NavigationStack`, so plain
`ImageRenderer` may work; if it doesn't, use the window approach.

Render all three moments as inline cards, light and dark. `MomentInlineCard` takes
`(moment:context:onTap:onDismiss:)` — pass a `MomentContext` with realistic numbers
(`gamesPlayed: 12`, `gamesBySport: [.nba: 7]`, `streak: 9`) so the copy reads like production
rather than "You've played 0".

## VoiceOver

Currently only the sticker is handled (`.accessibilityHidden(true)`). This repo did a VoiceOver
pass in M14 on `Keep4CardView`/`WhoAmIGameView`/`DailyGameCard` — match that bar:

- The sheet should read as headline → detail → actions, in that order, without the decorative
  sticker announcing itself.
- `MomentInlineCard`'s dismiss button already has `.accessibilityLabel("Dismiss")`. Verify the
  card's own content combines sensibly rather than reading as four disconnected fragments —
  `.accessibilityElement(children: .combine)` on the text block is the idiom used elsewhere in
  this codebase (see `OnboardingView.ruleRow`).
- The CTA must be reachable and its label must say what it does.

Verify with the Accessibility Inspector or `xcrun simctl spawn <UDID> notifyutil -s
com.apple.SpeakThis` — or, if neither is workable in your environment, at minimum read the view
code against the M14 examples and state in your report that you verified by reading rather than
by running. Do not claim you ran VoiceOver if you did not.

## File ownership (absolute)

You own exactly:
- `BallIQ/Features/Onboarding/MomentSheet.swift` (contains `MomentCopy`, `MomentSheet`,
  `MomentInlineCard`)
- `BallIQTests/MomentGalleryTests.swift` (new file — create it)

**Do not touch** `Moments.swift` or `MomentPresenter.swift` — M21-2 owns those and is editing
them concurrently. **Do not touch** `Localizable.xcstrings` — M21-4 owns it. If you change any
user-facing string in `MomentCopy`, say so **prominently** in your report, because M21-4 is
localizing those exact strings and needs to know.

## Definition of done

1. Every cell of the matrix captured, saved under `/tmp/m21-3/`, referenced by name in the report.
2. iPad ghost-button explicitly confirmed absent (or found — in which case fix it *without*
   reintroducing a layout-negotiating container, and say what you did).
3. Inline card rendered for all three moments, both themes, via the gallery test.
4. Every layout defect found is either fixed and re-screenshotted (before *and* after), or
   reported with a screenshot if the fix is out of your ownership.
5. Build + full suite green:
   ```bash
   xcodebuild -project BallIQ.xcodeproj -scheme BallIQ \
     -destination 'platform=iOS Simulator,id=20CA3EDA-AD16-4066-ABFB-48A91BB6FD65' \
     -derivedDataPath /tmp/build-agent-m21-3 test
   ```

## Do not

- Do not use `BallIQ-Test-iPhone17` — other agents are testing on it.
- Do not reintroduce `ViewThatFits` or `GeometryReader` into these layouts.
- Do not change copy purely because you prefer different words. The numbers in the copy
  ("You've played 5") are the whole reason these prompts land; keep them.
- Do not `git commit` or `git push`.
