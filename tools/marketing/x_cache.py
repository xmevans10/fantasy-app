"""On-disk TTL cache for X reads.

X bills per **post returned** (~$0.0052 each, measured 2026-09-22 from `GET /2/usage/tweets`:
962 reads against $5 of credits). An uncached polling read is therefore real money, so a
read-then-cache pattern applies here for the same reason the ingest providers use one: never pay
twice for an answer that has not changed.

Keys are caller-defined strings; the cache is a flat JSON file under `build/` (gitignored). Reads
are best-effort: a corrupt or missing file degrades to a miss, never an error.
"""
from __future__ import annotations

import json
import time

from . import brand

PATH = brand.ROOT / "build" / "x-read-cache.json"


def get(key: str, ttl: float):
    try:
        data = json.loads(PATH.read_text())
    except (FileNotFoundError, ValueError):
        return None
    entry = data.get(key)
    if not entry or (time.time() - entry.get("t", 0)) > ttl:
        return None
    return entry.get("v")


def put(key: str, value) -> None:
    try:
        data = json.loads(PATH.read_text())
    except (FileNotFoundError, ValueError):
        data = {}
    data[key] = {"t": time.time(), "v": value}
    PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        PATH.write_text(json.dumps(data))
    except OSError:
        pass                                    # cache is an optimisation, never a failure
