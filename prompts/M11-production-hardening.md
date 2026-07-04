# M11 — Production hardening & automation close-out

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.
> Read [docs/BALLIQ_SPEC.md](../docs/BALLIQ_SPEC.md) §2 and §8 for the exact open-items list this
> milestone closes.

## Goal

Finish what M4–M10 already built but never fully wired up. Nothing here is new product surface —
it's closing the gap between "the code exists" and "the code actually runs in production." After
this milestone, Versus auto-forfeits on timeout, Leagues seasons roll over on schedule, streak-risk
and challenge push notifications actually deliver, and the one known gameplay-correctness bug is
fixed.

## Why now

M10 shipped with five specific open items in the spec (§8) that are all closeable without new
product design — they're plumbing. Leaving them open means the app *looks* done (six live tabs,
real content, real scoring) but silently doesn't do what its own UI promises (a Versus challenge
that never expires, a season that never ends, a "DONE" badge that lies about which format you
played).

## Current state to build on

- Five Deno edge functions exist and are individually correct (`supabase/functions/`) but none are
  scheduled — each has a hand-written comment stating its intended cadence.
- `RepositoryContainer.hasPlayedToday(_:)` is a single boolean keyed by day, shared across both
  Keep4 and Who Am I? — finishing either format marks both Home cards DONE.
- The bundled offline fallback was regenerated with raw-PPR grades (2026-07-02); the live Supabase
  `puzzles` table was not — the daily rows a signed-in user actually plays may still be on the old
  0–100 scale depending on when they last synced.
- `apns.ts`'s `sendApnsPush` is a stub; the JWT-signing path (`TODO(hand-off)`) is unwritten.

## Scope

1. **Per-format daily completion.** Replace the single day-string flag with a per-`GameFormatKind`
   completion set (`LocalProgressRepository` + sync payload). Home's Keep4 and Who Am I? cards must
   independently show DONE. Add a regression test that completing one format doesn't complete the
   other.
2. **Schedule the edge functions.** Write the `pg_cron`/`pg_net` migration (a new file under
   `supabase/` or an addition to `schema.sql`) that schedules all five functions at the cadence each
   one's header comment already specifies (`versus-timeout` frequent, `notify-streak-risk` hourly,
   `notify-season-end` a few times daily, `weekly-cohort-rollover` weekly). The SQL itself is code
   the agent can write and test against a local/staging project; *running* it against the production
   project (enabling `pg_cron`/`pg_net` extensions, executing the migration) is the hand-off.
3. **APNs delivery.** Implement the ES256 JWT signing + HTTP/2 POST in `apns.ts` that the existing
   `TODO(hand-off)` comment describes. Unit-test the JWT construction against a known-good fixture
   (don't need a real key to test the signing math). The actual `APNS_*` secrets remain a hand-off.
4. **Regression guard against the content↔code drift class of bug.** M9's raw-PPR scoring shipped
   in code weeks before the data was regenerated, and nobody noticed until a user reported it. Add
   a cheap CI check — e.g. a Python test asserting no points-based theme's assembled grade lands in
   a suspicious `[0, 100]` band, or a Swift test spot-checking a few bundled grades against known
   raw-point values — that would have caught it immediately.
5. **One-command production data push.** Confirm (or fix) that
   `python3 -m tools.ingest.main --backfill 30 --upsert --catalog` is genuinely sufficient to bring
   the live Supabase `puzzles`/`player_seasons` tables current. Document the exact command + expected
   row counts in the spec so it's a copy-paste hand-off, not a judgment call.

## Key decisions (recommend, then confirm)

- `pg_cron` scheduling lands as a SQL migration file the agent writes and the user runs — don't try
  to invoke Supabase dashboard actions the agent has no credentials for.
- The drift-guard test should be cheap and specific (a few golden values), not a broad property test
  that becomes a maintenance burden — it exists to catch *this* failure mode, not to become a second
  scoring-parity suite (that's already `test_grade.py`/`GradeFormulaTests`/`ScoringRuleTests`).

## Deliverables

- Per-format completion tracking, tested, both Home cards independently correct.
- `pg_cron` migration file scheduling all five edge functions.
- `apns.ts` JWT signing implemented and unit-tested.
- A CI/test guard against silent content↔code scoring drift.
- Spec updated: §8 open items 1, 4, 5 marked closed; the remaining hand-off (running the migration,
  injecting the real APNs key, running the production upsert) stated as a single explicit checklist.

## Verification / success criteria

- New tests: per-format completion (finishing Keep4 doesn't mark Who Am I? done, and vice versa),
  APNs JWT signing against a fixture, the drift guard.
- Screenshot: Home with one format DONE and the other still playable.
- All existing tests green.

## Hand-offs (cannot be done by the agent)

- Running the `pg_cron` migration against the live Supabase project (needs elevated DB access).
- Real APNs key material (`APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_PRIVATE_KEY`/`APNS_BUNDLE_ID`).
- Running the production data-push command (needs the service-role key).
