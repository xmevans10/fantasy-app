"""PGA Tour season stats — ESPN's public golf core API (keyless, `sports.core.api.espn.com`).

Probed live 2026-09-26: `site.api.espn.com/apis/site/v2/sports/golf/pga/...` (the shape used
by other sports' `site.api.espn.com` sweeps) 403s for golf specifically, but the underlying
`sports.core.api.espn.com` core API is open and carries real per-season aggregates:

    GET .../leagues/pga/seasons/{year}/types/2/leaders?limit=250
        -> categories[officialAmount].leaders: every golfer who won money that season (the
           natural "played a real season" cohort — no MIN_EVENTS-style guess needed), each
           with a direct `statistics` ref (no id reconstruction).
    GET .../leagues/pga/seasons/{year}/types/2/athletes/{id}/statistics
        -> splits.categories[0].stats: the full season line (events, wins, top10s, cutsMade,
           officialAmount, scoringAverage, cupPoints, ...) in ONE call.
    GET .../athletes/{id}?lang=en&region=us
        -> displayName, headshot.href (a.espncdn.com/i/headshots/golf/players/full/{id}.png —
           exactly the M16-contract URL pattern the brief predicted), flag.href (nationality).

Season coverage confirmed 2001-2026 (the core API's own `seasons` list stops at 2001; older
years 404). This is shallower than F1 (1950-) or hockey (1917-) but deeper than tennis's
seed-only ceiling before M18's match sweeps, and — unlike rugby (M31 §1) — the source has
real per-golfer, per-season stats, so golf ships as a first-class live provider rather than a
curated seed.

**Pagination (fixed 2026-09-27):** the money-list `leaders` endpoint silently caps at
whatever `limit=` is requested, with NO `count`/`pageCount` metadata and a broken `offset`
(passing `offset=250` returns the same top slice again, not the next page) — there is no
real pagination on this endpoint, just a bigger single ask. Verified live: 2015 has 636
entries; the original `limit=250` silently dropped everyone ranked 251-636, which is most of
a full year's field. `_LEADERS_LIMIT` now asks for far more than any season has ever fielded,
and `refresh()` asserts the response isn't sitting exactly at that cap (which would mean the
real list grew past it and needs raising, not silently truncating again).

**Unofficial-event correction (fixed 2026-09-27):** ESPN's season `wins`/`topTenFinishes`
double-count small-field EXHIBITIONS that pay real money but earn no official PGA Tour credit
— Jordan Spieth's 2015 season shows 6 wins/16 top-10s here; the official record is 5/15,
and the extra one is the 2014-12-04 Hero World Challenge (an 18-player, no-cut invitational).
Verified two ways this couldn't be caught by a single cheap signal:
- The event's own EMBEDDED `competitors[].earnings` field is NOT a reliable official/unofficial
  signal by itself — the very same always-unofficial Hero World Challenge shows it as `0.0` in
  some years and a real nonzero payout in others (ESPN evidently backfills actual prize money
  there in some seasons). The AUTHORITATIVE signal is the winner's own per-event `statistics`
  sub-resource, which carries a distinct `officialAmount` field that is `0.0` for every
  unofficial win and `> 0` for every official one — this is what `_winner_official_amount`
  reads, from inside `_find_unofficial_events`.
- A pure `winner earnings == 0` check would also false-positive on a genuinely OFFICIAL event
  with a data gap: the 2015 Barbasol Championship (an opposite-field event, real FedEx points)
  has a corrupted competitor list in this API for that one season — garbage sequential ids
  (1, 2, 3...) instead of real ESPN athlete ids, a malformed `$ref` host (`v2/spade/golf/...`
  instead of `v2/sports/golf/...`), and an all-zero stat line for its nominal "winner". Field
  SIZE is the fix: every real PGA Tour event (even the smallest opposite-field ones) fields
  70+ players, while every actual unofficial exhibition (Hero World Challenge chief among them)
  fields under 25 — `_MAX_EXHIBITION_FIELD` gates the expensive per-event check to fields small
  enough that a real tournament can never be misclassified, corrupted record or not. A
  corrupted small-field record that can't produce a clean signal (no competitor's status
  resolves to finish position "1") is left alone rather than guessed at.
`events` (tournamentsPlayed) is decremented for every entrant of a confirmed-unofficial event
(matches Spieth's 26 -> 25 official starts); `wins`/`top10s` are decremented using each
entrant's REAL finish position (ties-safe — read from the competitor's own `status`, not
list order, which the Barbasol case proved isn't trustworthy either). `cuts_made` is
deliberately NOT touched: every confirmed-unofficial event checked here is a no-cut field
(verified live — no competitor in Hero World Challenge ever carries a `STATUS_CUT` status),
so there is no cut for the counter to have double-credited in the first place.

Modelling (a golfer-season on a tour, PGA Tour only — see the M-golf brief §"Modelling"):
- position is the single value "Golfer" (like tennis "Player", F1 "Driver") — no positional
  stat families.
- `team_abbr` is the golfer's nationality code (parsed from the `flag` image filename, e.g.
  ".../countries/500/eng.png" -> "ENG"), mirroring tennis's country-as-team_abbr convention.
  No clubs exist in golf, so this sport carries no Journeyman entry and is absent from
  `grid_axes.TEAM_MOBILE_SPORTS`.
- `majors` (major wins that season) is deliberately NOT stored: the season-stat blob has no
  per-tournament breakdown, so deriving "won a major" would need a second, much larger,
  per-event pull this sweep doesn't do. Don't invent a stat the source doesn't really carry.
- `scoring_avg` is lower-is-better (like ERA/GAA) — `grade.py`'s `golf_fantasy` scale gives it
  a NEGATIVE per-unit coefficient rather than inverting anything structurally, the same
  mechanism hockey's goals-against uses.
- Headshots satisfy the M16 contract directly from the source (no Wikimedia fallback needed,
  same as hockey/F1): a golfer with no `headshot.href` on their athlete record is dropped
  entirely rather than shipped photo-less.

Same split as every other provider here: a network-heavy `refresh()` writing a committed CSV
(`data/golf_seasons.csv`) and a stdlib-only `load_seasons()`.

Run:  python -m tools.ingest.providers.golf_pga  [--from 2001 --to 2025]
"""
from __future__ import annotations

import argparse
import csv
import re
import time
from pathlib import Path

from ..models import RawSeason
from .http import fetch_json, is_cached

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "golf_seasons.csv"

_LEADERS_URL = ("https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/"
                "{year}/types/2/leaders?limit={limit}")
_ATHLETE_URL = "https://sports.core.api.espn.com/v2/sports/golf/athletes/{id}?lang=en&region=us"
_EVENTS_URL = ("https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/"
               "{year}/types/2/events?limit=200")

# The `leaders` endpoint has no real pagination (no count/pageCount, and `offset=` is a no-op —
# verified live, it returns the same top slice again), just a bigger single `limit=`. 636 is
# the largest season seen (2015); this asks for far more than any season has ever fielded, and
# `refresh()` asserts the response isn't sitting exactly at the cap (which would mean raise it).
_LEADERS_LIMIT = 2000

# The core API's own `seasons` collection: 2001 is the earliest year that resolves (2000 and
# earlier 404 — verified live), 2026 is the current/most-recently-completed season as of this
# sweep. MAX_YEAR stops one short of that: 2026's PGA Tour season (FedEx Cup playoffs finish
# in August) reads as essentially final by the 2026-09-26 probe date, but "essentially" is not
# "confirmed", and every other sport's committed sweep in this pipeline stops at a season with
# no ambiguity left (tennis excludes its fork's partial in-progress year for the same reason).
MIN_YEAR = 2001
MAX_YEAR = 2025

# A real PGA Tour season, not a one-or-two-start cameo on a sponsor exemption. 10 events is
# generous relative to a full ~20-25 event season while still excluding pure noise rows.
MIN_EVENTS = 10

# Every real PGA Tour field (even the smallest opposite-field events) runs 70+ players; every
# actual unofficial exhibition (Hero World Challenge chief among them) runs under 25. This gates
# the expensive per-event official/unofficial check to fields small enough that a real
# tournament can never be misclassified — including one with a corrupted competitor record for
# that season (verified live: the 2015 Barbasol Championship, a real official event, but its
# 80-player field here is nowhere near this line regardless of that data gap).
_MAX_EXHIBITION_FIELD = 30
# How many list-order entries get a `status` lookup when hunting for the real winner / building
# the top-10 set inside a confirmed-unofficial event. Small fields here top out around 24
# entrants, so this comfortably covers the whole field, including ties spilling past 10th.
_EXHIBITION_SCAN_DEPTH = 25

# Documented reference point for `scoring_margin` (see `grade.py`'s `golf_fantasy` comment):
# roughly the long-run full-field PGA Tour scoring average. Not sourced per-season (ESPN's
# per-athlete blob has no field-average row to read), so it is a fixed constant rather than a
# fetched one — the same kind of documented approximation `career.py`'s module docstring flags
# for OBP's denominator. It only affects the DERIVED grading term; `scoring_avg` itself is
# always the real per-player number ESPN reports.
BASELINE_SCORING_AVG = 71.0

CSV_FIELDS = ["name", "athlete_id", "country", "season_year", "events", "wins", "top10s",
              "cuts_made", "earnings", "scoring_avg", "fedex_points", "headshot"]

# Politeness delay between UNCACHED per-athlete calls — ESPN's core API is keyless and has
# tolerated the F1/hockey sweeps' request volumes with no throttling observed, but a small
# pause is cheap insurance against becoming the exception.
_RATE_DELAY = 0.05

_FLAG_RE = re.compile(r"/countries/\d+/([a-zA-Z_-]+)\.\w+$")


def _country_from_flag(flag_href: str) -> str:
    """'.../countries/500/eng.png' -> 'ENG'. '' when the flag URL doesn't match the pattern
    (a handful of athlete records carry no flag at all)."""
    m = _FLAG_RE.search(flag_href or "")
    return m.group(1).upper() if m else ""


def _fetch_bio(athlete_id: str) -> dict | None:
    """Name + nationality + headshot for one athlete, or None when there's no usable photo
    (M16: dropped, not shipped photo-less). Cached indefinitely — a golfer's name/nationality/
    photo don't change season to season, so this is one lookup per athlete ever, not per
    athlete-season."""
    try:
        data = fetch_json(_ATHLETE_URL.format(id=athlete_id),
                          cache_key=f"golf_athlete_{athlete_id}.json", ttl_hours=24 * 365)
    except Exception as err:  # noqa: BLE001 — one bad athlete shouldn't sink the sweep
        print(f"[golf] athlete {athlete_id}: bio fetch failed ({err})")
        return None
    headshot = (data.get("headshot") or {}).get("href", "")
    if not headshot:
        return None
    name = data.get("displayName") or data.get("fullName") or ""
    if not name:
        return None
    flag_href = (data.get("flag") or {}).get("href", "")
    country = _country_from_flag(flag_href) or (data.get("citizenship") or "")[:3].upper()
    return {"name": name, "country": country, "headshot": headshot}


def _parse_season_stats(stats_data: dict) -> dict[str, float] | None:
    """The season aggregate line from one `.../athletes/{id}/statistics` payload, or None
    when the payload carries no stat categories at all (a handful of leader-list entries
    point at a season with a withdrawn/incomplete stat record)."""
    categories = (stats_data.get("splits") or {}).get("categories") or []
    if not categories:
        return None
    values = {s["name"]: s.get("value") for s in categories[0].get("stats", [])}

    def num(key: str) -> float:
        v = values.get(key)
        return float(v) if v is not None else 0.0

    return {
        "events": num("tournamentsPlayed"),
        "wins": num("wins"),
        "top10s": num("topTenFinishes"),
        "cuts_made": num("cutsMade"),
        "earnings": num("officialAmount") or num("amount"),
        "scoring_avg": num("scoringAverage"),
        "fedex_points": num("cupPoints"),
    }


_ID_RE = re.compile(r"/(\d+)(?:\?|$)")


def _ref_id(ref: str) -> str:
    """Trailing numeric id off any of this API's `$ref` URLs, e.g.
    '.../athletes/5467?lang=en&region=us' -> '5467'. '' when the ref doesn't end in a plain
    integer id (the tell for a corrupted/placeholder record — see `_find_unofficial_events`)."""
    m = _ID_RE.search(ref or "")
    return m.group(1) if m else ""


def _winner_official_amount(stats_data: dict) -> float | None:
    """The `officialAmount` a WINNER's per-event `statistics` payload reports (same category
    shape as `_parse_season_stats`, one event instead of one season), or None when the payload
    carries no stat categories at all (an unreadable/corrupted record — see module docstring's
    2015 Barbasol Championship note)."""
    categories = (stats_data.get("splits") or {}).get("categories") or []
    if not categories:
        return None
    values = {s["name"]: s.get("value") for s in categories[0].get("stats", [])}
    if "officialAmount" not in values and "amount" not in values:
        return None
    v = values.get("officialAmount")
    if v is None:
        v = values.get("amount")
    return float(v) if v is not None else None


def _find_unofficial_events(year: int) -> dict[str, dict[str, int]]:
    """`{athlete_id: {'events': n, 'wins': n, 'top10s': n}}` — credit to SUBTRACT from that
    athlete's season totals for one year, one entry per confirmed-unofficial small-field
    exhibition they were in. Empty in the overwhelmingly common case (no unofficial event
    found, or nothing about it could be confirmed cleanly). See the module docstring for the
    two-signal method (field-size pre-filter + the winner's own officialAmount) and why a
    single cheap check (winner earnings, list order) isn't safe on its own."""
    try:
        events = fetch_json(_EVENTS_URL.format(year=year),
                            cache_key=f"golf_events_{year}.json", ttl_hours=24 * 365)
    except Exception as err:  # noqa: BLE001 — no calendar this year, nothing to correct
        print(f"[golf] {year}: events list fetch failed, skipping unofficial-event check ({err})")
        return {}

    deltas: dict[str, dict[str, int]] = {}
    for item in events.get("items", []):
        eid = _ref_id(item.get("$ref", ""))
        try:
            ev = fetch_json(item["$ref"], cache_key=f"golf_event_{eid}.json", ttl_hours=24 * 365)
        except Exception:  # noqa: BLE001
            continue
        comps = ((ev.get("competitions") or [{}])[0]).get("competitors") or []
        # A real Tour field (70+), or a team event with no individual competitors at all
        # (Presidents Cup / Ryder Cup) — nothing here can be an unofficial stroke-play event.
        if not comps or len(comps) > _MAX_EXHIBITION_FIELD:
            continue

        # Resolve real finish position for as much of the field as this small-field event has,
        # from each competitor's OWN `status` — never list order, which a corrupted record can
        # scramble (see the Barbasol note). `aid` is skipped when it isn't a plain numeric ESPN
        # athlete id, which is exactly what a corrupted/placeholder entry looks like.
        positions: dict[str, int] = {}
        for c in comps[:_EXHIBITION_SCAN_DEPTH]:
            aid = _ref_id((c.get("athlete") or {}).get("$ref", ""))
            status_ref = (c.get("status") or {}).get("$ref", "")
            if not aid or not status_ref:
                continue
            try:
                st = fetch_json(status_ref, cache_key=f"golf_status_{eid}_{aid}.json",
                                ttl_hours=24 * 365)
            except Exception:  # noqa: BLE001
                continue
            pos_id = (st.get("position") or {}).get("id")
            try:
                positions[aid] = int(pos_id)
            except (TypeError, ValueError):
                continue

        winner_aid = next((aid for aid, pos in positions.items() if pos == 1), None)
        if winner_aid is None:
            continue   # can't confirm a winner from a small/odd field — leave it alone

        winner_stats_ref = next(
            (c["statistics"]["$ref"] for c in comps
             if _ref_id((c.get("athlete") or {}).get("$ref", "")) == winner_aid
             and c.get("statistics")), None)
        if not winner_stats_ref:
            continue
        try:
            wstats = fetch_json(winner_stats_ref,
                                cache_key=f"golf_winner_stats_{eid}.json", ttl_hours=24 * 365)
        except Exception:  # noqa: BLE001
            continue
        official = _winner_official_amount(wstats)
        if official is None or official > 0:
            continue   # a real Tour win (or an unreadable record) — leave it alone

        print(f"[golf] {year}: confirmed unofficial event {eid} "
              f"({len(comps)}-player field, winner officialAmount={official})")
        # Confirmed unofficial: every entrant loses one "event" credit (they started it, but it
        # isn't an official start); win/top10 credit is removed using each entrant's REAL
        # finish position, ties included.
        for c in comps:
            aid = _ref_id((c.get("athlete") or {}).get("$ref", ""))
            if not aid:
                continue
            d = deltas.setdefault(aid, {"events": 0, "wins": 0, "top10s": 0})
            d["events"] += 1
        for aid, pos in positions.items():
            d = deltas.setdefault(aid, {"events": 0, "wins": 0, "top10s": 0})
            if pos <= 10:
                d["top10s"] += 1
            if pos <= 1:
                d["wins"] += 1
    return deltas


def refresh(year_from: int = MIN_YEAR, year_to: int = MAX_YEAR) -> None:
    """Pull every qualifying PGA Tour player-season in range, resolve one bio per athlete,
    and write the committed CSV."""
    bios: dict[str, dict | None] = {}
    rows: list[dict] = []

    for year in range(year_from, year_to + 1):
        try:
            leaders = fetch_json(_LEADERS_URL.format(year=year, limit=_LEADERS_LIMIT),
                                 cache_key=f"golf_leaders_{year}.json", ttl_hours=24 * 30)
        except Exception as err:  # noqa: BLE001 — a missing year shouldn't sink the sweep
            print(f"[golf] {year}: leaders fetch failed, skipped ({err})")
            continue
        category = next((c for c in leaders.get("categories", [])
                         if c.get("name") == "officialAmount"), None)
        if not category:
            print(f"[golf] {year}: no money-list category, skipped")
            continue
        leader_entries = category.get("leaders", [])
        # No real pagination on this endpoint (see module docstring) — the only guard against
        # silent truncation is noticing the response landed exactly on the limit we asked for,
        # which means the real list may be bigger and this needs raising, not trusting blindly.
        assert len(leader_entries) < _LEADERS_LIMIT, (
            f"[golf] {year}: leaders list hit the {_LEADERS_LIMIT} cap exactly — "
            f"raise _LEADERS_LIMIT, the real season list may be bigger")

        unofficial = _find_unofficial_events(year)

        kept = 0
        for entry in leader_entries:
            athlete_ref = (entry.get("athlete") or {}).get("$ref", "")
            stats_ref = (entry.get("statistics") or {}).get("$ref", "")
            aid = athlete_ref.rstrip("/").split("/")[-1].split("?")[0]
            if not aid or not stats_ref:
                continue

            cache_key = f"golf_stats_{aid}_{year}.json"
            was_cached = is_cached(cache_key, ttl_hours=24 * 365)
            try:
                stats_data = fetch_json(stats_ref, cache_key=cache_key, ttl_hours=24 * 365)
            except Exception as err:  # noqa: BLE001
                print(f"[golf] {year} athlete {aid}: stats fetch failed ({err})")
                continue
            if not was_cached:
                time.sleep(_RATE_DELAY)

            stats = _parse_season_stats(stats_data)
            if not stats:
                continue

            # Strip unofficial-event credit (Hero World Challenge and its earlier sponsor
            # names — see module docstring) before the MIN_EVENTS gate, so a season is judged
            # on real Tour participation, floored at 0 in case a future season's numbers ever
            # disagree with this correction (never go negative on a stat that reads on a card).
            delta = unofficial.get(aid)
            if delta:
                stats["events"] = max(0.0, stats["events"] - delta["events"])
                stats["wins"] = max(0.0, stats["wins"] - delta["wins"])
                stats["top10s"] = max(0.0, stats["top10s"] - delta["top10s"])

            if stats["events"] < MIN_EVENTS:
                continue

            if aid not in bios:
                bios[aid] = _fetch_bio(aid)
                time.sleep(_RATE_DELAY)
            bio = bios[aid]
            if not bio:
                continue  # M16: no confident photo, dropped entirely

            rows.append({
                "name": bio["name"],
                "athlete_id": aid,
                "country": bio["country"],
                "season_year": year,
                "events": int(stats["events"]),
                "wins": int(stats["wins"]),
                "top10s": int(stats["top10s"]),
                "cuts_made": int(stats["cuts_made"]),
                "earnings": stats["earnings"],
                "scoring_avg": round(stats["scoring_avg"], 3),
                "fedex_points": stats["fedex_points"],
                "headshot": bio["headshot"],
            })
            kept += 1
        print(f"[golf] {year}: {kept} qualifying player-seasons of {len(leader_entries)} "
              f"on the money list ({len(bios)} distinct athletes resolved so far)")

    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)
    matched = sum(1 for b in bios.values() if b)
    print(f"[golf] wrote {len(rows)} player-seasons ({matched}/{len(bios)} athletes with a "
          f"real photo) → {CSV_PATH}")


def load_seasons() -> list[RawSeason]:
    """PGA Tour player-seasons from the committed CSV (stdlib-only; empty list until the
    one-time refresh has been run)."""
    if not CSV_PATH.exists():
        return []
    out: list[RawSeason] = []
    with CSV_PATH.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            events = float(row["events"])
            scoring_avg = float(row["scoring_avg"])
            fedex_points = float(row["fedex_points"])
            stats = {
                "events": events,
                "wins": float(row["wins"]),
                "top10s": float(row["top10s"]),
                "cuts_made": float(row["cuts_made"]),
                "earnings": float(row["earnings"]),
            }
            # ESPN writes 0 where it has NO value, and both of these are stats where 0 is not a
            # real reading: a golfer short of the official-rounds minimum has no scoring average
            # (168 seasons), and FedExCup points are absent before 2007 AND for whole later
            # seasons (2009-14, 2016-17). Left in as 0, a missing average reads as the best
            # scoring season ever and `scoring_margin` becomes ~71 x events, which swamps every
            # other term. Omit them instead, exactly as a stat the source never had.
            if scoring_avg > 0:
                stats["scoring_avg"] = scoring_avg
                # Derived grading term, not a sourced stat — see grade.py's golf_fantasy
                # comment and BASELINE_SCORING_AVG above.
                stats["scoring_margin"] = round((BASELINE_SCORING_AVG - scoring_avg) * events, 1)
            if fedex_points > 0:
                stats["fedex_points"] = fedex_points
            out.append(RawSeason(
                name=row["name"],
                team_abbr=row["country"],
                season_year=int(row["season_year"]),
                sport="golf",
                position="Golfer",
                person_id=row["athlete_id"],
                stats=stats,
                source="espn_golf",
                headshot=row["headshot"],
            ))
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed PGA Tour season sweep")
    ap.add_argument("--from", dest="year_from", type=int, default=MIN_YEAR)
    ap.add_argument("--to", dest="year_to", type=int, default=MAX_YEAR)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
