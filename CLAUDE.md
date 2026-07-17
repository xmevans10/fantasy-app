# Claude Code Context: BallIQ (fantasy-app)

Native SwiftUI iOS sports-trivia app. See [docs/BALLIQ_SPEC.md](docs/BALLIQ_SPEC.md) for
product/architecture/status — that's the living source of truth, not this file. See
[AGENTS.md](AGENTS.md) for *how* to work in this repo at the right quality bar (verification
habits, shared-vs-duplicated logic, blast-radius judgment) — this file is project facts, that
one is process. **When picking what to work on next, check BALLIQ_SPEC.md §9.1's version
roadmap first** (1.2 push → 1.3 monetization → 1.4 rating seasons → 1.5 content depth;
§9.0's tier rule still governs anything outside that roadmap). The app is LIVE on the App
Store as of 2026-07-16 (v1.0 approved; v1.1 in review) — treat `main` as production.

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
