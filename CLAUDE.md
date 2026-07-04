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
