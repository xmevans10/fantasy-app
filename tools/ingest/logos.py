"""Rehost club/league logos into the public Supabase Storage `team-logos` bucket.

Why rehost instead of hotlinking the source (ESPN) CDN: at "every club, every league" scale a
hotlink depends on the source keeping every lower-division crest live under a stable URL scheme
forever. Rehosting gives us one stable public URL per logo (our bucket), fetched once. The
bucket is world-readable (logos render in guest sessions), created in schema.sql.

`rehost()` is idempotent: an object already present under its content-stable key is not
re-uploaded (a HEAD check), so a re-run of --teams is cheap and a transient source 404 never
overwrites a good logo with nothing.

Uses the same SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY env as upsert.py (service-role required
to write to Storage; anon can only read a public bucket).
"""
from __future__ import annotations

import os
import time
import urllib.error
import urllib.request

BUCKET = "team-logos"


def _require_env() -> tuple[str, str]:
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise RuntimeError("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set to rehost logos")
    return url.rstrip("/"), key


def public_url(base: str, key: str) -> str:
    """The stable world-readable URL for an object already in the public bucket."""
    return f"{base}/storage/v1/object/public/{BUCKET}/{key}"


def _object_exists(base: str, service_key: str, key: str) -> bool:
    """HEAD the object; 200 = present (skip re-upload), 404/400 = absent. Any other error is
    treated as absent so the upload path runs and surfaces the real failure there."""
    req = urllib.request.Request(
        f"{base}/storage/v1/object/{BUCKET}/{key}",
        headers={"apikey": service_key, "Authorization": f"Bearer {service_key}"},
        method="HEAD",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return 200 <= resp.status < 300
    except urllib.error.HTTPError:
        return False
    except Exception:  # noqa: BLE001 — treat transient errors as "not present, try upload"
        return False


# Wikimedia throttles bulk image fetches with HTTP 429. `_download` used to swallow that as
# "no logo" like any other error, which made a large rehost lose images NON-DETERMINISTICALLY:
# measured 2026-09-06, an F1 run resolved 138 crest sources but only rehosted 124, and a
# different subset failed on each attempt. A 429 is the one failure here that is purely a
# function of how fast we asked, so it is the one worth retrying.
_RETRY_STATUSES = frozenset({429, 503})
_DOWNLOAD_ATTEMPTS = 3


def _download(source_url: str) -> tuple[bytes, str] | None:
    """Fetch the source image. Returns (bytes, content_type) or None on any failure — a missing
    source logo must degrade to "no logo" (null column), never abort the whole --teams build.

    Retries on 429/503 with backoff (see `_RETRY_STATUSES`): everything else — a 404, a bad
    host, a timeout — is a real absence and returns None on the first try, because retrying it
    would just slow a large build down for no gain.
    """
    for attempt in range(_DOWNLOAD_ATTEMPTS):
        try:
            req = urllib.request.Request(source_url, headers={"User-Agent": "balliq-ingest/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = resp.read()
                ctype = resp.headers.get("Content-Type", "image/png")
            return (data, ctype) if data else None
        except urllib.error.HTTPError as err:
            if err.code not in _RETRY_STATUSES or attempt == _DOWNLOAD_ATTEMPTS - 1:
                return None
            time.sleep(1.5 * 2 ** attempt)
        except Exception:  # noqa: BLE001
            return None
    return None


def _upload(base: str, service_key: str, key: str, data: bytes, content_type: str) -> None:
    """Upload bytes to the bucket under `key` (upsert=true so a re-run overwrites cleanly)."""
    req = urllib.request.Request(
        f"{base}/storage/v1/object/{BUCKET}/{key}",
        data=data,
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": content_type,
            "x-upsert": "true",
            "Cache-Control": "public, max-age=31536000, immutable",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"logo upload failed ({err.code}) for {key}: {body}") from err


def rehost(source_url: str | None, key: str) -> str | None:
    """Ensure the logo at `source_url` lives in the bucket under `key`; return its public URL.

    Returns None (→ a null logo_url) when there is no source URL or the source can't be
    fetched — the client renders the abbr/color fallback for a null logo, so a missing crest is
    never a broken image. Idempotent: skips the download+upload entirely if the object already
    exists (a warm re-run of --teams does no network writes)."""
    if not source_url:
        return None
    base, service_key = _require_env()
    if _object_exists(base, service_key, key):
        return public_url(base, key)
    fetched = _download(source_url)
    if fetched is None:
        return None
    data, content_type = fetched
    _upload(base, service_key, key, data, content_type)
    return public_url(base, key)


def _safe_segment(s: str) -> str:
    """One path segment of a Storage object key: lowercase, ASCII-alphanumerics kept, everything
    else (spaces, punctuation, AND non-ASCII letters) collapsed to '-'. The ASCII restriction is
    load-bearing: `str.isalnum()` is Unicode-aware and returns True for accented letters, so a
    club/league label like "São Paulo" or "Fenerbahçe" would otherwise leave an 'ã'/'ç' in the
    key — which urllib then can't encode into the (ASCII-only) HTTP request line, aborting the
    whole rehost with a UnicodeEncodeError."""
    return "".join(c if (c.isascii() and c.isalnum()) else "-" for c in s.lower()).strip("-") or "_"


def logo_key(sport: str, league: str, team_abbr: str) -> str:
    """Content-stable object key. League-qualified so post-collision same-code clubs don't
    overwrite each other's crest (BRO Blackburn vs BROA Brisbane)."""
    return f"{_safe_segment(sport)}/{_safe_segment(league.strip() or '_')}/{_safe_segment(team_abbr)}.png"


def league_logo_key(sport: str, league: str) -> str:
    return f"{_safe_segment(sport)}/_leagues/{_safe_segment(league)}.png"
