"""Upsert puzzle rows into the Supabase `puzzles` table via PostgREST.

Writes require the **service_role** key (RLS gives no write policy to anon).
Uses `Prefer: resolution=merge-duplicates` with `on_conflict=id` so re-running
the pipeline updates rows in place — deterministic, no duplicates.
"""
from __future__ import annotations

import json
import os
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
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                resp.read()
        except urllib.error.HTTPError as err:
            body = err.read().decode("utf-8", "ignore")
            raise RuntimeError(f"{table} upsert failed ({err.code}): {body}") from err
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


def fetch_todays_keep4_id(active_date: str) -> str | None:
    """The id of the keep4 row already minted for `active_date`, if any. Lets daily_puzzle.py
    stay idempotent per day — a retried/re-dispatched run shouldn't mint a second competing
    puzzle for a date that already has one (two rows sharing one active_date makes the
    client's "today" pick ambiguous)."""
    base, key = _require_env()
    endpoint = (f"{base}/rest/v1/puzzles?select=id&format=eq.keep4"
                f"&active_date=eq.{active_date}&limit=1")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"puzzles lookup failed ({err.code}): {body}") from err
    return rows[0]["id"] if rows else None
