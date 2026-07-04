# Playbook — M6: Community fixes + backend hardening

Self-contained prompt for a fresh agent. Read [prompts/README.md](README.md) for shared context
(build/test commands, architecture, design system, secrets policy) — it is not repeated here. Assumes
the repo as of **2026-06-29**: M5 shipped (PPR fantasy scoring + 0–100 display grade + foil card),
both test suites green, grading reference at [docs/scoring-and-grading.md](../docs/scoring-and-grading.md).

`fantasy-app` is **Playbook**, a native SwiftUI iOS sports-trivia app (NOT the chess coach in the global
`~/CLAUDE.md`). Supabase project `nhccgufqwndtoasdbkhc`; a Supabase MCP is connected (use it for SQL).
`tools/ingest/.env` (gitignored) holds the service-role + provider keys. App ships only the public anon
key in gitignored `BallIQ/Backend/Supabase.plist`.

---

## Task 1 (PRIMARY, confirmed bug): community puzzles vanish on refresh

**Symptom (user-reported, reproducible):** the Community feed shows user-created puzzles, then
pull-to-refresh (or any filter/sort change) makes them **disappear** to the empty state.

**This is already diagnosed — do not re-investigate from scratch; verify the fix.** Findings:

- The data is fine. Live DB has a public `keep4` row (`id=4fk5m16y`, "Elite WR seasons",
  `visibility=public`). The *exact* feed REST query the app builds returns it with **HTTP 200 even
  anonymously** (anon key, no user JWT). RLS read policy is `using (true)`. Decode is fine
  (`CommunitySummary.createdAt` is a `String`; all selected keys present). So server + query + decode
  are NOT the problem.

- **Root cause is client-side, two compounding bugs:**
  1. **Silent error→empty.** `CommunityPuzzleRepository.feed(...)`
     ([CommunityPuzzleRepository.swift:56](../BallIQ/Data/Repositories/CommunityPuzzleRepository.swift))
     swallows every error: `(try? await client.select(...)) ?? []`. And `CommunityView.load()`
     ([CommunityView.swift:135](../BallIQ/Features/Community/CommunityView.swift)) **unconditionally**
     assigns `items = await community.feed(...)`. So ANY transient failure wipes the visible list.
  2. **Stale JWT, never refreshed per-request.** When signed in, `SupabaseClient.applyHeaders`
     ([SupabaseClient.swift:69](../BallIQ/Backend/SupabaseClient.swift)) sends
     `Authorization: Bearer <token>` from `TokenBox`, set once in `AuthService.apply()`.
     `auth.refreshIfNeeded()` is called **only once at startup**
     ([RepositoryContainer.swift:52](../BallIQ/RepositoryContainer.swift)) — never before requests.
     `Session.isExpired` (refreshes 60s early) exists but **nothing consults it per-request**. Once the
     access token expires (~1h default), every authenticated request returns **401** (an expired JWT is
     rejected at the auth layer even for a `using(true)` read), `perform` throws
     `SupabaseError.http(401, …)`, `feed` returns `[]`, the feed empties. Deterministic once expired →
     matches "refresh makes them disappear."

**Success criteria:**
- A signed-in user with an expired token can refresh the Community feed and still see public puzzles.
- A transient fetch error never silently blanks a previously-populated feed — it keeps the last good
  list and surfaces an error affordance (e.g. a retry).
- Same hardening applied wherever a feed/read uses the `(try? …) ?? []` pattern (audit for siblings:
  `feed`, `keep4`, `whoAmI`, `load`, `resolve` in the same repo; the daily/catalog repos too).
- Existing tests stay green; add a unit test that `load()` does not clear `items` when the fetch throws.

**Recommended fix (do all three — defense in depth):**
1. **Don't clobber on failure.** Make `feed` (and friends) `throws` or return a `Result`, so
   `CommunityView.load()` can distinguish "genuinely empty" from "fetch failed" — on failure, keep the
   prior `items` and set an error flag. At minimum: compute into a local, only assign on success.
2. **Refresh the token before authenticated requests.** Either (a) have `SupabaseClient.perform` retry
   once on 401 after asking the `TokenProvider` to refresh, or (b) check `Session.isExpired` and
   `await auth.refreshIfNeeded()` before issuing requests. Wire it so `TokenBox` always hands out a
   fresh token.
3. **Public reads shouldn't depend on a session.** For world-readable tables (`community_puzzles`,
   `player_seasons`, daily `puzzles`), fall back to the **anon key** when the user token is
   missing/expired so the feed never breaks on auth state. (Anon read is verified working.)

**Verify:** build + run in sim, sign in, force-expire the token (or wait), pull-to-refresh — puzzles
persist. Screenshot the populated feed after refresh. Add the regression test.

---

## Task 2: NBA isn't live (balldontlie 429)

`tools/ingest/providers/nba_balldontlie.py` `fetch_targets()` sleeps 1.2s *between targets* but not
between the **two sequential calls per target** (`_find_player` then `season_averages`), so every live
fetch 429s and silently falls back to the curated 34-season seed (`tools/ingest/data/nba_seed.csv`).
Add a sleep/backoff between those two calls (and retry-on-429 with exponential backoff). Then a broad
per-season pull is needed before NBA era baselines / 0–100 bounds are meaningful (the curated seed
skews to legends — see [docs/scoring-and-grading.md](../docs/scoring-and-grading.md) "Known gaps").

**Success:** a live `python -m tools.ingest.main --dry-run` returns real balldontlie NBA rows (source
`balldontlie`, not `seed`) with no 429s in the logs.

---

## Task 3: the pipeline never runs automatically

`.github/workflows/ingest.yml` defines a correct daily cron that has **never executed** — the local
directory is **not a git repo** (`git status` → "fatal: not a git repository") and was never pushed.
Every upsert to date has been a manual CLI run. First step: `git init`, commit, push to GitHub, confirm
the Action runs and the daily/catalog upserts land. (Honor `.gitignore`: never commit `Supabase.plist`
or `tools/ingest/.env`.)

---

## Task 4 (backlog, pick up as capacity allows)

- **0–100 bounds auto-recalibration.** `_FANTASY_BOUNDS` in `tools/ingest/grade.py` are hand-set
  constants; a record season just clips at 100. Add a `--recalibrate-bounds` step that prints fresh
  percentiles so the bounds can be revisited when the ingested population grows. Keep Swift↔Python
  parity (`GradeFormula.swift`, `ScoringRule.swift`) if any constant changes.
- **Single-game grading (net-new milestone).** Entire data model is season-level only (`RawSeason`,
  `player_seasons`); there is no box-score concept. Would need a game-level data model + provider +
  its own DFS-style scale with single-game bounds. Scope before building.
- **Auth providers are dashboard-blocked.** Apple + Google are disabled in the Supabase project
  (`GET /auth/v1/settings` → both `false`); create→publish→play E2E needs a real session. Entering the
  OAuth client IDs/secrets is a **user hand-off**, not an agent task — surface it, don't attempt it.
- **Thin Who Am I? pool** (~12 entries) — widen via the ingest pipeline.

---

## Guardrails (every task)

- Keep Swift↔Python grade parity tested on **all three** impls (`grade.py`, `GradeFormula.swift`,
  `ScoringRule.swift`); grades stay **baked at publish**, never recomputed at read time.
- Community `content` jsonb stays **camelCase** (plain `JSONEncoder`, not the snake-casing `.supabase`
  one). Never ship `service_role` in the app.
- Match the "Prime Time" design system (`BallIQ/DesignSystem/DESIGN.md`) for any new UI; gate motion on
  Reduce Motion.
- Run both suites + a screenshot before claiming done. The agent can't provision third-party accounts
  or enter user credentials — surface those as explicit hand-offs.
```
Build: xcodebuild -scheme BallIQ -project BallIQ.xcodeproj -destination 'id=5D066EE7-6D68-4CF5-B95B-FE582A8E0570' -derivedDataPath build test
Pipeline: python3 -m tools.ingest.main [--dry-run|--write-fallback|--catalog --upsert]
```
