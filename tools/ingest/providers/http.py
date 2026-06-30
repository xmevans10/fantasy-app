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


def fetch_text(url: str, *, cache_key: str | None = None, ttl_hours: float = 24.0) -> str:
    """GET a URL as text, caching the body on disk under .cache/.

    `ttl_hours <= 0` disables caching (always refetch). Used for the large, slow
    nflverse season CSVs so repeated runs don't re-download.
    """
    if cache_key and ttl_hours > 0:
        path = _cache_path(cache_key)
        if path.exists() and (time.time() - path.stat().st_mtime) < ttl_hours * 3600:
            return path.read_text(encoding="utf-8")

    body = _get(url)

    if cache_key and ttl_hours > 0:
        path = _cache_path(cache_key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return body


def fetch_json(url: str, *, headers: dict[str, str] | None = None,
               cache_key: str | None = None, ttl_hours: float = 24.0) -> dict:
    if cache_key and ttl_hours > 0:
        path = _cache_path(cache_key)
        if path.exists() and (time.time() - path.stat().st_mtime) < ttl_hours * 3600:
            return json.loads(path.read_text(encoding="utf-8"))

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
