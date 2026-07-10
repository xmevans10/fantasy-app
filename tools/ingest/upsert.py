"""Upsert puzzle rows into the Supabase `puzzles` table via PostgREST.

Writes require the **service_role** key (RLS gives no write policy to anon).
Uses `Prefer: resolution=merge-duplicates` with `on_conflict=id` so re-running
the pipeline updates rows in place — deterministic, no duplicates.
"""
from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request

from .assemble import PuzzleRow


def _require_env() -> tuple[str, str]:
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise RuntimeError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set to upsert"
        )
    return url.rstrip("/"), key


def _upsert_table(table: str, payload: list[dict], *, conflict: str = "id",
                  batch_size: int = 200) -> int:
    """Upsert raw dict rows into `table` (on_conflict=`conflict`). Returns count sent."""
    base, key = _require_env()
    endpoint = f"{base}/rest/v1/{table}?on_conflict={conflict}"
    headers = {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "Prefer": "resolution=merge-duplicates,return=minimal",
    }
    sent = 0
    for start in range(0, len(payload), batch_size):
        batch = payload[start:start + batch_size]
        data = json.dumps(batch).encode("utf-8")
        req = urllib.request.Request(endpoint, data=data, headers=headers, method="POST")
        # A 130k-row catalog push is ~670 serial requests — long enough that one transient
        # network/TLS blip (hit live 2026-07-10: SSLV3_ALERT_BAD_RECORD_MAC mid-push) is a
        # matter of when, not if. Each batch is independently idempotent
        # (merge-duplicates), so retrying just the failed batch is always safe. HTTP 4xx
        # (a real payload/permission problem) still fails fast — retrying can't fix it.
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    resp.read()
                break
            except urllib.error.HTTPError as err:
                body = err.read().decode("utf-8", "ignore")
                raise RuntimeError(f"{table} upsert failed ({err.code}): {body}") from err
            except Exception as err:  # noqa: BLE001 — transient socket/TLS/timeout
                if attempt == 3:
                    raise RuntimeError(f"{table} upsert failed after 4 attempts: {err}") from err
                time.sleep(1.5 * 2 ** attempt)
        sent += len(batch)
    return sent


def upsert(rows: list[PuzzleRow]) -> int:
    """Upsert puzzle rows into `puzzles`."""
    payload = [
        {"id": r.id, "sport": r.sport, "format": r.format,
         "content": r.content, "active_date": r.active_date}
        for r in rows
    ]
    return _upsert_table("puzzles", payload)


def upsert_catalog(rows: list[dict]) -> int:
    """Upsert real player-seasons into `player_seasons` (the creation catalog)."""
    return _upsert_table("player_seasons", rows)


def upsert_grid(rows: list[dict]) -> int:
    """Upsert Grid puzzle rows (already-shaped id/sport/format/content/active_date dicts —
    unlike `upsert()`, which takes `PuzzleRow` objects) into `puzzles`."""
    return _upsert_table("puzzles", rows)


def fetch_history_signatures() -> set[str]:
    """Every puzzle signature ever served by the daily novel-puzzle picker (see
    daily_puzzle.py) — a small, service-role-only table, so a full pull is fine."""
    base, key = _require_env()
    endpoint = f"{base}/rest/v1/puzzle_history?select=signature"
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"puzzle_history fetch failed ({err.code}): {body}") from err
    return {r["signature"] for r in rows}


def upsert_history(rows: list[dict]) -> int:
    """Record newly-served puzzle signatures into `puzzle_history` (on_conflict=signature —
    a signature can never legitimately recur, but re-running the same day's pick is safe)."""
    return _upsert_table("puzzle_history", rows, conflict="signature")


def fetch_served_dates(dates: list[str]) -> set[str]:
    """Which of `dates` already have a daily_puzzle.py-minted keep4 pick, per `puzzle_history`
    (served_date) — the picker's own exclusive bookkeeping. Lets daily_puzzle.py stay
    idempotent per day: a retried/re-dispatched run shouldn't mint a second competing puzzle
    for a date that already has one (two rows sharing one active_date makes the client's
    "today" pick ambiguous).

    Deliberately checks `puzzle_history`, NOT `puzzles.active_date`: the latter is *also*
    stamped in bulk by main.py's `assign_active_dates` on every regular pipeline run, purely
    for archival/informational spread across the trailing window (documented as tolerant of
    multiple rows per day — Browse never reads it). Checking `puzzles` directly previously
    let an unrelated archival row's incidental active_date collision false-positive this
    check and silently skip a genuine daily mint. `puzzle_history` is written only here, so
    it can't cross-contaminate. A `served_date, format` unique constraint (schema.sql) is the
    hard backstop against the underlying race this replaces (two processes both passing this
    read-then-act check before either writes) -- it turns a silent duplicate into a loud
    upsert failure instead of leaving two puzzles live for the same day, which is exactly
    what happened once in production before this fix (see BALLIQ_SPEC.md)."""
    if not dates:
        return set()
    base, key = _require_env()
    in_list = ",".join(dates)
    endpoint = (f"{base}/rest/v1/puzzle_history?select=served_date&format=eq.keep4"
                f"&served_date=in.({in_list})")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"puzzle_history lookup failed ({err.code}): {body}") from err
    return {r["served_date"] for r in rows}


def fetch_player_seasons(sport: str, *, career: bool = False, page_size: int = 1000) -> list[dict]:
    """Real season rows for `sport` from the live `player_seasons` catalog (populated by
    `--catalog`) -- used by The Grid (grid.py), which generates content directly from this
    already-ingested table instead of re-pulling raw provider data.

    Paginates via the `Range` header rather than trusting a `limit` query param alone --
    PostgREST caps a single response at its own configured max (Supabase's default is 1000
    rows) regardless of a larger `limit`, so a naive single request silently truncates any
    sport with >1000 rows (NFL has ~14k). Also orders by `id` for a stable row set across
    calls -- without an explicit order, which rows land in an early page is not guaranteed
    stable, which would make grid.py's "deterministic per (sport, date)" promise fragile in
    practice even though the pure generator itself is deterministic given its input."""
    base, key = _require_env()
    endpoint = (f"{base}/rest/v1/player_seasons"
                f"?select=name,team_abbr,season_year,sport,position,stats,career"
                f"&sport=eq.{sport}&career=eq.{str(career).lower()}&order=id")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    rows: list[dict] = []
    start = 0
    while True:
        page_headers = {**headers, "Range-Unit": "items", "Range": f"{start}-{start + page_size - 1}"}
        req = urllib.request.Request(endpoint, headers=page_headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                page = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            body = err.read().decode("utf-8", "ignore")
            raise RuntimeError(f"player_seasons fetch failed ({err.code}): {body}") from err
        rows.extend(page)
        if len(page) < page_size:
            break
        start += page_size
    return rows
