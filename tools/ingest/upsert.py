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
import urllib.parse
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


def _get_json(url: str, headers: dict, *, what: str, timeout: int = 60):
    """GET + decode JSON, retrying transient socket/TLS failures.

    The WRITE path was hardened against these long ago ("a matter of when, not if" — see
    `_upsert_table`), but the paginated READ helpers below were not, and a full catalog run
    makes hundreds of them: a single `TimeoutError` mid-pagination killed a ~2h run right
    after the puzzle upsert (2026-07-26), before a single catalog row was written. A GET is
    idempotent, so retrying is always safe. HTTP 4xx/5xx still fails fast — a real
    payload/permission problem can't be retried away.
    """
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers=headers, method="GET")
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            body = err.read().decode("utf-8", "ignore")
            raise RuntimeError(f"{what} failed ({err.code}): {body}") from err
        except Exception as err:  # noqa: BLE001 — transient socket/TLS/timeout
            if attempt == 3:
                raise RuntimeError(f"{what} failed after 4 attempts: {err}") from err
            time.sleep(2 ** attempt)
    raise AssertionError("unreachable")


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


def upsert_teams(rows: list[dict]) -> int:
    """Upsert club identity rows into `teams` (on_conflict on the league-qualified PK)."""
    return _upsert_table("teams", rows, conflict="sport,team_abbr,league")


def upsert_leagues(rows: list[dict]) -> int:
    """Upsert league/competition identity rows into `leagues`. Conflict includes `tier`: the key
    is (sport, league, tier) because `league` is a COUNTRY label, so a country with more than one
    division (Germany -> Bundesliga + 2. Bundesliga) needs a row per tier."""
    return _upsert_table("leagues", rows, conflict="sport,league,tier")


def fetch_existing_catalog_ids(sport: str, page_size: int = 1000) -> set[str]:
    """Every `id` already stored in `player_seasons` for `sport` — lets the daily run skip
    re-sending closed-season rows that can never change (see `main.filter_new_catalog_rows`),
    instead of resending the full ~130k-row catalog on every single run regardless of what's
    actually new.

    Pages by keyset (`order=id` + `id=gt.<last seen>`), NOT by Range/offset: a deep OFFSET
    makes Postgres walk and discard every earlier row, and once the table doubled past
    ~460k rows (the pre-collision-fix duplicate id scheme still resident), deep pages blew
    the server's statement timeout (57014) and killed the pipeline mid-run — caught live
    2026-07-14. Keyset pages are primary-key index seeks, equally fast at any depth."""
    base, key = _require_env()
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    ids: set[str] = set()
    last: str | None = None
    while True:
        query = f"select=id&sport=eq.{sport}&order=id.asc&limit={page_size}"
        if last is not None:
            query += f"&id=gt.{urllib.parse.quote(last)}"
        page = _get_json(f"{base}/rest/v1/player_seasons?{query}", headers,
                         what="player_seasons id fetch")
        # Stop on an empty page, not `len(page) < page_size` — PostgREST/Supabase silently
        # caps a single response at its own configured max (default 1000, see
        # `fetch_player_seasons`'s docstring) regardless of a larger requested `limit`, so a
        # `page_size` above that cap made every page look "short" and the loop exited after
        # page 1 every time — undercounting existing ids and defeating this function's whole
        # point (caught live: only 973/~26,000 NFL ids matched on the first production run).
        if not page:
            break
        ids.update(r["id"] for r in page)
        last = page[-1]["id"]
    return ids


def fetch_catalog_ids_missing(sport: str, column: str, page_size: int = 1000) -> set[str]:
    """Ids of stored `player_seasons` rows for `sport` whose `column` is NULL/empty — the
    set `main.filter_new_catalog_rows` treats as still-improvable (resendable) even though
    they're "already stored". Same keyset pagination as `fetch_existing_catalog_ids` and
    for the same statement-timeout reason.

    Generalized from the headshot-only version because a second column turned out to need
    exactly the same treatment: `competition` (and `league`) were NULL on ~75k stored soccer
    rows written before those columns existed, and a closed-season row is otherwise skipped
    forever. Any column the pipeline can fill in later belongs here rather than in a third
    near-identical copy of this function."""
    base, key = _require_env()
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    ids: set[str] = set()
    last: str | None = None
    while True:
        query = (f"select=id&sport=eq.{sport}&or=({column}.is.null,{column}.eq.)"
                 f"&order=id.asc&limit={page_size}")
        if last is not None:
            query += f"&id=gt.{urllib.parse.quote(last)}"
        page = _get_json(f"{base}/rest/v1/player_seasons?{query}", headers,
                         what=f"missing-{column} id fetch")
        if not page:
            break
        ids.update(r["id"] for r in page)
        last = page[-1]["id"]
    return ids


def fetch_headshot_ledger(page_size: int = 1000) -> dict[str, str]:
    """`headshot_assets.source_url` -> the value the catalog should carry for it: our Storage
    `public_url` for a rehosted photo (`ok`), or `''` for a `placeholder`/`missing` source.

    Exists because rehosting was only ever applied to the catalog *after the fact*, by
    `headshot_repoint()`, while the ingest pipeline kept writing raw third-party CDN URLs
    back over the top of it. Measured 2026-08-25: 46,936 NFL rows (35% of the sport) were
    hotlinked again despite 83,580 already sitting in Storage, because
      * a repointed placeholder is stored as `''`, which `fetch_catalog_ids_missing` counts
        as *missing*, so every run "improved" it by resending the CDN URL, and
      * career rows are in `filter_new_catalog_rows`'s unconditional `always_send` path and
        got overwritten regardless.
    The ledger is the source of truth for what a headshot should be, so the pipeline has to
    consult it at write time rather than racing a cleanup pass that runs afterwards.

    Rows with no ledger entry are absent from the dict and left untouched — a brand-new
    player's photo has not been probed yet, and guessing would be worse than hotlinking it
    for one cycle until the next `headshots.py` run classifies it."""
    base, key = _require_env()
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    out: dict[str, str] = {}
    last: str | None = None
    while True:
        query = ("select=source_url,status,public_url"
                 "&status=in.(ok,placeholder,missing)"
                 f"&order=source_url.asc&limit={page_size}")
        if last is not None:
            query += f"&source_url=gt.{urllib.parse.quote(last)}"
        page = _get_json(f"{base}/rest/v1/headshot_assets?{query}", headers,
                         what="headshot ledger fetch")
        # Empty page, not a short one — same PostgREST row-cap reason as
        # `fetch_existing_catalog_ids`.
        if not page:
            break
        for r in page:
            if r["status"] == "ok":
                if r.get("public_url"):
                    out[r["source_url"]] = r["public_url"]
            else:
                out[r["source_url"]] = ""
        last = page[-1]["source_url"]
    return out


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


def fetch_served_pairs(dates: list[str]) -> set[tuple[str, str]]:
    """Which (served_date, sport) pairs among `dates` already have a daily_puzzle.py-minted
    keep4 pick, per `puzzle_history` — the picker's own exclusive bookkeeping. Lets
    daily_puzzle.py stay idempotent per (day, sport): a retried/re-dispatched run shouldn't
    mint a second competing puzzle for a slot that already has one (two rows sharing one
    active_date makes the client's "today" pick ambiguous). Sport-scoped (not just date)
    since every sport now mints its own canonical pick each day — a date that already has
    NFL's row must still allow the other four sports to mint theirs.

    Deliberately checks `puzzle_history`, NOT `puzzles.active_date`: the latter is *also*
    stamped in bulk by main.py's `assign_active_dates` on every regular pipeline run, purely
    for archival/informational spread across the trailing window (documented as tolerant of
    multiple rows per day — Browse never reads it). Checking `puzzles` directly previously
    let an unrelated archival row's incidental active_date collision false-positive this
    check and silently skip a genuine daily mint. `puzzle_history` is written only here, so
    it can't cross-contaminate. A `served_date, sport, format` unique constraint (schema.sql)
    is the hard backstop against the underlying race this replaces (two processes both
    passing this read-then-act check before either writes) -- it turns a silent duplicate
    into a loud upsert failure instead of leaving two puzzles live for the same slot, which
    is exactly what happened once in production before this fix (see BALLIQ_SPEC.md)."""
    if not dates:
        return set()
    base, key = _require_env()
    in_list = ",".join(dates)
    endpoint = (f"{base}/rest/v1/puzzle_history?select=served_date,sport&format=eq.keep4"
                f"&served_date=in.({in_list})")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"puzzle_history lookup failed ({err.code}): {body}") from err
    return {(r["served_date"], r["sport"]) for r in rows}


def fetch_recent_theme_keys(since: str) -> dict[str, set[str]]:
    """`{sport: {theme_key, …}}` for every keep4 daily served on/after `since` (YYYY-MM-DD).

    Feeds `daily_puzzle`'s theme cooldown. The picker already excludes exact player-set
    signatures forever, but a *theme* has many signatures, so a sport with six curated themes
    re-served the same title constantly — live on 2026-08-18, baseball had served "Ace pitching
    seasons" 9 times in 23 days, and the daily-drop push names the theme, so the repetition was
    the most visible thing about the whole content pipeline. This is what lets the picker
    prefer a title the sport hasn't shown recently."""
    if not since:
        return {}
    base, key = _require_env()
    endpoint = (f"{base}/rest/v1/puzzle_history?select=sport,theme_key&format=eq.keep4"
                f"&served_date=gte.{since}")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    rows = _get_json(endpoint, headers, what="recent theme keys")
    out: dict[str, set[str]] = {}
    for r in rows:
        out.setdefault(r["sport"], set()).add(r["theme_key"])
    return out


def fetch_whoami_history() -> list[dict]:
    """Every Who Am I? pick ever served (sport, player_key, served_date) — small,
    service-role-only table (one row per day per sport), so a full pull is fine. Feeds
    daily_whoami.py's least-recently-served ranking AND its per-(date, sport) idempotency
    check in one round trip."""
    base, key = _require_env()
    endpoint = f"{base}/rest/v1/whoami_history?select=sport,player_key,served_date"
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"whoami_history fetch failed ({err.code}): {body}") from err


def upsert_whoami_history(rows: list[dict]) -> int:
    """Record daily Who Am I? picks (on_conflict=served_date,sport — re-running the same
    day's mint is a safe no-op, mirroring upsert_history's posture for keep4)."""
    return _upsert_table("whoami_history", rows, conflict="served_date,sport")


def fetch_journeyman_history() -> list[dict]:
    """Every Journeyman pick ever served — same shape, size and purpose as
    `fetch_whoami_history` (one row per day per sport), feeding daily_journeyman.py's
    least-recently-served ranking and its idempotency check in one round trip."""
    base, key = _require_env()
    endpoint = f"{base}/rest/v1/journeyman_history?select=sport,player_key,served_date"
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"journeyman_history fetch failed ({err.code}): {body}") from err


def upsert_journeyman_history(rows: list[dict]) -> int:
    """Record daily Journeyman picks (on_conflict=served_date,sport — same idempotent posture
    as `upsert_whoami_history`)."""
    return _upsert_table("journeyman_history", rows, conflict="served_date,sport")


def fetch_grid_history(since_date: str) -> list[dict]:
    """Grid combos served on/after `since_date` (sport, row_teams, col_decades) — the
    trailing-window rejection set grid.py uses to keep a freshly-minted board from
    repeating a recent team-set x decade-set verbatim."""
    base, key = _require_env()
    endpoint = (f"{base}/rest/v1/grid_history?select=sport,row_teams,col_decades"
                f"&served_date=gte.{since_date}")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"grid_history fetch failed ({err.code}): {body}") from err


def upsert_grid_axis_membership(rows: list[dict]) -> int:
    """Write stat/position axis membership (on_conflict = the full primary key, so a re-run
    after the catalog grows is a no-op for rows that already matched)."""
    return _upsert_table("grid_axis_membership", rows,
                         conflict="sport,axis_key,player_name,team_abbr,league,season_year")


def upsert_grid_history(rows: list[dict]) -> int:
    """Record newly-minted grid combos (on_conflict=served_date,sport — same idempotent
    re-run posture as the other history writers)."""
    return _upsert_table("grid_history", rows, conflict="served_date,sport")


def fetch_existing_puzzle_ids(ids: list[str]) -> set[str]:
    """Which of `ids` already exist in `puzzles`. Grid minting uses this to skip a
    (sport, date) whose row was already written — once minted for a day, a board must not
    silently shift content mid-day just because the underlying catalog changed between two
    same-day pipeline runs (merge-duplicates would happily overwrite it)."""
    if not ids:
        return set()
    base, key = _require_env()
    in_list = ",".join(urllib.parse.quote(i) for i in ids)
    endpoint = f"{base}/rest/v1/puzzles?select=id&id=in.({in_list})"
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    req = urllib.request.Request(endpoint, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            rows = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "ignore")
        raise RuntimeError(f"puzzles id lookup failed ({err.code}): {body}") from err
    return {r["id"] for r in rows}


# The Grid's column set -- the default for `fetch_player_seasons`. `league` is load-bearing
# for it, not decorative: soccer team codes are derived and collide hard across countries --
# 51 of 954 abbreviations carry rows from two different clubs, including MCI (Man City +
# Melbourne City), TOR (Torino + Toronto FC) and GAL (Galatasaray + LA Galaxy). Without it a
# single "MCI" axis accepts either club's players.
GRID_CATALOG_COLUMNS = "name,team_abbr,season_year,sport,position,stats,career,league"

# whoami_pool.py's set -- the Grid columns plus the career-span and photo fields it tiers and
# qualifies subjects on. A separate constant rather than widening the default, so The Grid's
# 79k-row soccer pull doesn't start carrying three columns it has no use for.
WHOAMI_CATALOG_COLUMNS = GRID_CATALOG_COLUMNS + ",first_year,last_year,headshot"


def fetch_player_seasons(sport: str, *, career: bool = False, page_size: int = 1000,
                         columns: str = GRID_CATALOG_COLUMNS) -> list[dict]:
    """Real season rows for `sport` from the live `player_seasons` catalog (populated by
    `--catalog`) -- used by The Grid (grid.py) and the Who Am I? pool builder
    (whoami_pool.py), which generate content directly from this already-ingested table
    instead of re-pulling raw provider data.

    Pages by **keyset** (`id > last seen`) rather than `Range`/OFFSET. Both read the same
    rows, but OFFSET makes the server walk and discard everything before the window, so cost
    climbs with depth: measured against live NFL career rows, page 1 came back in 0.6s and
    the page at offset 8000 took 4.3s, and a fetch of a bigger sport under load has hit the
    statement timeout (57014) outright. Keyset paging stays flat, and the `(sport, id)` index
    (`player_seasons_sport_id_idx`) serves it directly.

    Ordering by `id` also keeps the row set stable across calls -- without an explicit order,
    which rows land in an early page is not guaranteed stable, which would make grid.py's
    "deterministic per (sport, date)" promise fragile in practice even though the pure
    generator itself is deterministic given its input."""
    base, key = _require_env()
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    rows: list[dict] = []
    last_id = ""
    while True:
        endpoint = (f"{base}/rest/v1/player_seasons"
                    f"?select=id,{columns}"
                    f"&sport=eq.{sport}&career=eq.{str(career).lower()}"
                    f"&order=id&limit={page_size}")
        if last_id:
            endpoint += f"&id=gt.{urllib.parse.quote(last_id, safe='')}"
        # Via `_get_json` for its transient-failure retry: a catalog-wide pull is hundreds of
        # requests, and one socket blip shouldn't cost the whole run (see that docstring).
        page = _get_json(endpoint, headers, what="player_seasons fetch")
        if not page:
            break
        rows.extend(page)
        last_id = page[-1]["id"]
        if len(page) < page_size:
            break
    return rows


def fetch_teams() -> list[dict]:
    """Every `teams` row (sport, team_abbr, full_name, league). Small table -- 323 rows live
    across four sports -- so this is a single request with no paging."""
    base, key = _require_env()
    endpoint = (f"{base}/rest/v1/teams?select=sport,team_abbr,full_name,league&order=sport,team_abbr")
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}
    return _get_json(endpoint, headers, what="teams")
