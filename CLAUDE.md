# Claude Code Context: BallIQ (fantasy-app)

Native SwiftUI iOS sports-trivia app. See [docs/BALLIQ_SPEC.md](docs/BALLIQ_SPEC.md) for
product/architecture/status — that's the living source of truth, not this file. See
[AGENTS.md](AGENTS.md) for *how* to work in this repo at the right quality bar (verification
habits, shared-vs-duplicated logic, blast-radius judgment) — this file is project facts, that
one is process. **§9.1's version roadmap (1.2 push → 1.3 monetization → 1.4 rating seasons
→ 1.5 content depth) is fully shipped and live — when picking what to work on next, check
BALLIQ_SPEC.md §9.3's post-1.5 roadmap instead** (growth/marketing + new engagement features
prioritized ahead of further Grid-depth/monetization-funnel work; §9.0's tier rule still
governs anything outside that roadmap). The app is LIVE on the App Store, monetization
switched on: v1.3 build 21 is `READY_FOR_SALE` as of 2026-07-31 (confirmed via the ASC API —
see BALLIQ_SPEC.md §8 Release status for what shipped in the builds since 1.3's double
rejection, including native Sign in with Google and an account-switch data-isolation fix) —
treat `main` as production.

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

## App Store Connect / TestFlight

Archiving, signing, uploading a build, or driving App Store Connect metadata (TestFlight
groups, beta review, app info) is covered by the `testflight-release` skill
(`.claude/skills/testflight-release/SKILL.md`) rather than inline here — it's real
credentials + a hard-won cloud-signing workaround, but only relevant during release work,
so it loads on demand instead of every session.

## Dispatching subagents for feature/provider work

When orchestrating parallel work (the pattern in `prompts/HANDOFF-*.md`: orchestrator does
shared plumbing, then dispatches disjoint-file-ownership subagents), use the two custom
subagents already defined for this repo instead of hand-writing the brief from scratch each
time — `Agent({ subagent_type: "balliq-swift-feature", ... })` for a SwiftUI slice and
`Agent({ subagent_type: "balliq-data-provider", ... })` for an ingest provider. Both already
know the pbxproj/RepositoryContainer/design-vocabulary/stdlib-runtime rules and the
verification bar; your brief only needs the task-specific parts (exact file ownership, API
contracts to paste, what "done" looks like).

## When you get corrected, fix the context that misled you

If the user corrects a fact you asserted, a documented command/flag/path turns out to be
wrong, a subagent reports its brief didn't match the code, or you had to grep for something
these docs should have told you — that is a defect in this file, `AGENTS.md`,
`docs/BALLIQ_SPEC.md`, the memory directory, or a subagent brief. Fixing only the immediate
task leaves it in place for the next session, which is how this repo lost months to a
silently-empty Versus tab and re-derived the same Supabase auth gotcha more than once.

Invoke the **`context-repair`** skill and follow it: attribute in one backward pass over the
session (earliest inconsistent step, not the latest), **read the target file before deciding
CREATE vs UPDATE**, then write the smallest correct fix. Not every failure qualifies — a
plain bug with no documentary cause is just a bug, and the skill has a NO_ACTION path.

**Why this rule exists:** established 2026-08-24, adopting the mechanics from Amazon's TRACE
paper (arXiv:2608.09153). It lives here rather than only in AGENTS.md §12 because this file
is loaded into every session automatically and `AGENTS.md` is not.
