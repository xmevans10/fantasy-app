"""Shared Wikipedia headshot resolution — one summary-API lookup per player, cached for
90 days, kept only when the page confidently matches the sport (a same-named
politician's photo would be worse than no photo).

Extracted from `tennis_atp.py` when the NFL/NBA historical providers needed the same
mechanism; the cache key format (`wiki_summary_<slug>.json`) is unchanged so the tennis
sweep's existing cache keeps working.

Politeness contract (learned live): burst-calling Wikipedia's REST API with no delay
gets the client 429-throttled within ~20 requests, after which every call crawls
through retry backoff. `WIKI_DELAY` between UNCACHED calls stays comfortably under
their anonymous limit; cached hits skip the sleep entirely.
"""
from __future__ import annotations

import time
import urllib.parse

from ..models import slug
from .http import fetch_json, is_cached

_SUMMARY_URL = "https://en.wikipedia.org/api/rest_v1/page/summary/{title}"
_TTL_HOURS = 24 * 90
WIKI_DELAY = 0.35


def headshot(name: str, *, context: str, title_suffixes: tuple[str, ...] = ()) -> str:
    """A real Wikipedia thumbnail for this person, or '' when there's no confident match.
    `context` is the lowercase word that must appear in the page's description/extract
    (e.g. "tennis", "basketball", "football") for the photo to be trusted.
    `title_suffixes` are Wikipedia's disambiguation forms tried when the plain title
    misses — e.g. ("American football",) finds "James Wilder (American football)" when
    the bare "James Wilder" page is the actor (a real case the M16 bundle guard caught)."""
    for suffix in ("", *title_suffixes):
        page = f"{name} ({suffix})" if suffix else name
        if shot := _lookup(page, context):
            return shot
    return ""


def _lookup(page: str, context: str) -> str:
    title = urllib.parse.quote(page.replace(" ", "_"))
    cache_key = f"wiki_summary_{slug(page)}.json"
    was_cached = is_cached(cache_key, _TTL_HOURS)
    try:
        data = fetch_json(_SUMMARY_URL.format(title=title),
                          headers={"User-Agent": "balliq-ingest (data pipeline; contact: xmevans10@gmail.com)"},
                          cache_key=cache_key,
                          ttl_hours=_TTL_HOURS)
    except Exception:  # noqa: BLE001 — 404/disambiguation/network: just no photo
        if not was_cached:
            time.sleep(WIKI_DELAY)
        return ""
    if not was_cached:
        time.sleep(WIKI_DELAY)
    blob = " ".join([data.get("description") or "", data.get("extract") or ""]).lower()
    if context not in blob:
        return ""
    return ((data.get("thumbnail") or {}).get("source")) or ""
