# Claude Code Context: BallIQ (fantasy-app)

Native SwiftUI iOS sports-trivia app. See [docs/BALLIQ_SPEC.md](docs/BALLIQ_SPEC.md) for
product/architecture/status — that's the living source of truth, not this file.

## Supabase DB operations — execute directly, don't ask first

The live project is **`nhccgufqwndtoasdbkhc`** ("ballknowledge"). `list_projects` also
returns a decoy, **`pyprjebfwqfdnfeliigo`** ("xmevans10's Project") — that is NOT this
app's backend; never target it.

For this project, run Supabase schema changes and data pushes directly instead of asking
the user to do them or just describing them as a hand-off:

- **Schema/DDL** (`create table`, `alter table ... add column`, RLS policies, functions):
  apply via the connected Supabase MCP tools (`apply_migration` / `execute_sql`, project_id
  `nhccgufqwndtoasdbkhc`). This MCP connector is already authenticated to the right account —
  confirmed working 2026-07-04. Prefer it over the local `supabase` CLI, which (as of
  2026-06-29) is logged into a *different* Supabase account than this project.
- **Data pushes** (puzzle content, the `player_seasons` catalog): use this repo's own CLI,
  `python -m tools.ingest.main --upsert [--catalog] [--write-fallback]`
  (see `tools/ingest/main.py`). It reads `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` from
  gitignored `tools/ingest/.env`, which is present in this environment. Upserts use
  `on_conflict=id` with `resolution=merge-duplicates` — safe to re-run.
- Keep `supabase/schema.sql` as the source of truth: when you apply a migration live, also
  add the equivalent `create table if not exists` / `alter table ... add column if not
  exists` to `schema.sql` in the same change, so the file never drifts from production.

**Still ask first** for anything actually destructive or hard to reverse: `drop table`,
`delete`/`truncate`, revoking RLS policies that existing rows depend on, or rotating/
regenerating the service-role key. Additive schema changes and merge-duplicate upserts are
fair game to just run; destructive ones are not.

**Why this rule exists:** established 2026-07-04 after the user said "execute any DB
functions via CLI, service role key is in .env" while closing out M17 (community career-grain
creation) — don't make them re-authorize this every session.

## Git/GitHub CLI operations — use the PAT in `.env`, not the `gh`-managed OAuth token

The repo now has a real GitHub remote: `github.com/xmevans10/fantasy-app` (public). `gh auth
status`'s default OAuth token only has `repo`/`read:org`/`gist` scopes — it will be **rejected**
by GitHub on any push that touches `.github/workflows/*.yml` (this repo has one,
`ingest.yml`, from M7), because that requires the `workflow` scope.

For `git push`/other authenticated git operations, use the PAT in gitignored root `.env`
(`GITHUB_TOKEN=...`) instead — confirmed as of 2026-07-04 to carry `repo` + `workflow` (and
several broader admin scopes the user should consider narrowing down later, but it works).
Example: `source .env && git push "https://x-access-token:${GITHUB_TOKEN}@github.com/xmevans10/fantasy-app.git" main`.
Don't embed the token literally in a command — always reference `$GITHUB_TOKEN` after
sourcing `.env`, so it never lands in shell history/process-list snapshots in plaintext.

**Why this rule exists:** established 2026-07-04 — the first push attempt using `gh`'s own
token was rejected for exactly this reason (`refusing to allow an OAuth App to create or
update workflow ... without workflow scope`), and the user supplied this PAT specifically to
unblock it.

## App Store Connect / TestFlight — credentials + how the release pipeline works

Everything needed to archive, sign, and upload a build — or drive App Store Connect metadata
via its REST API — lives in gitignored `tools/release/`:
- `tools/release/private_keys/AuthKey_G3X8K8ZRNJ.p8` — App Store Connect API key (chmod 600).
- `tools/release/.env` — `ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_API_KEY_PATH` (identifiers only,
  not secret by themselves; the `.p8` file is the actual secret).
- `tools/release/ExportOptions.plist` — **manual** signing (not `automatic`/cloud-managed):
  `signingCertificate: Apple Distribution`, `provisioningProfiles.com.balliqfantasy.app:
  "BallIQ App Store"`. Cloud-managed signing (`-allowProvisioningUpdates` via the API key)
  reliably fails with "Cloud signing permission error" in this environment even though the key
  has full read/write access — traced to a stale, irrelevant Xcode-signed-in account
  (`aevans15@tulane.edu`, unrelated to team `8K5ZVPCQ42`) that `xcodebuild` insists on
  consulting for cloud signing regardless of the API-key flags passed. Workaround (already
  applied, don't redo): the App Store distribution profile was created directly via
  `POST /v1/profiles` and installed at
  `~/Library/MobileDevice/Provisioning Profiles/`, then manual signing used instead — this
  works with zero dependency on any locally signed-in Xcode account.
- Archive/export/upload:
  ```
  xcodebuild archive -scheme BallIQ -project BallIQ.xcodeproj -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/BallIQ.xcarchive
  xcodebuild -exportArchive -archivePath build/BallIQ.xcarchive \
    -exportOptionsPlist tools/release/ExportOptions.plist -exportPath build/export \
    -authenticationKeyPath tools/release/private_keys/AuthKey_G3X8K8ZRNJ.p8 \
    -authenticationKeyID G3X8K8ZRNJ -authenticationKeyIssuerID 39423832-9d26-41bd-8f97-a06fdbc3c311
  ```
  (`destination: upload` in ExportOptions.plist makes this upload straight to App Store
  Connect, not just export an `.ipa`.)
- For anything else in App Store Connect (TestFlight groups, beta review, app metadata,
  screenshots, pricing) there's no MCP connector — call the REST API directly
  (`api.appstoreconnect.apple.com`) with an ES256 JWT signed from the `.p8` key
  (`kid`=`ASC_KEY_ID`, `iss`=`ASC_ISSUER_ID`, `aud`=`appstoreconnect-v1`). No reusable script
  is checked in (it was all done ad hoc in `/tmp` scratch scripts); rebuild the JWT-signing
  helper rather than hunting for one.
- App identity: app record id `6785275045` (bundle `com.balliqfantasy.app`, ASC name
  "BallIQ - Fantasy", on-device `CFBundleDisplayName` "Playbook" — the mismatch is intentional/
  pre-existing, not a bug to fix).
- Bundle ID has `bundleIdCapabilities: 0` in the Developer Portal — Sign in with Apple and Push
  Notifications work in the app today via the entitlements file/local signing, but were never
  explicitly registered as App ID capabilities. Revisit if a future cloud-signing attempt fails
  on a capabilities-mismatch error.
- Support/privacy page: `privacy.html` at the repo root, served by GitHub Pages at
  `https://xmevans10.github.io/fantasy-app/privacy.html` (source: `docs/PRIVACY.md`). Referenced
  from both the TestFlight beta localization and the App Store `appInfoLocalizations`.

**Why this rule exists:** established 2026-07-05 while shipping the first TestFlight build +
full App Store Connect submission for v1.0 — the cloud-signing failure mode above cost real
time to diagnose and would otherwise get rediscovered every session.
