# TestFlight QA — M19/M20 signed-in social flows (two-account human pass)

Agent-prepped 2026-07-14. Needs **two real Apple accounts on two devices** (or one device +
one simulator signed into a second account) running the same TestFlight build. Call them
**A** and **B**. Everything below is pass/fail observable — no judgment calls. Estimated
time: ~25 min.

Before starting: both devices on the same build number (check Profile → version footer),
both signed OUT of any prior test state (delete + reinstall the TestFlight app for a clean
`hasOnboarded` slate — note simulator `defaults delete` doesn't apply to real devices;
reinstall is the reliable reset).

## 1. Onboarding + username claim (M20)

- [ ] A: fresh install → onboarding → Sign in with Apple as a **brand-new** account →
      the one-shot username-claim sheet appears right after sign-in (not buried in Profile).
- [ ] A: claim a username (e.g. `qa-alpha`). Sheet dismisses → lands on Home.
- [ ] B: fresh install → sign in as a brand-new account → claim sheet appears → **Cancel**
      instead of saving. Confirm it still lands on Home (claiming is skippable) and the
      claim sheet does NOT reappear on next launch.
- [ ] B: Profile → set username there instead (`qa-bravo`). Both usernames visible on the
      respective Profile screens.
- [ ] A: sign out, sign back in → NO claim sheet (existing profile, one-shot only).

## 2. Friends graph (M19)

- [ ] A: Friends → send a request to `qa-bravo` (search by username).
- [ ] B: Friends shows the incoming request; the Profile/Friends entry-point badge count
      is 1 WITHOUT killing the app (foreground refresh is enough).
- [ ] B: accept. Both sides now list each other as friends.
- [ ] A: remove friend (destructive button) → gone on A. B: after foregrounding, gone on B.
- [ ] Re-add (A→B request, B accepts) to set up the leaderboard checks below.
- [ ] Negative: A sends a request to a nonexistent username → clear error, no crash.

## 3. FRIENDS leaderboard scope (M20)

- [ ] Both: play today's daily Keep4 (scores can differ, that's the point).
- [ ] A: Leagues → toggle LEAGUE / FRIENDS. FRIENDS scope shows exactly: A + B (the friend
      graph), ranked, with usernames + avatars — no strangers from the cohort.
- [ ] B: same check from B's side.
- [ ] A: remove B as friend → FRIENDS board back to just A (after refresh/foreground).

## 4. Versus 1v1 (M19, badge is the push stopgap)

- [ ] A: Versus → challenge `qa-bravo` (pick any sport).
- [ ] B: WITHOUT killing the app, foreground it → Versus tab badge increments (this is the
      explicit stopgap while APNs `versus_challenge` pushes are stubbed).
- [ ] B: play the challenge. A: after foregrounding, sees B's score + outcome.
- [ ] Timeout path (optional, slow): leave a second challenge unplayed ≥ the timeout window
      (versus-timeout cron runs every 15 min) → it resolves/expires on its own.

## 5. Daily Draft + arcade leaderboards (shipped 07-13/07-14 — signed-in halves)

- [ ] A + B: play today's Daily Draft (same sport-of-the-day, same round-1 spin — glance at
      round 1 on both devices to confirm the shared seed).
- [ ] Result banner → board sheet: both accounts on the board with correct ranks; replaying
      does NOT change the official score (first-write-wins).
- [ ] A: finish an Over/Under run → result screen → Leaderboard row → A appears on this
      week's board for that sport. B: same board shows both.
- [ ] A: finish today's Grid (first, ranked run) → Grid result → Leaderboard → both on the
      weekly Grid board. Replay Grid → replay score does NOT appear (ranked-run-only).
- [ ] Signed-out spot-check: sign out on one device, play Over/Under → result screen still
      works, board shows the signed-in-only empty-state message, no crash, no phantom row.

## 6. Cross-device sync sanity (M2 regression guard)

- [ ] A: note rating/XP/streak on device → sign in as A on the OTHER device → same numbers
      (server-authoritative progress, max-merge rating).

## Known-blocked (do NOT count as failures)

- No actual push notifications arrive anywhere — APNs key material not yet configured
  (edge functions run in `[apns:stub]` log-only mode) and the app lacks the
  `aps-environment` entitlement until the App ID capability is enabled.
- Paid/Pro purchase flows — Paid Applications agreement + ASC IAP products still pending.

## Where to report

File anything that fails as a line in this doc's PR/commit, or paste into the next agent
session — include device, account (A/B), and the step number.
