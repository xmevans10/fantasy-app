---
name: testflight-release
description: Archive, sign, and upload a BallIQ build to App Store Connect/TestFlight, or drive App Store Connect metadata (TestFlight groups, beta review, app info, screenshots, pricing) via its REST API. Use when the task involves shipping a build, TestFlight, App Store Connect, or Apple release/signing credentials.
---

# TestFlight / App Store Connect release pipeline

Everything needed to archive, sign, and upload a build — or drive App Store Connect
metadata via its REST API — lives in gitignored `tools/release/`:

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
  (`kid`=`ASC_KEY_ID`, `iss`=`ASC_ISSUER_ID`, `aud`=`appstoreconnect-v1`). A reusable helper
  now lives at gitignored `tools/release/asc.py` (added 2026-07-16, run from the repo root):
  `python3 tools/release/asc.py GET|POST|PATCH|DELETE <path> ['<json-body>']` — stdlib-only,
  signs the JWT via `openssl` (DER→raw conversion included). Apple's API occasionally drops
  a connection (`RemoteDisconnected`); just retry once.
- **1.1 release flow, proven end-to-end 2026-07-16** (v1.0 went READY_FOR_SALE ~2026-07-16;
  1.1 = build 9 submitted same day): bump `CURRENT_PROJECT_VERSION` in the pbxproj → archive/
  export-upload per above → `POST /v1/appStoreVersions` (versionString, app rel) →
  `PATCH .../appStoreVersionLocalizations/<id>` `whatsNew` → poll `GET /v1/builds?filter[app]=
  …&filter[version]=N` for `processingState: VALID` (~15 min) → `PATCH /v1/appStoreVersions/
  <id>/relationships/build` → `POST /v1/reviewSubmissions` + `POST /v1/reviewSubmissionItems`
  → `PATCH /v1/reviewSubmissions/<id>` `{"submitted": true}`. Export compliance never blocks:
  `ITSAppUsesNonExemptEncryption=false` is baked into Info.plist.
- **Resubmit-after-rejection flow, proven 2026-07-22 (build 12 for the 3.1.2(c) EULA fix):** when
  a version is `REJECTED`, do NOT create a new `appStoreVersion` — reuse the existing one. Fix code
  → bump build → archive/export-upload → poll build to `VALID` → `PATCH .../relationships/build`
  to attach the new build (the version flips `REJECTED` → `PREPARE_FOR_SUBMISSION`). The original
  rejected `reviewSubmission` stays in state `UNRESOLVED_ISSUES` (its item is `REJECTED`); resubmit
  through it with `PATCH /v1/reviewSubmissions/<id>` `{"submitted": true}` — do NOT try to POST a
  new submission (only one open submission allowed). **Gotcha:** for several minutes after
  attaching the build the submit `PATCH` returns `409 STATE_ERROR` "Version is not ready to be
  submitted yet, please try again later" even though `appStoreState` already reads
  `PREPARE_FOR_SUBMISSION` — it's a backend propagation lag, not a real error. Retry the same PATCH
  on a ~60s loop until it 200s. **Metadata edits** (e.g. adding a required link to `description`):
  `PATCH /v1/appStoreVersionLocalizations/<loc-id>` `{attributes:{description}}` works while the
  version is editable. **Reviewer notes:** `PATCH /v1/appStoreReviewDetails/<id>` `{attributes:{notes}}`.
  **One UI-only step remains:** the Resolution Center reply (and any screen recording Apple asks
  for) is not exposed in the REST API — the user must post it manually.
- **Cancel-a-queued-submission flow, proven 2026-07-27 (build 15, to fold the Grid work into the
  in-flight 1.2):** Apple allows only **one open review submission per app**, so you cannot cut a
  new version while another sits in `WAITING_FOR_REVIEW` — the only ways forward are to wait it
  out or cancel it. Cancel with `PATCH /v1/reviewSubmissions/<id>` `{"canceled": true}`; it
  returns state `CANCELING` and settles to `COMPLETE` within a minute or two, and the
  `appStoreVersion` lands in **`DEVELOPER_REJECTED`**. From there it's the resubmit flow — attach
  the new build (`PATCH .../relationships/build`, which flips the version to
  `PREPARE_FOR_SUBMISSION`) — with **one critical difference from the rejection path above**: a
  *canceled* submission is `COMPLETE`, not `UNRESOLVED_ISSUES`, so there is nothing to resubmit
  through. You must `POST /v1/reviewSubmissions` + `POST /v1/reviewSubmissionItems` for a **new**
  submission, which is exactly what the rejection path tells you *not* to do. Getting this
  backwards is the easy mistake. The `409 STATE_ERROR` propagation lag did **not** appear on this
  path (submit `PATCH` 200'd on the first attempt), but keep the retry loop — it's cheap.
  Cost to weigh before cancelling: the queued version loses its place in the review queue and
  restarts review from scratch.
  - `-authenticationKeyPath` for `-exportArchive` **must be an absolute path** — a repo-relative
    path fails with "must be an absolute path to an existing file". Wrap in `$(pwd)/…`.
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

**Why this exists:** established 2026-07-05 while shipping the first TestFlight build +
full App Store Connect submission for v1.0 — the cloud-signing failure mode above cost real
time to diagnose and would otherwise get rediscovered every session. Moved from CLAUDE.md
into this on-demand skill 2026-07-12 (release work is not every-session-relevant, so it
doesn't need to load into every conversation's context — see CLAUDE.md for the pointer).
