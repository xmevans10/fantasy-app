"""The headshot work queue has to GROW, and nothing in the pipeline used to make it.

`headshot_assets` is the queue: `claim_pending` reads it and never looks at the catalog, which
is what made the sharded worker fast (it replaced 18 concurrent deep-OFFSET scans over 380k
rows that died with 57014 statement timeouts). The cost of that design is that the queue is a
closed set unless something explicitly adds to it, and for as long as it existed, nothing did.
Every stage of `headshot-backfill.yml` reprocesses sources the ledger already knows — the
shards claim `pending` rows, the `--*-backfill` flags start from `player_seasons.headshot = ''`
— so a player discovered after the last hand-seeding was invisible to all of them, and to
`headshot_coverage_summary` as well, because a row that is not in the ledger is not outstanding
work either. 7,590 such sources were drained by hand on 2026-09-07; nothing stopped the next
batch accumulating behind them.

Parsed with the stdlib rather than PyYAML, matching this pipeline's no-third-party-deps
contract (see `test_fresh_drop_workflow.py` and `providers/http.py`).
"""
from __future__ import annotations

import re
from pathlib import Path

from tools.ingest import headshots

ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github" / "workflows" / "headshot-backfill.yml"
MIGRATION = ROOT / "supabase" / "migrations" / "0026_headshot_queue_seed.sql"
SCHEMA = ROOT / "supabase" / "schema.sql"


def _sql() -> str:
    """The migration with its `--` commentary stripped, so a test asserting what the SQL does
    cannot be satisfied (or broken) by a comment that merely talks about it."""
    return "\n".join(re.sub(r"--.*$", "", line)
                     for line in MIGRATION.read_text(encoding="utf-8").splitlines())


# ── The RPC contract ──────────────────────────────────────────────────────────

def test_seed_calls_the_rpc_and_reports_what_it_enqueued(monkeypatch, capsys):
    calls: list[tuple] = []

    def fake_rest(base, key, path, method="GET", body=None, **kw):
        calls.append((path, method, body))
        return {"dry_run": False, "candidates": 7590, "enqueued": 7590}

    monkeypatch.setattr(headshots, "load_dotenv", lambda: None)
    monkeypatch.setattr(headshots, "_require_env", lambda: ("https://x", "k"))
    monkeypatch.setattr(headshots, "_rest", fake_rest)

    assert headshots.seed_queue(dry_run=False) == 0
    assert calls == [("rpc/headshot_queue_seed", "POST", {"dry_run": False})]
    assert "7590" in capsys.readouterr().out


def test_a_dry_run_seed_writes_nothing(monkeypatch):
    seen: list[dict] = []
    monkeypatch.setattr(headshots, "load_dotenv", lambda: None)
    monkeypatch.setattr(headshots, "_require_env", lambda: ("https://x", "k"))
    monkeypatch.setattr(headshots, "_rest",
                        lambda *a, body=None, **kw: seen.append(body) or
                        {"dry_run": True, "candidates": 12, "enqueued": 0})
    headshots.seed_queue(dry_run=True)
    assert seen == [{"dry_run": True}]


def test_seed_queue_is_reachable_from_the_cli(monkeypatch):
    """`--seed-queue` has to short-circuit before the shard parsing, or it would need a
    meaningless `--shard` argument to run at all."""
    called: list[bool] = []
    monkeypatch.setattr(headshots, "seed_queue", lambda dry_run: called.append(dry_run) or 0)
    assert headshots.main(["--seed-queue"]) == 0
    assert called == [False]


# ── The migration ─────────────────────────────────────────────────────────────

def test_the_seed_is_idempotent_and_never_reopens_a_resolved_source():
    """A source already in the ledger carries a status that was EARNED (ok / placeholder /
    missing / error). Re-seeding on every pass is only safe because it cannot overwrite one."""
    sql = _sql()
    assert "on conflict (source_url) do nothing" in sql
    assert "do update" not in sql


def test_the_seed_skips_sources_that_are_already_ours_or_proven_absent():
    sql = _sql()
    # Rehosted copies are the finished state, not work.
    assert "/storage/v1/object/public/player-headshots/" in sql
    # '' is `headshot_repoint`'s proven "there is no photo for this player", not a source.
    assert "coalesce(p.headshot, '') <> ''" in sql


def test_seeded_rows_get_a_shard_bucket_in_range():
    """`claim_pending` partitions work by `shard % shards`. A row seeded without one would be
    claimed by no worker at all and sit pending forever."""
    sql = _sql()
    assert "% 64" in sql
    assert re.search(r"insert into headshot_assets \([^)]*\bshard\b", sql)


def test_the_migration_is_mirrored_into_schema_sql():
    """schema.sql is this repo's source of truth for production DDL; a migration that only
    exists as a migration is drift waiting to happen (CLAUDE.md)."""
    assert "headshot_queue_seed" in SCHEMA.read_text(encoding="utf-8")


# ── The workflow wiring ───────────────────────────────────────────────────────

def _jobs(text: str) -> dict[str, str]:
    """`{job name: its block}` — two-space-indented keys under `jobs:`."""
    body = text.split("\njobs:\n", 1)[1]
    names = [(m.group(1), m.start()) for m in re.finditer(r"^  ([a-z0-9-]+):$", body, re.M)]
    out = {}
    for i, (name, start) in enumerate(names):
        end = names[i + 1][1] if i + 1 < len(names) else len(body)
        out[name] = body[start:end]
    return out


def test_the_workflow_seeds_the_queue_before_anything_claims_from_it():
    jobs = _jobs(WORKFLOW.read_text(encoding="utf-8"))
    assert "--seed-queue" in jobs["seed-queue"]
    # Ordering is the whole point: the shards claim from a queue that must already be complete.
    assert "needs: seed-queue" in jobs["plan"]
    assert "needs: [plan, reset-errors]" in jobs["fetch"]


def test_seeding_lands_inside_the_convergence_loops_before_snapshot():
    """`converge` re-dispatches only while outstanding work is FALLING. Seeding after the
    snapshot would make a pass that enqueues 5,000 and resolves 4,000 read as a regression and
    stop the loop, which is the opposite of what a growing queue needs."""
    text = WORKFLOW.read_text(encoding="utf-8")
    jobs = _jobs(text)
    assert "before_remaining" in jobs["plan"], "the snapshot still lives in `plan`"
    assert text.index("\n  seed-queue:") < text.index("\n  plan:")
