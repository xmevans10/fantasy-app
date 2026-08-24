"""Rehost player headshots into the public Supabase Storage `player-headshots` bucket.

Why this exists (measured 2026-08-24, before any of it was written):

`player_seasons.headshot` is 100% non-null, which is exactly why the coverage problem was
invisible for so long — the *column* is full, the *images* are not. Every headshot was
hotlinked to one of five third-party CDNs, and each one fails differently:

  * `img.mlbstatic.com` — all 90,092 baseball rows carry Cloudinary's
    `d_people:generic:headshot:silo` default-image parameter, so a player with no photo
    returns **200 OK with a grey silhouette**. Probed without that parameter, only 35% of
    baseball sources have a real photo (6% for players who last played before 1970).
  * `a.espncdn.com` — 404s on retired players. Michael Jordan (`full/1035.png`) was a 404;
    NBA players who last played 1990–2009 were at 7.8% coverage.
  * `upload.wikimedia.org` — rate-limits us: 26 of 40 probes returned 429. Tennis is 100%
    Wikimedia, so tennis headshots were at the mercy of a throttle.
  * `static.www.nfl.com` / `a.espncdn.com` — serve full-resolution source images (NFL median
    373 KB, NBA 232 KB) for circles the app draws at ~40 pt.

That last point is why this tool fixes latency as well as coverage. `AppImagePipeline
.transformed()` (BallIQ/DesignSystem/RemoteImage.swift) only rewrites **Supabase Storage**
URLs to the render/transform endpoint, so a hotlinked headshot could never be resized
server-side. Rehosting puts every headshot behind that endpoint with no client change —
verified on this project: a 40,228-byte object serves as 18,806 bytes at width=192.

Design notes:

  * **Sharded.** `--shard i/N` claims a disjoint slice by `sha1(source_url)`, so N processes
    run in parallel without coordinating. Ledger writes are per-source-url upserts, so two
    shards racing on the same row (they can't, but if the sharding were ever changed) would
    converge rather than corrupt.
  * **Idempotent.** Shards claim only rows still marked `pending`, so a re-run picks up
    exactly what an interrupted run left behind. Re-running is cheap and safe.
  * **Placeholders are not rehosted.** Copying MLB's grey silo into our own bucket would make
    a permanent asset out of a non-photo. They're recorded as `placeholder` and the row's
    headshot is cleared, so the app's designed initials-on-team-colors fallback takes over —
    which looks intentional in a way a silhouette never does.
  * **stdlib at runtime.** Pillow is imported lazily and only for `--resize`; without it the
    tool uploads originals and the transform endpoint still handles delivery sizing. Matches
    the optional-dependency contract in requirements.txt.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

from .main import load_dotenv

BUCKET = "player-headshots"
UA = "balliq-ingest/1.0 (+https://github.com/xmevans10/fantasy-app)"

# Cloudinary's "if the real asset is missing, serve this instead" parameter. Stripping it
# turns MLB's silent silhouette into an honest 404, which is the only way to tell whether a
# baseball player actually has a photo.
MLB_SILO_RE = re.compile(r",?d_people:generic:headshot:silo:current\.png")

# cdn.nba.com answers 200 for unknown person ids with a ~12 KB generic stub; real headshots
# run 180–280 KB. Anything at or under this is treated as a placeholder, not a photo.
NBA_STUB_MAX_BYTES = 20_000

# A source that returns fewer bytes than this isn't a usable headshot regardless of host.
MIN_REAL_BYTES = 2_000


def _require_env() -> tuple[str, str]:
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise RuntimeError(
            "SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set to rehost headshots"
        )
    return url.rstrip("/"), key


# ---------------------------------------------------------------- PostgREST helpers


def _rest(base: str, key: str, path: str, *, method: str = "GET", body=None,
          extra_headers: dict | None = None, timeout: int = 90):
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    headers.update(extra_headers or {})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{base}/rest/v1/{path}", data=data,
                                 headers=headers, method=method)
    last = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as err:
            raise RuntimeError(
                f"{method} {path} failed ({err.code}): "
                f"{err.read().decode('utf-8', 'ignore')[:400]}"
            ) from err
        except Exception as exc:  # noqa: BLE001 — transient socket/TLS, GET+upsert are idempotent
            last = exc
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"{method} {path} failed after retries: {last}")


def claim_pending(base: str, key: str, shard: int, shards: int,
                  sports: list[str] | None, limit: int | None) -> list[tuple[str, str]]:
    """Claim this shard's slice of the work queue.

    The queue is `headshot_assets` itself, seeded server-side with every distinct non-Storage
    source (see the headshot_assets_work_queue migration). Each row carries a stable
    `shard` bucket (0..63), so N parallel processes take buckets where `bucket % N == i` and
    never overlap without talking to each other.

    This replaced a version that paginated player_seasons per shard: 18 concurrent deep-OFFSET
    scans over 380k rows produced 57014 statement timeouts past ~offset 30000. Here the query
    is an index lookup on (status, shard) against a 44k-row table.
    """
    buckets = [b for b in range(64) if b % shards == shard]
    filt = f"&shard=in.({','.join(str(b) for b in buckets)})"
    if sports:
        filt += f"&sport=in.({','.join(sports)})"
    out: list[tuple[str, str]] = []
    page, offset = 1000, 0
    while True:
        rows = _rest(base, key,
                     f"headshot_assets?select=source_url,sport&status=eq.pending{filt}"
                     f"&order=source_url&limit={page}&offset={offset}")
        if not rows:
            break
        out.extend((r["source_url"], r.get("sport") or "") for r in rows)
        offset += page
        if len(rows) < page or (limit and len(out) >= limit):
            break
    return out[:limit] if limit else out


# ---------------------------------------------------------------- image fetch / classify


def _get(url: str, timeout: int = 30) -> tuple[int, bytes, str]:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read(), resp.headers.get("Content-Type", "image/png")
    except urllib.error.HTTPError as err:
        return err.code, b"", ""
    except Exception:  # noqa: BLE001
        return -1, b"", ""


def fetch_real_image(source_url: str) -> tuple[str, bytes, str, str]:
    """Fetch `source_url`, distinguishing a real photo from a served placeholder.

    Returns (status, data, content_type, note) where status is ok/placeholder/missing/error.
    """
    probe = MLB_SILO_RE.sub("", source_url)
    stripped = probe != source_url

    code, data, ctype = _get(probe)

    if code == 429:
        # Wikimedia throttles bursts. Back off once — this is the whole reason tennis
        # headshots were unreliable in the app, and a shard that ignores it just re-creates
        # the problem on our side.
        time.sleep(5)
        code, data, ctype = _get(probe)

    if code in (403, 404):
        # For MLB this is the honest answer the silo parameter was hiding: no photo exists.
        return ("placeholder" if stripped else "missing"), b"", "", f"http {code}"
    if code == -1 or not (200 <= code < 300):
        return "error", b"", "", f"http {code}"
    if len(data) < MIN_REAL_BYTES:
        return "placeholder", b"", "", f"{len(data)}B too small"
    if "cdn.nba.com" in probe and len(data) <= NBA_STUB_MAX_BYTES:
        return "placeholder", b"", "", f"nba stub {len(data)}B"
    return "ok", data, ctype or "image/png", ""


def maybe_resize(data: bytes, content_type: str, max_px: int) -> tuple[bytes, str]:
    """Downscale to `max_px` on the long edge. Lazy Pillow import per requirements.txt's
    optional-dependency contract — without Pillow this is a no-op and the Storage transform
    endpoint still sizes on delivery, just from a larger stored original."""
    try:
        from PIL import Image  # noqa: PLC0415 — deliberately lazy
    except ImportError:
        return data, content_type
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
        if max(img.size) <= max_px:
            return data, content_type
        img.thumbnail((max_px, max_px), Image.LANCZOS)
        out = io.BytesIO()
        if img.mode in ("RGBA", "LA", "P"):
            img = img.convert("RGBA")
            img.save(out, format="PNG", optimize=True)
            return out.getvalue(), "image/png"
        img.convert("RGB").save(out, format="JPEG", quality=88, optimize=True)
        return out.getvalue(), "image/jpeg"
    except Exception:  # noqa: BLE001 — a source we can't decode is uploaded untouched
        return data, content_type


# ---------------------------------------------------------------- storage


def object_key(sport: str, source_url: str, content_type: str) -> str:
    """Content-addressed by source URL: stable across runs, dedupes the many rows that share
    one source, and a changed source naturally lands on a new key instead of overwriting."""
    ext = "jpg" if "jpeg" in content_type else "png" if "png" in content_type else "img"
    digest = hashlib.sha1(source_url.encode()).hexdigest()[:20]
    return f"{sport or 'unknown'}/{digest}.{ext}"


def public_url(base: str, key: str) -> str:
    return f"{base}/storage/v1/object/public/{BUCKET}/{key}"


def upload(base: str, service_key: str, key: str, data: bytes, content_type: str) -> None:
    req = urllib.request.Request(
        f"{base}/storage/v1/object/{BUCKET}/{key}",
        data=data,
        headers={
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": content_type,
            "x-upsert": "true",
            # Matches the team-logos contract: fetched once per install, never revalidated.
            "Cache-Control": "public, max-age=31536000, immutable",
        },
        method="POST",
    )
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                resp.read()
                return
        except urllib.error.HTTPError as err:
            raise RuntimeError(
                f"upload failed ({err.code}) for {key}: "
                f"{err.read().decode('utf-8', 'ignore')[:300]}"
            ) from err
        except Exception:  # noqa: BLE001
            if attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))


# ---------------------------------------------------------------- NBA id backfill

# `player_seasons` stores ESPN athlete ids for NBA, and ESPN simply has no headshot for most
# retired players: Michael Jordan's own id 404s, and players who last played 1990–2009 sat at
# 7.8% coverage. The NBA's own CDN *does* have them — verified 2026-08-24 for Jordan (893),
# Iverson (947) and Reggie Miller (397) — but it is keyed on NBA person ids, which we don't
# store. This bridges the two by name, using the static historical roster the nba_api project
# publishes (6,424 players, including everyone pre-2000).
NBA_STATIC_URL = ("https://raw.githubusercontent.com/swar/nba_api/master/"
                  "src/nba_api/stats/library/data.py")
NBA_CDN = "https://cdn.nba.com/headshots/nba/latest/1040x760/{pid}.png"

_SUFFIXES = {"jr", "sr", "ii", "iii", "iv", "v"}


def normalize_name(name: str) -> str:
    """Fold a display name to a match key: accents stripped, punctuation dropped, generational
    suffix removed. 'Nenê'/'Nene' and 'Gary Payton II'/'Gary Payton' have to collide, or the
    bridge misses exactly the players it exists to find."""
    import unicodedata
    folded = unicodedata.normalize("NFKD", name)
    folded = "".join(c for c in folded if not unicodedata.combining(c))
    folded = re.sub(r"[^a-zA-Z ]", " ", folded).lower()
    parts = [p for p in folded.split() if p and p not in _SUFFIXES]
    return " ".join(parts)


def nba_person_ids() -> dict[str, int]:
    """normalized name -> NBA person id, from the published static roster."""
    req = urllib.request.Request(NBA_STATIC_URL, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as resp:
        source = resp.read().decode("utf-8", "ignore")
    # rows look like: [893, "Jordan", "Michael", "Michael Jordan", False],
    rows = re.findall(r"\[(\d+),\s*\"[^\"]*\",\s*\"[^\"]*\",\s*\"([^\"]+)\",\s*(?:True|False)\]",
                      source)
    index: dict[str, int] = {}
    for pid, full in rows:
        key = normalize_name(full)
        # First id wins: the list is roughly chronological and a duplicate name is far more
        # likely to be a modern namesake than the historical player we're missing a photo for.
        index.setdefault(key, int(pid))
    return index


def nba_backfill(workers: int, max_px: int, limit: int | None, dry_run: bool) -> int:
    """Fill NBA rows the ledger left with no usable photo, from cdn.nba.com.

    Run this AFTER --repoint: repoint clears every source proven to be a placeholder or a 404
    to '', so "headshot is empty" is then an unambiguous statement of "this player has no
    photo", and the backfill can target exactly those without risking a good image.
    """
    load_dotenv()
    base, key = _require_env()

    print("[nba-backfill] loading NBA person-id roster …", flush=True)
    ids = nba_person_ids()
    print(f"[nba-backfill] {len(ids)} historical NBA players indexed", flush=True)

    names: set[str] = set()
    page, offset = 1000, 0
    while True:
        rows = _rest(base, key,
                     f"player_seasons?select=name&sport=eq.nba&headshot=eq."
                     f"&order=name&limit={page}&offset={offset}")
        if not rows:
            break
        names.update(r["name"] for r in rows if r.get("name"))
        offset += page
        if len(rows) < page:
            break

    targets = []
    unmatched = 0
    for name in sorted(names):
        pid = ids.get(normalize_name(name))
        if pid is None:
            unmatched += 1
            continue
        targets.append((name, pid))
    if limit:
        targets = targets[:limit]
    print(f"[nba-backfill] {len(names)} photo-less names, {len(targets)} matched to a person "
          f"id, {unmatched} unmatched", flush=True)
    if dry_run or not targets:
        return 0

    counts = {"ok": 0, "stub": 0, "missing": 0, "error": 0}

    def work(item: tuple[str, int]) -> str:
        name, pid = item
        url = NBA_CDN.format(pid=pid)
        status, data, ctype, _ = fetch_real_image(url)
        if status != "ok":
            return "stub" if status == "placeholder" else status
        data, ctype = maybe_resize(data, ctype, max_px)
        okey = object_key("nba", url, ctype)
        try:
            upload(base, key, okey, data, ctype)
            target = public_url(base, okey)
            record(base, key, [{"source_url": url, "sport": "nba", "status": "ok",
                                "storage_key": okey, "public_url": target,
                                "bytes": len(data), "note": f"nba-backfill:{name}",
                                "shard": 0}])
            # Only rows still proven photo-less are touched — never one holding a good image.
            _rest(base, key,
                  f"player_seasons?sport=eq.nba&headshot=eq."
                  f"&name=eq.{urllib.parse.quote(name, safe='')}",
                  method="PATCH", body={"headshot": target},
                  extra_headers={"Prefer": "return=minimal"})
        except Exception:  # noqa: BLE001 — one player must not kill the pass
            return "error"
        return "ok"

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for i, outcome in enumerate(pool.map(work, targets), 1):
            counts[outcome] = counts.get(outcome, 0) + 1
            if i % 200 == 0:
                print(f"[nba-backfill] {i}/{len(targets)} {counts}", flush=True)
    print(f"[nba-backfill] DONE {counts}", flush=True)
    return 0


# ---------------------------------------------------------------- name-based backfills

# Wikipedia is a markedly better source than any league CDN for players the leagues have
# forgotten. Measured 2026-08-24 on 44 photo-less baseball players: Wikipedia had 75% of
# them, including 10/10 who last played 1940–69 and 64% of the pre-1940 group — exactly the
# era where MLB's own CDN collapses to 6%.
#
# `providers.wikimedia.headshot` is reused rather than reimplemented: it already does the
# confident-match check that keeps a same-named politician's portrait out of the catalog
# (a wrong face is worse than no face), caches for 90 days, and paces itself under
# Wikipedia's anonymous rate limit.
_WIKI_CONTEXT = {
    "baseball": "baseball",
    "nba": "basketball",
    "nfl": "football",
    "soccer": "football",
    "tennis": "tennis",
}


def _photoless_names(base: str, key: str, sport: str) -> list[str]:
    """Distinct names in `sport` with no usable photo left.

    Reads rows already cleared to '' — which is what --repoint leaves behind for every source
    proven to be a placeholder or a 404 — so this is an unambiguous "has no photo" set and a
    backfill can never overwrite a good image.
    """
    names: set[str] = set()
    page, offset = 1000, 0
    while True:
        rows = _rest(base, key,
                     f"player_seasons?select=name&sport=eq.{sport}&headshot=eq."
                     f"&order=name&limit={page}&offset={offset}")
        if not rows:
            break
        names.update(r["name"] for r in rows if r.get("name"))
        offset += page
        if len(rows) < page:
            break
    return sorted(names)


def _adopt(base: str, key: str, sport: str, name: str, source: str,
           max_px: int, note: str) -> str:
    """Fetch a candidate source, rehost it, and point this player's photo-less rows at it."""
    status, data, ctype, _ = fetch_real_image(source)
    if status != "ok":
        return "stub" if status == "placeholder" else status
    data, ctype = maybe_resize(data, ctype, max_px)
    okey = object_key(sport, source, ctype)
    try:
        upload(base, key, okey, data, ctype)
        target = public_url(base, okey)
        record(base, key, [{"source_url": source, "sport": sport, "status": "ok",
                            "storage_key": okey, "public_url": target, "bytes": len(data),
                            "note": f"{note}:{name}", "shard": 0}])
        _rest(base, key,
              f"player_seasons?sport=eq.{sport}&headshot=eq."
              f"&name=eq.{urllib.parse.quote(name, safe='')}",
              method="PATCH", body={"headshot": target},
              extra_headers={"Prefer": "return=minimal"})
    except Exception:  # noqa: BLE001 — one player must not kill the pass
        return "error"
    return "ok"


def wiki_backfill(sports: list[str] | None, workers: int, max_px: int,
                  limit: int | None, dry_run: bool) -> int:
    """Fill photo-less rows from Wikipedia. Run AFTER --repoint (and after --nba-backfill,
    which has a better source for NBA specifically)."""
    from .providers.wikimedia import headshot as wiki_headshot

    load_dotenv()
    base, key = _require_env()
    targets = sports or sorted(_WIKI_CONTEXT)

    for sport in targets:
        context = _WIKI_CONTEXT.get(sport)
        if not context:
            print(f"[wiki-backfill] no context for {sport}, skipping", flush=True)
            continue
        names = _photoless_names(base, key, sport)
        if limit:
            names = names[:limit]
        print(f"[wiki-backfill] {sport}: {len(names)} photo-less names", flush=True)
        if dry_run:
            continue

        # Resolution is sequential on purpose: wikimedia.headshot paces itself between
        # UNCACHED calls, and running it from a thread pool would defeat that pacing and
        # get us 429-throttled — the same failure that made tennis unreliable to begin with.
        resolved: list[tuple[str, str]] = []
        for i, name in enumerate(names, 1):
            url = wiki_headshot(name, context=context)
            if url:
                resolved.append((name, url))
            if i % 250 == 0:
                print(f"[wiki-backfill] {sport}: resolved {i}/{len(names)}, "
                      f"{len(resolved)} hits", flush=True)
        print(f"[wiki-backfill] {sport}: {len(resolved)}/{len(names)} resolved "
              f"({100 * len(resolved) / max(len(names), 1):.0f}%)", flush=True)

        counts: dict[str, int] = {}
        with ThreadPoolExecutor(max_workers=workers) as pool:
            outcomes = pool.map(
                lambda item: _adopt(base, key, sport, item[0], item[1], max_px, "wiki"),
                resolved)
            for outcome in outcomes:
                counts[outcome] = counts.get(outcome, 0) + 1
        print(f"[wiki-backfill] {sport} DONE {counts}", flush=True)
    return 0


def warm_transforms(workers: int, limit: int | None) -> int:
    """Pre-generate the 192 px rendition for every rehosted headshot.

    Storage's render endpoint resizes on FIRST request and caches the result immutably — so
    without this, the first player to open a given puzzle pays ~1-2s per uncached headshot
    while the rendition is generated. Measured on one 8-card board: 1.94s cold vs 0.10-0.27s
    warm. Doing it here means no real user is ever the first requester.

    192 px is the only size worth warming: every headshot call site in the app draws at <=48 pt,
    which resolves to that single bucket (AppImagePipeline.buckets).
    """
    load_dotenv()
    base, key = _require_env()

    urls: list[str] = []
    page, offset = 1000, 0
    while True:
        rows = _rest(base, key,
                     f"headshot_assets?select=public_url&status=eq.ok&public_url=not.is.null"
                     f"&order=public_url&limit={page}&offset={offset}")
        if not rows:
            break
        urls.extend(r["public_url"] for r in rows if r.get("public_url"))
        offset += page
        if len(rows) < page:
            break
    if limit:
        urls = urls[:limit]
    print(f"[warm-transforms] {len(urls)} renditions to generate", flush=True)

    def warm(url: str) -> bool:
        rendered = url.replace("/storage/v1/object/public/",
                               "/storage/v1/render/image/public/")
        rendered += "?width=192&height=192&resize=contain&quality=80"
        code, _, _ = _get(rendered, timeout=45)
        return 200 <= code < 300

    done = failed = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for ok_ in pool.map(warm, urls):
            done += 1
            failed += 0 if ok_ else 1
            if done % 2000 == 0:
                print(f"[warm-transforms] {done}/{len(urls)} ({failed} failed)", flush=True)
    print(f"[warm-transforms] DONE {done} generated, {failed} failed", flush=True)
    return 0


def detect_dupes(threshold: int, dry_run: bool) -> int:
    """Find stock "no photo" graphics that every other check waves through.

    Three sources now have been caught serving a placeholder at HTTP 200: MLB's grey silo,
    cdn.nba.com's 12 KB stub, and — found only by LOOKING at a contact sheet of what we had
    actually stored — NFL's generic helmet graphic, which is a normal-sized PNG and therefore
    sailed past both the status check and the byte floor. It accounted for 7,222 of ~13,400
    distinct NFL sources: 71.7% of the sport.

    The signal that catches all of them: a real photograph is unique, a placeholder is
    byte-identical across every player it's served for. So any (sport, bytes) group larger
    than `threshold` is a stock graphic, not a photo. This runs on the ledger alone — no
    re-downloading — because `bytes` was recorded at upload time.
    """
    load_dotenv()
    base, key = _require_env()

    rows = _rest(base, key,
                 "rpc/headshot_dupe_groups", method="POST", body={"min_count": threshold})
    if not rows:
        print("[detect-dupes] no duplicate groups found", flush=True)
        return 0
    total = 0
    for group in rows:
        sport, size, count = group["sport"], group["bytes"], group["n"]
        print(f"[detect-dupes] {sport}: {count} sources are byte-identical at {size} B "
              f"-> placeholder", flush=True)
        total += count
        if not dry_run:
            _rest(base, key,
                  f"headshot_assets?sport=eq.{sport}&bytes=eq.{size}&status=eq.ok",
                  method="PATCH",
                  body={"status": "placeholder", "note": f"stock graphic ({size}B, x{count})",
                        "public_url": None},
                  extra_headers={"Prefer": "return=minimal"})
    print(f"[detect-dupes] {'would mark' if dry_run else 'marked'} {total} sources as "
          f"placeholder", flush=True)
    return 0


# ---------------------------------------------------------------- driver


def record(base: str, key: str, rows: list[dict]) -> None:
    if not rows:
        return
    _rest(base, key, "headshot_assets?on_conflict=source_url", method="POST", body=rows,
          extra_headers={"Prefer": "resolution=merge-duplicates,return=minimal"})


def run(shard: int, shards: int, *, sports: list[str] | None, limit: int | None,
        workers: int, max_px: int, dry_run: bool) -> int:
    load_dotenv()
    base, key = _require_env()

    print(f"[headshots] shard {shard}/{shards} — claiming from queue …", flush=True)
    mine = claim_pending(base, key, shard, shards, sports, limit)
    print(f"[headshots] shard {shard}/{shards}: {len(mine)} to process", flush=True)
    if dry_run or not mine:
        return 0

    counts: dict[str, int] = {}
    pending: list[dict] = []
    processed = 0

    def work(item: tuple[str, str]) -> dict:
        source_url, sport = item
        status, data, ctype, note = fetch_real_image(source_url)
        # Every row carries the identical key set: PostgREST rejects a bulk insert whose
        # objects differ in shape ("All object keys must match", PGRST102).
        row = {"source_url": source_url, "sport": sport, "status": status,
               "note": note or None, "bytes": len(data) or None,
               "storage_key": None, "public_url": None}
        if status != "ok":
            return row
        data, ctype = maybe_resize(data, ctype, max_px)
        okey = object_key(sport, source_url, ctype)
        try:
            upload(base, key, okey, data, ctype)
        except Exception as exc:  # noqa: BLE001 — one bad object must not kill the shard
            return {**row, "status": "error", "note": str(exc)[:200], "bytes": None}
        row.update({"storage_key": okey, "public_url": public_url(base, okey),
                    "bytes": len(data)})
        return row

    with ThreadPoolExecutor(max_workers=workers) as pool:
        for row in pool.map(work, mine):
            counts[row["status"]] = counts.get(row["status"], 0) + 1
            pending.append(row)
            processed += 1
            if len(pending) >= 200:
                record(base, key, pending)
                pending = []
                print(f"[headshots] shard {shard}: {processed}/{len(mine)} {counts}",
                      flush=True)
    record(base, key, pending)
    print(f"[headshots] shard {shard}/{shards} DONE {processed} processed {counts}",
          flush=True)
    return 0


def repoint(dry_run: bool) -> int:
    """Point `player_seasons.headshot` at our rehosted copies, and clear the ones the ledger
    proved are placeholders or dead so the app falls back to its designed treatment rather
    than rendering a grey silo or a broken image.

    Loops in batches: ~292k rows is far past Postgres's statement timeout in one UPDATE
    (the first version counted fine and then died with 57014 on the write).
    """
    load_dotenv()
    base, key = _require_env()
    if dry_run:
        stats = _rest(base, key, "rpc/headshot_repoint", method="POST",
                      body={"dry_run": True})
        print(f"[headshots] repoint (dry run) -> {stats}", flush=True)
        return 0

    total_pointed = total_cleared = 0
    stalls = 0
    while True:
        try:
            stats = _rest(base, key, "rpc/headshot_repoint_batch", method="POST",
                          body={"batch_size": 1000}, timeout=180)
        except RuntimeError as exc:
            # 57014 under concurrent shard writes is transient contention, not a dead end —
            # the whole point of batching is that a failed batch costs one batch, so back off
            # and keep going rather than abandoning a partially-repointed catalog.
            if "57014" not in str(exc) or stalls >= 40:
                raise
            stalls += 1
            print(f"[headshots] repoint batch timed out ({stalls}), backing off …", flush=True)
            time.sleep(5 * min(stalls, 6))
            continue
        pointed = int(stats.get("repointed") or 0)
        cleared = int(stats.get("cleared") or 0)
        total_pointed += pointed
        total_cleared += cleared
        if pointed == 0 and cleared == 0:
            break
        print(f"[headshots] repoint … +{pointed} pointed, +{cleared} cleared "
              f"(running {total_pointed}/{total_cleared})", flush=True)
    print(f"[headshots] repoint DONE repointed={total_pointed} cleared={total_cleared}",
          flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shard", default="0/1",
                        help="i/N — process only sources whose hash falls in shard i of N. "
                             "Run N of these in parallel; they never overlap.")
    parser.add_argument("--sports", default="",
                        help="comma-separated sports to limit to (default: all)")
    parser.add_argument("--limit", type=int, default=None)
    parser.add_argument("--workers", type=int, default=12)
    parser.add_argument("--max-px", type=int, default=512,
                        help="downscale long edge before upload (needs Pillow; no-op without)")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--detect-dupes", action="store_true",
                        help="mark byte-identical stock graphics (NFL's helmet, etc.) as "
                             "placeholders so --repoint clears them")
    parser.add_argument("--dupe-threshold", type=int, default=25)
    parser.add_argument("--warm-transforms", action="store_true",
                        help="pre-generate the 192px rendition for every rehosted headshot so "
                             "no real user is the first requester (run AFTER --repoint)")
    parser.add_argument("--wiki-backfill", action="store_true",
                        help="fill photo-less rows from Wikipedia (run AFTER --repoint); "
                             "75%% hit rate on the baseball players MLB's CDN lacks")
    parser.add_argument("--reset-errors", action="store_true",
                        help="flip 'error' rows back to 'pending' so a re-run retries them "
                             "(transfermarkt and Wikimedia both throttle under load)")
    parser.add_argument("--nba-backfill", action="store_true",
                        help="fill photo-less NBA rows from cdn.nba.com by name->person id "
                             "(run AFTER --repoint)")
    parser.add_argument("--repoint", action="store_true",
                        help="after shards finish: rewrite player_seasons.headshot from the ledger")
    args = parser.parse_args(argv)

    if args.reset_errors:
        load_dotenv()
        base, key = _require_env()
        _rest(base, key, "headshot_assets?status=eq.error", method="PATCH",
              body={"status": "pending"}, extra_headers={"Prefer": "return=minimal"})
        print("[headshots] error rows reset to pending", flush=True)
        return 0
    if args.repoint:
        return repoint(args.dry_run)
    if args.nba_backfill:
        return nba_backfill(args.workers, args.max_px, args.limit, args.dry_run)
    if args.detect_dupes:
        return detect_dupes(args.dupe_threshold, args.dry_run)
    if args.warm_transforms:
        return warm_transforms(args.workers, args.limit)
    if args.wiki_backfill:
        sports = [x.strip() for x in args.sports.split(",") if x.strip()] or None
        return wiki_backfill(sports, args.workers, args.max_px, args.limit, args.dry_run)

    try:
        index, total = (int(x) for x in args.shard.split("/"))
    except ValueError:
        parser.error("--shard must look like i/N, e.g. 0/8")
    if not (0 <= index < total):
        parser.error(f"--shard index {index} out of range for {total} shards")

    sports = [s.strip() for s in args.sports.split(",") if s.strip()] or None
    return run(index, total, sports=sports, limit=args.limit, workers=args.workers,
               max_px=args.max_px, dry_run=args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
