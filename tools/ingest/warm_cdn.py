"""Pre-warm the image CDN so no player ever pays for a cold transform.

Supabase's render endpoint is *generated on demand and then cached forever*
(``cache-control: public, max-age=31536000, immutable``). Measured 2026-08-28 against this
project:

    cold  (first request for a given url+size)   1.4 - 1.8 s
    warm  (cf-cache-status: HIT)                 0.06 - 0.18 s

Each ``(image, width)`` pair is its own cache entry, so with ~41k headshots the cold path is not
a rare edge — it is what the *first* player to see any given card gets, every time content
changes. That is a second of a blank card in a timed Puzzle Blitz round.

This module walks the images the app actually requests and fetches each one at each bucket the
client uses, exactly as the client would (same transform parameters, same ``Accept`` header), so
the CDN has the rendition ready before anybody asks for it. It writes nothing and mutates
nothing; the only side effect is a warmer cache.

Run after any content push:

    python -m tools.ingest.warm_cdn --scope puzzles      # what the dailies/blitz serve
    python -m tools.ingest.warm_cdn --scope teams        # crests (also bundled, so rarely needed)
    python -m tools.ingest.warm_cdn --scope catalog      # the whole 41k catalog, hours

``--scope puzzles`` is the one that matters and takes a few minutes; it covers every frozen
board the app can serve today.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# Must match `AppImagePipeline.buckets` in BallIQ/DesignSystem/RemoteImage.swift. A size warmed
# here that the client never asks for is wasted work, and a size the client asks for that is not
# warmed here still costs somebody 1.5 s — the two lists have to agree.
BUCKETS = (192, 384)

# Must match `AppImagePipeline.acceptHeader`. Content negotiation means the PNG and the WebP
# rendition are *different cache entries*: warming without this header would fill the one the app
# never requests.
ACCEPT = "image/webp,image/avif,image/*;q=0.8,*/*;q=0.5"

STORAGE_MARKER = "/storage/v1/object/public/"
RENDER_MARKER = "/storage/v1/render/image/public/"


def _env() -> tuple[str, str]:
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, ".env")
    values: dict[str, str] = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line and not line.strip().startswith("#"):
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip().strip('"')
    url = values.get("SUPABASE_URL") or os.environ.get("SUPABASE_URL", "")
    key = values.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not url or not key:
        sys.exit("warm_cdn: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not found in tools/ingest/.env")
    return url.rstrip("/"), key


def _rest(base: str, key: str, path: str) -> list[dict]:
    req = urllib.request.Request(
        f"{base}/rest/v1/{path}",
        headers={"apikey": key, "Authorization": f"Bearer {key}"},
    )
    with urllib.request.urlopen(req, timeout=120) as response:
        return json.load(response)


def _sql_urls(base: str, key: str, scope: str) -> set[str]:
    """Every Storage-hosted image URL the given scope can put on screen."""
    urls: set[str] = set()
    if scope in ("puzzles", "all"):
        # Frozen board content — the set the dailies, the archive and Blitz draw from.
        for fmt in ("keep4", "journeyman"):
            rows = _rest(base, key, f"puzzles?select=content&format=eq.{fmt}&limit=5000")
            for row in rows:
                content = row.get("content") or {}
                if fmt == "keep4":
                    for player in content.get("players") or []:
                        if player.get("headshot"):
                            urls.add(player["headshot"])
                elif content.get("headshot"):
                    urls.add(content["headshot"])
    if scope in ("teams", "all"):
        for row in _rest(base, key, "teams?select=logo_url&limit=1000"):
            if row.get("logo_url"):
                urls.add(row["logo_url"])
    if scope in ("catalog", "all"):
        # Paged: the catalog is ~41k distinct photos and PostgREST caps a page at 1000.
        offset, page = 0, 1000
        while True:
            rows = _rest(
                base, key,
                f"player_seasons?select=headshot&headshot=not.is.null"
                f"&order=headshot&limit={page}&offset={offset}")
            if not rows:
                break
            for row in rows:
                if row.get("headshot"):
                    urls.add(row["headshot"])
            offset += page
            if len(rows) < page:
                break
    # Only Storage objects have a render endpoint. Cloudinary (the league CDNs) resizes on their
    # own edge and needs no warming from us; everything else has no transform at all.
    return {u for u in urls if STORAGE_MARKER in u}


def _render_url(source: str, size: int) -> str:
    """Byte-identical to `AppImagePipeline.supabaseRender`, or the warm lands on the wrong key."""
    return (source.replace(STORAGE_MARKER, RENDER_MARKER)
            + f"?width={size}&height={size}&resize=contain&quality=80")


class _Stats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.hit = self.miss = self.failed = self.bytes = 0

    def record(self, cache_status: str, size: int, ok: bool) -> None:
        with self.lock:
            if not ok:
                self.failed += 1
                return
            self.bytes += size
            if cache_status.upper().startswith("HIT"):
                self.hit += 1
            else:
                self.miss += 1


def _warm_one(url: str, stats: _Stats, retries: int = 5) -> None:
    request = urllib.request.Request(url, headers={"Accept": ACCEPT})
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                body = response.read()
                stats.record(response.headers.get("cf-cache-status", ""), len(body), True)
                return
        except urllib.error.HTTPError as error:
            # 429 is expected: this is a burst of requests at an edge that is deliberately
            # rate-limited. Back off rather than giving up — a skipped image is a cold transform
            # for a real player later, which is the whole thing we are here to prevent.
            if error.code in (429, 500, 502, 503, 504) and attempt < retries - 1:
                time.sleep(1.5 * (attempt + 1))
                continue
            stats.record("", 0, False)
            return
        except Exception:
            if attempt < retries - 1:
                time.sleep(1.0 * (attempt + 1))
                continue
            stats.record("", 0, False)
            return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--scope", default="puzzles",
                        choices=["puzzles", "teams", "catalog", "all"])
    parser.add_argument("--workers", type=int, default=6,
                        help="parallel requests; the edge starts 429ing above ~12")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    base, key = _env()
    sources = _sql_urls(base, key, args.scope)
    targets = [_render_url(source, size) for source in sorted(sources) for size in BUCKETS]
    print(f"[warm_cdn] scope={args.scope}: {len(sources)} images x {len(BUCKETS)} buckets "
          f"= {len(targets)} renditions")
    if args.dry_run:
        for target in targets[:5]:
            print("  ", target)
        return 0

    stats, started = _Stats(), time.time()
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for index, _ in enumerate(pool.map(lambda t: _warm_one(t, stats), targets), start=1):
            if index % 250 == 0:
                print(f"  {index}/{len(targets)}  hit={stats.hit} cold={stats.miss} "
                      f"failed={stats.failed}  {time.time() - started:.0f}s")

    elapsed = time.time() - started
    print(f"[warm_cdn] done in {elapsed:.0f}s — {stats.hit} already warm, {stats.miss} newly "
          f"rendered, {stats.failed} failed, {stats.bytes / 1024 / 1024:.1f} MB pulled")
    # A failure here is not fatal to a content push: the image still works, it is just cold for
    # whoever sees it first.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
