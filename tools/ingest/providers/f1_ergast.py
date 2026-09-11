"""Formula 1 driver-seasons, 1950-present — the Ergast schema via the Jolpica mirror.

`ergast.com` itself is **dead** (every path 404s as of 2026-09-03); `api.jolpi.ca/ergast`
is the maintained drop-in mirror and is what this provider targets. The schema is
unchanged, so any Ergast documentation still applies.

## What an F1 "player-season" is here

A driver-season: one row per (driver, year), with `team_abbr` holding the **constructor**.
That makes F1 a club sport in this catalog's sense — `hasClubCareers` is true and a
driver's constructor history (Hamilton: McLaren -> Mercedes -> Ferrari) is a real Journeyman
board, which is what makes F1 worth more to this app than tennis, the other one-position
sport.

## Why the championship `points` column is NOT ingested

F1 rewrote its points system in 1961, 1991 and 2010 (a win went 8 -> 9 -> 10 -> 25), so a
raw points total is meaningless across eras: Fangio's 1954 title season scored 42, which a
modern midfielder beats without ever seeing a podium. Every stat below is instead an
era-invariant achievement counted from race results, which is the only way a 1950s season
and a 2020s season are rankable on one axis. See `grade.py`'s `f1_driver_fantasy`.

Two API quirks that shape the code:

1. **Fastest laps only exist from 2004.** Ergast has no `FastestLap` block before then
   (checked: 2003 no, 2004 yes). For a pre-2004 season the key is OMITTED rather than
   written as 0, the same rule `nhl_stats.py` applies to pre-1968 plus-minus — a zero would
   claim Jim Clark never set a fastest lap, which is false, rather than "not recorded".
2. **An in-progress season is excluded outright.** Ergast serves standings for a season
   mid-flight, so the current points leader comes back with `position == "1"` and would be
   written as a world champion — caught live on 2026-09-03, 12 races into 2026, which minted
   Andrea Kimi Antonelli a title he has not won. A partial season is also simply not
   comparable to the complete ones it would share a Keep4 board with. `_season_is_complete`
   settles it against the season SCHEDULE (see its docstring — the two more obvious checks
   both give the wrong answer), and `refresh` skips the season if the calendar has not run
   out. Same call `tennis_wta.py` makes for the same reason.
3. **A DNF is read off `positionText`, not `status`.** `status` is free text with dozens of
   values ("Gearbox", "+2 Laps", "Spun off"); `positionText` is a digit for every classified
   finish and a letter code otherwise (R retired, D disqualified, W withdrawn, N not
   classified), which is era-proof in a way that string-matching statuses is not.

Constructor codes are the raw Ergast `constructorId`, uppercased ("MCLAREN", "RED_BULL",
"TEAM_LOTUS"). Deliberately not a derived 3-letter abbreviation: this repo has already paid
for that once on the soccer side, where a word-initials heuristic silently merged Blackburn
Rovers and Brisbane Roar under "BRO" (see `club_codes.py`). Ergast ids are unique and stable
by construction, so using them directly makes a collision impossible rather than merely
unlikely, and the human-readable name travels in `meta["team_name"]` for the card to show.

Run:  python -m tools.ingest.providers.f1_ergast [--from 1950 --to 2026]
"""
from __future__ import annotations

import argparse
import collections
import csv
import datetime as _dt
from pathlib import Path

from ..models import RawSeason
from .http import fetch_json
from .wikimedia import headshot as wiki_headshot

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "f1_seasons.csv"

_BASE = "https://api.jolpi.ca/ergast/f1"
_PAGE = 100

FIRST_SEASON = 1950
FASTEST_LAP_FROM = 2004   # Ergast carries no FastestLap block before this

CSV_FIELDS = [
    "name", "team_abbr", "team_name", "teams_all", "season_year", "position",
    "headshot", "nationality", "championship_position",
    "wins", "podiums", "poles", "fastest_laps", "top_tens", "races",
    "championships", "dnfs",
]


def current_season() -> int:
    """The season now running. F1 runs March-December inside one calendar year, so this is
    just the current year once the season has started. Computed rather than hardcoded, the
    same treatment `main.py` gives the nflverse year range."""
    return _dt.date.today().year


def _paged(path: str, year: int) -> list[dict]:
    """Every race in `path` for `year`, paged through Ergast's 100-row limit."""
    races: list[dict] = []
    offset = 0
    while True:
        url = f"{_BASE}/{year}/{path}/?format=json&limit={_PAGE}&offset={offset}"
        data = fetch_json(url, cache_key=f"f1_{path}_{year}_{offset}.json",
                          ttl_hours=24 * 365)["MRData"]
        races.extend(data.get("RaceTable", {}).get("Races", []))
        total = int(data.get("total") or 0)
        offset += _PAGE
        if offset >= total:
            return races


def _standings(year: int) -> dict[str, dict]:
    """driverId -> that driver's final championship standing for the season."""
    url = f"{_BASE}/{year}/driverstandings/?format=json&limit={_PAGE}"
    data = fetch_json(url, cache_key=f"f1_standings_{year}.json",
                      ttl_hours=24 * 365)["MRData"]
    lists = data.get("StandingsTable", {}).get("StandingsLists", [])
    if not lists:
        return {}
    return {s["Driver"]["driverId"]: s for s in lists[0].get("DriverStandings", [])}


def _season_is_complete(year: int, today: _dt.date | None = None) -> bool:
    """Has the season's final round been run?

    Judged against the season SCHEDULE (`/{year}/races/`), not against the results already
    published. Two things make the obvious checks wrong:

    * The latest result's date is not the season's end. On 2026-09-03, 2026's newest result
      was dated 2026-08-23 — in the past — while nine rounds remained on the calendar. That
      check passed and minted the current points leader a world championship.
    * Counting race objects in the results feed does not give the number of rounds run:
      Ergast pages by RESULT row, so a race straddling a page boundary appears in both pages
      (2024 reports 28 race objects for 24 real rounds). Harmless for aggregation — no result
      row is duplicated, verified — but useless as a completeness signal.

    The schedule's last date is neither of those things: it is the season's actual end.
    """
    today = today or _dt.date.today()
    dates = [r.get("date") for r in _paged("races", year) if r.get("date")]
    if not dates:
        return False        # no calendar to judge by — treat as incomplete rather than guess
    return max(dates) < today.isoformat()


def _rows_for_season(year: int, require_complete: bool = False) -> list[dict]:
    """One CSV-shaped row per driver who started a race that season."""
    races = _paged("results", year)
    if not races:
        return []
    if require_complete and not _season_is_complete(year):
        print(f"[f1] {year}: season still in progress, skipped")
        return []
    standings = _standings(year)

    # Ergast only carries fastest-lap data from 2004; before that the absence of a
    # FastestLap block means "not recorded", not "never set one".
    have_fl = year >= FASTEST_LAP_FROM

    agg: dict[str, dict] = {}
    ctors: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for race in races:
        for res in race.get("Results", []):
            did = res["Driver"]["driverId"]
            row = agg.setdefault(did, {
                "name": f"{res['Driver']['givenName']} {res['Driver']['familyName']}".strip(),
                "nationality": res["Driver"].get("nationality", ""),
                "wins": 0, "podiums": 0, "poles": 0, "fastest_laps": 0,
                "top_tens": 0, "races": 0, "dnfs": 0,
            })
            row["races"] += 1
            ctor = res["Constructor"]
            ctors[did][(ctor["constructorId"], ctor.get("name", ""))] += 1

            # `positionText` is a digit only for a classified finish; R/D/W/N/E mark a
            # retirement, disqualification, withdrawal or non-classification.
            ptext = res.get("positionText", "")
            if ptext.isdigit():
                pos = int(ptext)
                if pos == 1:
                    row["wins"] += 1
                if pos <= 3:
                    row["podiums"] += 1
                if pos <= 10:
                    row["top_tens"] += 1
            else:
                row["dnfs"] += 1

            if res.get("grid") == "1":
                row["poles"] += 1
            if have_fl and (fl := res.get("FastestLap")) and fl.get("rank") == "1":
                row["fastest_laps"] += 1

    out: list[dict] = []
    for did, row in agg.items():
        # A driver can change constructor mid-season; the one they raced most for is the
        # season's primary, and the full set travels in `teams_all` so Journeyman can
        # reconstruct the switch as two stints rather than swallowing it.
        ordered = [c for c, _ in ctors[did].most_common()]
        primary_id, primary_name = ordered[0]
        standing = standings.get(did, {})
        champ_pos = standing.get("position", "")
        row.update({
            "team_abbr": primary_id.upper(),
            "team_name": primary_name,
            "teams_all": "|".join(cid.upper() for cid, _ in ordered),
            "season_year": year,
            "position": "Driver",
            "headshot": "",
            "championship_position": champ_pos,
            "championships": 1 if champ_pos == "1" else 0,
        })
        if not have_fl:
            row["fastest_laps"] = ""     # omitted, not zero — see module docstring
        out.append(row)
    return out


def _wiki(name: str) -> str:
    """A real Wikipedia portrait, or "" — the M16 no-photo-no-row contract's input.
    `racing` is the context word because Wikipedia/Wikidata describe drivers as
    "<nationality> racing driver"; the suffixes catch the disambiguated page titles."""
    return wiki_headshot(name, context="racing",
                         title_suffixes=("racing driver", "Formula One", "driver"))


def refresh(year_from: int = FIRST_SEASON, year_to: int | None = None) -> None:
    year_to = current_season() if year_to is None else year_to
    rows: list[dict] = []
    for year in range(year_from, year_to + 1):
        try:
            season_rows = _rows_for_season(year, require_complete=True)
        except Exception as err:  # noqa: BLE001 — one bad season shouldn't sink the sweep
            print(f"[f1] {year}: skipped ({err})")
            continue
        rows.extend(season_rows)
        print(f"[f1] {year}: {len(season_rows)} driver-seasons")

    names = sorted({r["name"] for r in rows})
    print(f"[f1] resolving Wikipedia portraits for {len(names)} drivers …")
    shots = {n: _wiki(n) for n in names}
    matched = sum(1 for v in shots.values() if v)
    print(f"[f1] {matched}/{len(names)} drivers matched a real photo")

    final = []
    for row in rows:
        if shot := shots.get(row["name"], ""):
            row["headshot"] = shot
            final.append(row)

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(final)
    print(f"[f1] wrote {len(final)} driver-seasons → {CSV_PATH}")


_STAT_KEYS = ("wins", "podiums", "poles", "fastest_laps", "top_tens",
              "races", "championships", "dnfs")


def _to_raw(row: dict, source: str) -> RawSeason:
    stats = {}
    for key in _STAT_KEYS:
        raw = row.get(key, "")
        if raw == "" or raw is None:
            continue
        stats[key] = float(raw)
    meta = {k: str(row[k]) for k in ("team_name", "nationality", "championship_position")
            if row.get(k)}
    if (teams := row.get("teams_all", "")) and "|" in teams:
        meta["teams_all"] = teams
    return RawSeason(
        name=row["name"],
        team_abbr=row["team_abbr"],
        season_year=int(row["season_year"]),
        sport="f1",
        position="Driver",
        stats=stats,
        source=source,
        headshot=row.get("headshot", ""),
        meta=meta,
    )


def load_seasons() -> list[RawSeason]:
    """Historical F1 driver-seasons from the committed CSV (stdlib-only; empty until the
    one-time `refresh()` has been run)."""
    if not CSV_PATH.exists():
        return []
    with CSV_PATH.open(encoding="utf-8") as f:
        return [_to_raw(row, "f1_ergast") for row in csv.DictReader(f)]


def main() -> int:
    ap = argparse.ArgumentParser(description="Refresh the committed F1 driver-season sweep")
    ap.add_argument("--from", dest="year_from", type=int, default=FIRST_SEASON)
    ap.add_argument("--to", dest="year_to", type=int, default=None)
    args = ap.parse_args()
    refresh(args.year_from, args.year_to)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
