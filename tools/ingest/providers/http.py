"""Tiny stdlib HTTP + on-disk cache helper.

The pipeline deliberately avoids third-party deps (requests/pandas/pyarrow) so it
runs unchanged in CI and locally with only Python 3.11+. nflverse publishes CSV
variants of every dataset, so `csv` from the stdlib is all we need.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from pathlib import Path

CACHE_DIR = Path(__file__).resolve().parent.parent / ".cache"
_USER_AGENT = "balliq-ingest/1.0 (+https://github.com/balliq)"


def _cache_path(key: str) -> Path:
    return CACHE_DIR / key


def evict_current_season(now_year: int) -> int:
    """Delete cache entries that can go stale mid-season, so the next fetch is guaranteed
    fresh: anything keyed by the current or previous calendar year (a season can span both —
    NBA 2025-26, soccer 2025/26), plus the per-athlete ESPN NBA stat files, which aren't
    year-keyed but hold live current-season lines. Everything else (historical years,
    player-id lookups) is immutable and keeps its cache. Returns the number of files removed.
    Used by the weekly in-season refresh (`--evict-current-season`)."""
    if not CACHE_DIR.exists():
        return 0
    markers = (str(now_year), str(now_year - 1))
    removed = 0
    for path in CACHE_DIR.iterdir():
        if not path.is_file():
            continue
        if any(m in path.name for m in markers) or path.name.startswith("espn_nba_stats_"):
            path.unlink()
            removed += 1
    return removed


def is_cached(cache_key: str | None, ttl_hours: float = 24.0) -> bool:
    """Would `fetch_text`/`fetch_json` serve this from disk right now, with no network call?
    Callers that rate-limit-delay themselves between requests (mlb_stats, espn_nba) use this
    to skip the delay on a cache hit — the delay only exists to protect the live API, so
    paying it on every loop iteration regardless of whether a request actually happened
    turns a warm-cache run into just-as-slow-as-cold for no reason."""
    if not cache_key or ttl_hours <= 0:
        return False
    path = _cache_path(cache_key)
    return path.exists() and (time.time() - path.stat().st_mtime) < ttl_hours * 3600


def fetch_text(url: str, *, cache_key: str | None = None, ttl_hours: float = 24.0) -> str:
    """GET a URL as text, caching the body on disk under .cache/.

    `ttl_hours <= 0` disables caching (always refetch). Used for the large, slow
    nflverse season CSVs so repeated runs don't re-download.
    """
    if is_cached(cache_key, ttl_hours):
        return _cache_path(cache_key).read_text(encoding="utf-8")

    body = _get(url)

    if cache_key and ttl_hours > 0:
        path = _cache_path(cache_key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return body


def fetch_json(url: str, *, headers: dict[str, str] | None = None,
               cache_key: str | None = None, ttl_hours: float = 24.0) -> dict:
    if is_cached(cache_key, ttl_hours):
        return json.loads(_cache_path(cache_key).read_text(encoding="utf-8"))

    body = _get(url, headers=headers)

    if cache_key and ttl_hours > 0:
        path = _cache_path(cache_key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return json.loads(body)


def _get(url: str, *, headers: dict[str, str] | None = None, retries: int = 4) -> str:
    req = urllib.request.Request(url)
    req.add_header("User-Agent", _USER_AGENT)
    for name, value in (headers or {}).items():
        req.add_header(name, value)

    last_err: Exception | None = None
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read().decode("utf-8")
        except urllib.error.HTTPError as err:
            # 429 (rate limited) IS retryable with backoff; other 4xx (e.g. balldontlie
            # 401 missing key) won't fix on retry, so fail fast.
            if err.code != 429 and 400 <= err.code < 500:
                raise
            last_err = err
            # Honor an explicit Retry-After (seconds) when the server sends one.
            retry_after = err.headers.get("Retry-After") if err.headers else None
            if retry_after and retry_after.strip().isdigit():
                time.sleep(min(float(retry_after), 30))
                continue
        except urllib.error.URLError as err:
            last_err = err
        time.sleep(min(1.5 * 2 ** attempt, 30))  # exponential backoff, capped
    raise RuntimeError(f"GET failed after {retries} attempts: {url}") from last_err
