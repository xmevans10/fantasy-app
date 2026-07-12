# Handoff — continue BallIQ development (2026-07-12, session B)

You are the orchestrator agent for this repo. Read `CLAUDE.md`, `AGENTS.md`, and skim
`docs/BALLIQ_SPEC.md` §7–§9 first. This supersedes `HANDOFF-next-agent-2026-07-12.md`
(that session's work is fully landed and pushed — nothing uncommitted this time; tree is
clean at `d27e75e`).

## What the previous session (2026-07-12) landed

1. Committed + pushed the three bodies of work the prior handoff described (minigame
   polish, tennis ingest + incremental catalog, M19 social layer).
2. **M19 server side live-verified 16/16** with two throwaway auth users exercising the
   full flow under their own JWTs (RLS negatives included: spoofed requester, reverse
   duplicate, username 409). The *signed-in UI pass* is still open — needs two real
   TestFlight accounts (claim → request → accept → challenge → public profiles from
   Leagues/Community/Versus). That remains the top QA task.
3. **M20 social follow-through shipped** (commit `89d44ad`):
   - FRIENDS scope on Leagues (`friend_profiles()` RPC — one round trip, security definer,
     live-verified; sport chips; me-row from local state; `FriendsLeaderboardTests`).
   - Onboarding username claim: post-sign-in, `IdentityEditorSheet` presented once if
     `identity.username == nil`, skippable.
   - Friend-request push: `notify-friend-request` edge function deployed;
     `notification_settings.friend_request` column + Profile toggle;
     **pg_net AFTER INSERT triggers now wired for BOTH `notify-friend-request` and
     `notify-versus-challenge`** — the old "wire webhook in dashboard" hand-off is dead.
     Chain verified live: friends insert → trigger → function → `{"sent":1}`.
   - Suites at close: 242 Swift / 181 Python / 18 deno (`deno test --allow-env .` from
     `supabase/functions/`).

## Prioritized backlog (from §9 + prior handoff, updated)

1. **Human/TestFlight QA of M19+M20 signed-in surfaces** (agent can't do real
   Apple/Google sign-in): friends flow, FRIENDS leaderboard, onboarding claim sheet.
   Fix whatever falls out.
2. **Soccer data gap — needs explicit user green-light on approach before building**:
   `JaseZiv/worldfootballR_data` mirror, `fb_big5_advanced_season_stats/*.rds`, one-time
   `.rds`→CSV (`pyreadr`), provider shaped like `tennis_wta.py`. No FBref live scraping.
3. **M14 Spanish localization** — untouched, pure app-code, parallelizes by feature folder.
4. **M5 Phase F** — 8-week rating seasons (SPEC §8/§9).
5. External hand-offs still pending (user, not agent): APNs key material (secrets unset —
   pushes stub-log), Paid Applications agreement / ASC products for M5 Phase B.

## Method

Same orchestration pattern as before (see `HANDOFF-next-agent-2026-07-12.md` §2 — it
worked again this session): recon yourself, orchestrator owns shared plumbing
(migrations via Supabase MCP + mirror to schema.sql, `RepositoryContainer`, shared views),
2 Sonnet subagents max with provably disjoint file ownership + pasted API contracts +
own `-derivedDataPath`, integration pass + screenshots yourself, report verified vs. assumed.

New gotcha discovered this session: `simctl uninstall` does NOT clear the app's
UserDefaults (cfprefsd caches by bundle id) — `xcrun simctl spawn <sim> defaults delete
com.balliqfantasy.app <key>` before fresh-install screenshots (e.g. onboarding).
