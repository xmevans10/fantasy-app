# My Teams — Saints TestFlight pilot

TestFlight: Playbook 1.9.0 (60), October 14, 2026. Built on main `9e74a66` after core-product cleanup. This is a finite team collection, not a team daily service.

## Player experience

Home has a My Teams switcher driven by existing favorites, with guest preferences persisted. New Orleans has 13 validated K4C4 games: Brees, Colston, Ingram and Kamara ladders, receiving/rushing history and era comparisons. Brees is the free starter; the deeper collection uses the existing Pro archive entitlement. Other teams retain preferences and show a clearly labeled general-game fallback until enabled.

The hub groups icons, history, deep cuts and completed games. Native K4C4 scoring/game/result views are reused. A fixed next-game action offers another distinct board or the existing Pro paywall. Team play is normal mode and unranked. Shared career progress shows a permanent level, next-level distance and named milestones; competitive rating is unchanged. The level curve preserves thresholds through level 10 and caps subsequent intervals at 1,900 XP.

Completion markers persist across days. Guests earn on-device once; signed-in rewards are computed from published grades and committed with a unique user+puzzle ledger. Signed-in offline results enter a durable outbox; XP/streak settle on reconnection using the settlement day. Guest history is claimed at sign-in without awarding twice. Existing account-owner cleanup also clears team history/preferences. Guest history remains device-local until sign-in.

## Content and operations

`python -m tools.ingest.team_puzzles --env-file PATH --output report.json` reads stored Supabase Saints regular seasons only. No provider refresh, per-fan generation or LLM is needed. Complete score-bearing stats, canonical person identity, production floors, eight unique season cards and an unambiguous keep/cut boundary are mandatory. NFL season cutoff conservatively treats the previous season as complete from March onward. At most five of eight cards may overlap with an accepted board. Recipe counts and rejection reasons are emitted in the report; most historical rows without canonical person IDs are excluded.

`--publish` requires at least 12 valid boards. Portrait-independent immutable content identities, ignore-duplicate inserts and comparison with existing inventory prevent duplicate or high-overlap publication. A manual/weekly GitHub Actions workflow provides bounded retries, single-run concurrency and retained report artifacts. Assembly measured about 0.02 seconds for the pilot; retaining the existing Python assembler avoids a second scoring implementation. Supabase owns inventory, indexed team reads, release visibility and atomic rewards. New formats/teams need explicit data and recipe validation.

`team_puzzles` is separate from general daily pools, so older clients remain unaffected. RLS exposes only published, available rows and each caller's own completion history. Service role publishes. The client requests at most 100 rows for one team; the 13-board bundle supports offline play. Portrait policy matches the existing official-image policy. Pending offline results and bundled content must be considered when withdrawing a board: a withdrawn board cannot settle new server rewards, and an offline bundle can remain playable until an app update.

Migrations 0040/0041 were applied to `nhccgufqwndtoasdbkhc`. A progress trigger prevents delayed pre-team snapshots from erasing banked team XP or moving last-played day backward. This does not replace the app's broader snapshot-based progress sync protocol.

## Verification

- 13 live boards, three shelves, one free starter; same-team attribution and display-to-score formula checks.
- Deterministic generation, missing-stat/person exclusions, short-ladder rejection and overlap tests.
- Transactional SQL checks: score recomputation, first reward, duplicate reward suppression, malformed placement/date rejection, anonymous denial, own-history RLS, future-content hiding and stale snapshot protection. Test state rolled back.
- Native persistence/outbox, bundle contracts, level boundaries and guest replay suppression tests.
- Hosted Home, hub, gameplay, result, completed and accessibility-text screenshots on iPhone 15 and SE. No image/name/chip redesign was imported from the rejected earlier branch.
- Full iOS suite: 1,038 tests, one existing skip, zero failures. Final SE/version checks: 12 tests, zero failures.
- Python suite: 968 passed, one skipped. Test-only F1 identity fetches are isolated; local-server tests ran with network access.
- Signed Release archive succeeded; its Info.plist confirms 1.9.0 (60). Apple marks build 60 VALID; internal testing is READY_FOR_BETA_TESTING. Both existing external groups are assigned (HTTP 204), with beta review WAITING_FOR_REVIEW. Testing notes are set. PR #6 merged at a0672029. The shared-inventory workflow succeeded on main (run 38602185797), and the exact archived app’s guest REST configuration fetched all 13 boards with content identical to its bundle.

Analytics: `team_viewed`, `team_puzzle_started`, `team_puzzle_completed`, with team/puzzle identifiers. Evaluate entry-to-play, completion, next-game selection and returns; do not treat recipe ranking or pilot traffic as proof of retention improvement.

TestFlight is the fan-testing stage. Wider NFL/sport rollout, Who Am I? team clues, daily schedules, and mastery percentiles remain gated on validated data and pilot feedback. Trading-card collections and pack economies remain retired.
