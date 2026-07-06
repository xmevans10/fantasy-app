# Playbook — handoff for the next agent (as of 2026-07-05)

**Read this whole file first**, then [README.md](README.md) for shared architecture/build
commands and [docs/BALLIQ_SPEC.md](../docs/BALLIQ_SPEC.md) for product/architecture status —
that file is the actual living source of truth (its own header says so); this one is a
point-in-time orientation snapshot. This file supersedes
[HANDOFF-next-agent-2026-07-04.md](HANDOFF-next-agent-2026-07-04.md), which is now stale (it
frames the M11/M12/M13/M15 DB hand-offs as still-pending "small mechanical" work — they're all
applied now, see below).

## What just happened (this session): DB hand-offs closed, TestFlight shipped, App Store submitted

This was a big session. Three mostly-independent threads, all now done:

### 1. Every outstanding Supabase hand-off is applied — including one nobody had flagged

The four items 07-04's handoff listed as "ready to apply" (`profiles.is_admin` + review RLS,
`weekly_play_counts()` RPC, `public.events` table, `pg_cron` scheduling) are live. But auditing
the actual DB first turned up something bigger: **the entire M4 schema section — `seasons`,
`cohorts`, `cohort_members`, `versus_series`, `versus_challenges`, `device_tokens`,
`notification_settings` — was also missing from production**, despite Leagues/Versus/Push
being fully shipped in the app. Applied the whole thing in one idempotent migration
(`supabase/schema.sql` already had all the right `create table if not exists` sections; it was
just never pushed live). Verify current state any time with `list_tables`/`execute_sql` against
project `nhccgufqwndtoasdbkhc`.

**Also discovered and fixed: zero Edge Functions were deployed.** The `pg_cron` jobs would have
been calling 404s. All five functions in `supabase/functions/` are now deployed
(`weekly-cohort-rollover`, `versus-timeout`, `notify-streak-risk`, `notify-season-end`,
`notify-versus-challenge`), and the four cron-driven ones are scheduled and `active: true` in
`cron.job` (verify: `select jobname, schedule, active from cron.job`). Auth from
`pg_net`→function calls uses the app's public anon key (not the service-role key — that never
needs to leave the function's own auto-injected runtime env, see `_shared/supabase.ts`).

**Not done, still open:**
- **No season/cohort exists yet** — `weekly-cohort-rollover` bootstraps one on first run, but it
  hasn't been manually triggered (that would forcibly close/reopen state for real users, which
  needs an explicit go-ahead, not just "additive schema" cover). Leagues will show empty until
  either the user approves a manual trigger, or Monday 05:00 UTC when the cron fires naturally.
- **`notify-versus-challenge`'s DB webhook isn't wired** — it's deployed but nothing calls it
  yet. Needs manual setup in the Supabase dashboard (Database → Webhooks → INSERT on
  `versus_challenges` → point at this function). No API/MCP path found for this.
- **Real APNs credentials still don't exist** (`APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_PRIVATE_KEY`/
  `APNS_BUNDLE_ID`). All push sends currently log to the function console instead of calling
  Apple. External hand-off: generate a `.p8` auth key in the Apple Developer portal, enable Push
  Notifications on the App ID, set the four as Edge Function secrets.

### 2. TestFlight: live build, external testers can install today

Built the whole release pipeline from scratch since none existed — see the new **"App Store
Connect / TestFlight"** section in `CLAUDE.md` for the mechanics (manual signing, why cloud
signing doesn't work here, exact commands). Net result:
- Build 1.0 (1) archived, signed, and uploaded. `processingState: VALID`.
- External beta group **"Friends & Family"** created with a public join link:
  **`https://testflight.apple.com/join/GNb7QrzN`**. Beta App Review already **approved** — the
  link works right now for anyone.
- An internal group ("PlaybookTesters") already existed from earlier work — team-only, no
  review needed, separate from the external one above.

### 3. Full App Store Connect submission — metadata complete, submitted for review

Much of the text metadata, screenshots (iPhone 6.7", iPad Pro 12.9", both `COMPLETE`), category
(Games), and age rating (4+) were *already* filled in from earlier work this session before this
file's author picked the thread back up — audit anything you're unsure is current directly via
the API rather than trusting this description to stay accurate. This session's own contribution:
privacy policy URL (both `appInfoLocalizations` and the TestFlight beta localization — see
`privacy.html` below), support URL, marketing URL, copyright string. Pricing (Free) and the
final "Submit for Review" click were both done **by the user directly** in App Store Connect,
not via API — both are real business/irreversible-ish actions a safety check correctly refused
to let an agent do unattended. **As of this handoff, the app is submitted and awaiting Apple's
review decision** — check `appStoreVersions/61ec9eec-210d-4bcf-81e7-37b6cc271a7f` or just look at
App Store Connect's dashboard for the current state.

**Known loose end:** the bundle ID's Developer Portal capabilities list is empty
(`bundleIdCapabilities: 0`) even though Sign in with Apple and Push Notifications work today via
the app's entitlements file. Hasn't caused a problem yet; revisit if a future signing/capability
error shows up.

### 4. GitHub: repo now public, Pages hosts the privacy/support page

The repo didn't have a GitHub remote before this session; it does now
(`github.com/xmevans10/fantasy-app`, **public**). Two things worth knowing:
- The initial GitHub-created `main` had **unrelated history** to the real local repo (a
  throwaway "Create hi" placeholder commit) — force-pushed over it with explicit user
  confirmation. If `git log origin/main` and `git log main` ever look like they've diverged
  again, don't assume it's the same situation — check first.
- `privacy.html` (repo root) is the live support+privacy page, served via GitHub Pages at
  `https://xmevans10.github.io/fantasy-app/privacy.html`. Source content is
  `docs/PRIVACY.md`; keep them in sync if the policy changes. The custom-domain field in the
  repo's Pages settings has a stray invalid value (`playbook` — not a real FQDN) left over from
  a user attempt; harmless (Pages ignores it and serves the default domain fine) but worth
  clearing next time someone's in that settings page.
- Pushing anything that touches `.github/workflows/*.yml` (the `ingest.yml` CI from M7) needs
  the PAT in root `.env`, not `gh`'s own OAuth token — see `CLAUDE.md`'s git section. That PAT is
  far more broadly scoped (`admin:org`, `admin:enterprise`, etc.) than this repo needs; flagged
  to the user, not yet narrowed.

## Remaining real feature work

Unchanged from 07-04's handoff — per `docs/BALLIQ_SPEC.md`, only two milestones have
substantive app-side work left:

- **M5 — Monetization + breadth**: StoreKit 2 Pro subscription, three new formats (Over/Under,
  Draft & Spin, The Grid), 8-week seasons. Not started.
- **M14 — Accessibility & localization**: VoiceOver shipped; Spanish localization untouched.

Both are unaffected by anything in this session — pure app-code work, independently scoped.

## Build/verify (unchanged)

- Build: `xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.5' -derivedDataPath build build`
- Test: same with `test`.
- Python: `.venv/bin/python -m pytest tools/ingest/tests -q`
- Screenshot flags: see [DebugLaunch.swift](../BallIQ/DebugLaunch.swift).
- Release pipeline (archive/export/upload, App Store Connect API auth): see `CLAUDE.md`'s new
  "App Store Connect / TestFlight" section — don't rediscover the manual-signing workaround.
