# M21-6 — Live end-to-end: do the moment events actually reach production?

**Agent type:** `general-purpose` (needs Bash + Supabase access; the `balliq-swift-feature` agent
is deliberately forbidden from launching the app, and this brief is nothing but launching it)
**Depends on:** M21-1 through M21-5 all reporting done. **This runs LAST, alone.**
**Repo:** `/Users/xanderevans/Documents/fantasy-app`

---

## Goal

Prove the Moments funnel works against the real backend: a real account, a real session, real
rows in the production `events` table. Not a unit test — the actual thing.

## Why this brief exists, in one paragraph

This repo has been burned specifically by trusting instrumentation it never read back. From
`AnalyticsClient.swift`: `game_results` *"held 0 rows for the whole of build 22's life with no
way to tell 'nobody played signed in' apart from 'every push is 400ing'."* From the spec: a
duplicate-`app_opened` bug *"was caught and fixed by reading those rows rather than trusting the
call site"* — a `.task` on a `Group` fired on every child during a transition and silently halved
the measured activation rate. Analytics writes here are **fire-and-forget and swallow every
failure by design** (`try? await client.perform(req)`), so a broken write is completely silent.
Three new events just landed. Read them back.

## Backend facts

- Live project: **`nhccgufqwndtoasdbkhc`** ("ballknowledge").
- ⚠️ `list_projects` also returns a decoy, **`pyprjebfwqfdnfeliigo`** ("xmevans10's Project").
  That is **NOT** this app's backend. Never query or write to it.
- Service-role credentials for read-only SQL are in gitignored `tools/ingest/.env`
  (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`). Reference them as `$VARS` after `source`-ing —
  never paste the literal value into a command, so it can't land in shell history.
- `events` rows are `{event_name, properties jsonb, user_id, created_at}`. Guests write
  `user_id = null`; the RLS policy accepts both.

## The three events under test

| Event | Fired from | Properties |
|---|---|---|
| `moment_shown` | `MomentPresenter` | `moment`, `trigger` (`foreground`/`post_game`), `games_played`, `day_index`, `sport` (favorite-team only) |
| `moment_accepted` | `MomentSheet.accept()` — the CTA tap | `moment` |
| `moment_completed` | goal reached (username saved / team picked / friend added) | `moment` |

There is deliberately **no** `moment_dismissed` — it's derived as `shown − accepted`.

⚠️ **M21-2 may have moved when `moment_shown` fires** (from arm-time to appear-time) and may have
added a de-duplication guard. Read its report first and test the behavior that is actually in the
tree, not what this table describes.

## Setup

Use `Sprout-ProMax` (`36BBF35E-B7CF-4A0B-AEEE-10C60692AAE6`). **Quit Xcode first** — its
auto-reinstall kills the app mid-session.

Start genuinely clean. `simctl uninstall` alone is **not** enough — cfprefsd caches the defaults
domain, so `hasOnboarded` and every `activation.*` / `moments.*` key survive:

```bash
xcrun simctl uninstall <UDID> com.balliqfantasy.app
xcrun simctl spawn <UDID> defaults delete com.balliqfantasy.app
```

Build and install with your own DerivedData (`/tmp/build-agent-m21-6`).

**Do not use `-screenshotMoment`.** That forced path deliberately passes `record: false` — it
writes no analytics and burns no show, which is exactly wrong for this brief. You need the real
engine to fire on its own.

## Reaching the moments for real

This is the hard part; budget for it. The thresholds in `MomentEngine` are:

- `claimUsername` — 5 completed games **or** `day_index >= 1`
- `favoriteTeam` — 3 completed games in one team sport
- `addFriend` — 7-day streak **or** 10 completed games

Plus the global gates: `hasOnboarded`, `firstGameCompleted`, **one per session**, **48h between
any two**, and `isProfileLoaded` (the container must have finished syncing).

Two levers make this tractable:

1. **`day_index >= 1`** is far cheaper than five games. `ActivationState` stores the install
   birthday under the `activation.firstOpenAt` UserDefaults key. Setting it a day into the past
   (via `xcrun simctl spawn <UDID> defaults write com.balliqfantasy.app …`) makes the next launch
   read as a next-day return. Confirm the key name against `ActivationFunnel.swift` before you
   rely on it, and confirm the *stored type* — it's written as a `Date`, so a naive string write
   will read back as nil and silently give you day 0.
2. **The 48h cooldown** (`moments.lastShownAt`) is what stops you seeing all three in one sitting.
   Deleting that key between runs is the intended way to test each moment in isolation. Note that
   `moments.shown.<id>` is *also* persisted, and 2 shows retires a moment permanently — so if you
   need a third attempt at one, clear that key too.

Also useful: `-skipStoreKit` avoids the "Sign in to Apple Account" system sheet on a simulator
with no Apple ID.

Play real games to move the counters — the daily K4C4 from Home is the fastest loop. `-screenshotGame`
opens today's daily and `-screenshotResult` plays it to the result screen, which is the cheapest
way to increment a completed game without tapping through a board.

## What to verify

### A. The happy path, per moment

For each of the three: reach it legitimately, screenshot the sheet, tap the CTA, complete the
goal, and confirm **three** rows land:

```sql
select event_name,
       properties->>'moment'       as moment,
       properties->>'trigger'      as trigger,
       properties->>'games_played' as games_played,
       properties->>'day_index'    as day_index,
       properties->>'sport'        as sport,
       user_id is not null         as signed_in,
       created_at
from events
where event_name in ('moment_shown','moment_accepted','moment_completed')
  and created_at > now() - interval '2 hours'
order by created_at;
```

Check the property values are *right*, not merely present — `games_played` should equal the
number of games you actually played; `day_index` should match how you set up the install;
`sport` should be present on `favorite_team` and absent on the other two.

### B. No duplicates

The single most likely defect, given this repo's history. Confirm exactly one `moment_shown` per
presentation. Backgrounding and re-foregrounding the app **while a moment sheet is on screen** is
the specific stress case — `ContentView`'s `scenePhase` watcher calls `evaluate` on every
`.active`, and it also has a `.task`. Both should be blocked by `guard pending == nil` and
`shownThisSession`, but verify empirically rather than by reading.

### C. The gates hold under real conditions

- **One per session:** finish two games in one session; confirm a second moment does not arm.
- **48h cooldown:** with `moments.lastShownAt` freshly set, relaunch and confirm no moment fires.
- **Retirement:** claim a username, then re-qualify; confirm `claimUsername` never returns.
- **Push primer wins:** on an install with a streak and notifications still `notDetermined`,
  confirm Home shows `pushPrimerCard` and **no** moment arms. This is the interaction most likely
  to be wrong, because the two prompts were built years apart and only recently taught about
  each other via `PushPrimer.shouldOffer`.
- **`isProfileLoaded`:** sign in on a slow/throttled network and confirm you are **not** asked to
  claim a username you already have. `xcrun simctl status_bar` won't throttle for you; use
  Network Link Conditioner or simply watch the ordering in the logs.

### D. The signed-out `claimUsername` variant

Its CTA is `SignInButtons`, not a plain button. Confirm the sheet renders the Apple button, and
that after sign-in the flow continues into `IdentityEditorSheet` rather than declaring victory at
the account. **The actual sign-in must be performed by the user, not by you** — do not attempt to
enter anyone's credentials. If the user is not available to drive it, verify everything up to the
Apple sheet appearing and say clearly in your report that the post-sign-in half is unverified.

## File ownership (absolute)

You own exactly:
- `docs/ANALYTICS.md` — corrections only, if what you observe contradicts what it documents.

You own **no app source**. If you find a bug, **report it precisely** (file, symptom, the row or
screenshot that proves it) rather than fixing it. This brief is a measurement, and an agent that
edits the thing it is measuring produces neither a fix nor a measurement anyone can trust.

## Definition of done

A report containing:
1. For each of the three moments: how you reached it, a screenshot, and the actual `events` rows
   (pasted, with values) proving shown → accepted → completed.
2. An explicit yes/no on duplicate `moment_shown` rows, with the stress case you ran.
3. Each gate in section C: verified / not verified / verified-by-reading-only. Be exact about
   which.
4. Any discrepancy between observed behavior and `docs/ANALYTICS.md` or
   `docs/BALLIQ_SPEC.md` §1.2.1's Moments section.
5. A list of anything you could not verify and why — an honest gap is worth more here than a
   confident claim that doesn't hold, because the next person will build on this.

## Do not

- Do not write, update, or delete anything in Supabase. **Reads only.** No `insert`, no `update`,
  no `delete`, no DDL. The `events` table is production data.
- Do not query project `pyprjebfwqfdnfeliigo`.
- Do not enter credentials for any account.
- Do not `git commit` or `git push`.
