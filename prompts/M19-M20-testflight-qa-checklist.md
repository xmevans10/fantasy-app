# M19/M20 TestFlight QA checklist — signed-in social flows (human pass)

Written 2026-07-12. The server side is already live-verified (16/16 including RLS
negatives, push chain insert → trigger → edge function → `{"sent":1}`); this pass covers
the parts that genuinely need **two real signed-in humans on TestFlight builds**: the
signed-in UI, cross-device state, and real APNs delivery to physical devices.

## Prerequisites

- [ ] Two physical iPhones (pushes don't arrive in the simulator), both on the current
      TestFlight build.
- [ ] Two distinct Apple/sign-in accounts — call them **A** and **B** below.
- [ ] Notification permission **granted** on both devices when prompted.
- [ ] Neither account has previously claimed a username or friended the other (if they
      have, remove the friendship and note it — the onboarding-claim steps below then
      only apply to whichever account is fresh).

Record ✅/❌ per line; anything ❌ gets a one-line note of what actually happened.

## 1. Onboarding username claim (fresh account) — M20

On a device where the account has never signed in:

- [ ] After sign-in, the username-claim sheet appears (IdentityEditorSheet), and is
      **skippable**.
- [ ] Validation hints fire inline, no network round trip: `ab` → "At least 3
      characters."; `1abc` → "Must start with a letter."; `abc!` → "Letters, numbers,
      and underscores only."; 21+ chars → "20 characters or fewer."
- [ ] `  MixedCase_10  ` is accepted and saved as `mixedcase_10` (trimmed + lowercased).
- [ ] Claiming a username the *other* account already holds fails with a clear
      uniqueness error (server-enforced), not a silent success or crash.
- [ ] Skip path: dismissing the sheet lands you in the app; Profile still offers the
      claim later.

## 2. Profile identity + share card — M19

- [ ] Profile shows the claimed username; editing it re-runs the same validation.
- [ ] Share card (ProfileShareCardView) renders the identity correctly and the share
      sheet actually presents.

## 3. Friend request + push — M19/M20 (the core loop)

1. Device A: Friends hub → send a request to B **by username**.
   - [ ] Typo'd username → "not found" style error, not a crash.
   - [ ] Sending to your own username is rejected (`cannotFriendSelf`).
   - [ ] After sending, A shows B as **outgoing pending**.
2. Device B (app **backgrounded or killed**):
   - [ ] A real APNs push arrives for the friend request within ~a minute.
   - [ ] Tapping it opens the app (note where it lands).
   - [ ] In-app, B shows A as **incoming pending** with accept/decline.
3. Duplicate-request guard:
   - [ ] A sending a second request to B while pending is rejected (`alreadyLinked`).
4. Push toggle (M20 `notification_settings.friend_request`):
   - [ ] B: Profile → turn the friend-request toggle **off**. From a third state (or
         after removing + re-requesting, see §5), a new request from A produces **no**
         push. Turn it back on afterwards.

## 4. Accept → friends everywhere

Device B accepts A's request:

- [ ] Both devices now list each other as friends (pull to refresh / relaunch as needed).
- [ ] Tapping the friend row opens their **public profile** (PublicProfileView) with
      username, avatar, and per-sport ratings.
- [ ] Usernames elsewhere are tappable into the same public profile: check one each in
      **Leagues**, **Community**, and **Versus**.

## 5. FRIENDS leaderboard scope on Leagues — M20

- [ ] Leagues shows a LEAGUE/FRIENDS scope switcher; FRIENDS lists **you + accepted
      friends only** (so exactly A and B here), ranked by per-sport rating.
- [ ] Sport chips default to *your* best sport (the one with your highest rating).
- [ ] Switching sport chips reorders/re-scores correctly against what each account's
      Profile shows for that sport.
- [ ] Tapping a row pushes the public profile.
- [ ] Decline path (needs a fresh pair state — do before re-accepting if you removed
      the friendship): declining a request removes the pending state on both sides and
      does NOT create a friendship.

## 6. Remove friend

- [ ] A removes B: both sides drop the friend row (refresh/relaunch as needed), and B
      disappears from A's FRIENDS leaderboard scope.
- [ ] Re-requesting after removal works (no stale `alreadyLinked`).

## 7. Versus challenge push — M20 trigger wiring

- [ ] With A and B friends again, A challenges B in Versus; B (backgrounded) receives
      the versus-challenge push.

## Reporting

Paste the checked list back with per-line ✅/❌ and notes. Anything ❌ becomes a Tier 2
bug with repro steps already written (the failing line is the repro).
