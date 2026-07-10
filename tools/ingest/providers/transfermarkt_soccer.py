"""Soccer full-squad season stats — the Transfermarkt-derived open dataset from
dcaribou/transfermarkt-datasets, via its HuggingFace CSV mirror.

Breaks past api_football.py's documented free-tier ceiling (top ~20 attackers per
league-season, ~3-season rolling window, no clean-sheets field anywhere): this dataset is
per-match appearance rows for EVERY player — defenders and keepers included — across 14
European first-tier leagues from 2012 on, with real Transfermarkt portrait URLs on
~83% of players. That turns "soccer is 20 scorers a season plus a hand-curated GK seed"
into tens of thousands of full-squad player-seasons, and makes the `soccer-defenders`
theme populatable from a real source for the first time (clean sheets are derived, not
provided: a GK/DF appearance in a match their club conceded 0 goals in — verified against
the hand-seed's golden-glove rows, e.g. Alisson LIV 2018-19 = 38 apps / 21 CS exactly).

Upstream: the canonical HuggingFace home named in the project README
(davidcariboo/player-scores) went 401/private — verified 2026-07-10, both the file
resolver and the dataset API reject anonymous access. `ngeorgea/transfermarkt-player-scores`
is a public, ungated mirror of the same export (same filenames/schemas, refreshed
2026-06-29) and is what this provider downloads from. If it too goes dark, the generator
repo (github.com/dcaribou/transfermarkt-datasets, still active) publishes the same CSVs
to data.world and Kaggle — re-point `_HF_BASE` rather than rebuild.

Scope decisions (all verified against the data, not assumed):
- **Domestic first tiers only** (competitions.csv `sub_type == "first_tier"`). The
  existing catalog's soccer stats are league-only lines (seed: Haaland MCI 2023 = 35
  apps/36 goals = his PL-only 2022-23; api-football topscorers are per-league too), so
  folding UCL/UEL/cup games into the same row would inflate every stat out of that
  convention. Only 14 of the dataset's 31 first-tier ids actually have appearance rows
  (its league coverage is European: GB1/ES1/IT1/L1/FR1/PO1/NL1/BE1/TR1/RU1/GR1/SC1/
  UKR1/DK1 — Brazil/MLS/etc are club-metadata-only), and those 14 fit in ~9 MB, under
  the ~20 MB committed-file budget, so all 14 are kept.
- **`season_year` = the season's END year** (Transfermarkt labels seasons by START year:
  its `season=2022` is 2022-23). The hand-curated seed — the reference the GK/DF rows
  from here must merge with — uses END years throughout: Haaland's 36-goal PL season
  carries 2023, Cech's record 24-clean-sheet season carries 2005, Alisson's golden-glove
  season carries 2019. (soccer_live.json's api-football rows use START years — a
  pre-existing inconsistency between seed and live; this provider sides with the seed
  because that's where the overlapping GK/DF rows live.) The end year is derived from
  game dates per (competition, season) rather than hardcoded +1, so a calendar-year
  league would come out unshifted if the dataset ever grows one.
- **appearances >= 5** — a real squad member's season, not a cameo.
- **No photo, no row** (the M16 contract): players whose Transfermarkt `image_url` is
  missing or the literal default.jpg placeholder are dropped entirely.

Same split as hoopr_nba/tennis_atp: a network-heavy `refresh()` writes a committed CSV
(`data/soccer_transfermarkt_seasons.csv`, same column layout as soccer_seed.csv) and a
stdlib-only `load_seasons()` reads it at pipeline runtime. The source files are cached
under `.cache/` (appearances.csv is ~150 MB — streamed to disk and stream-parsed, never
held in memory).

Run:  python -m tools.ingest.providers.transfermarkt_soccer
"""
from __future__ import annotations

import argparse
import csv
import shutil
import time
import urllib.request
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable, Iterator

from ..models import RawSeason
from .http import CACHE_DIR, _USER_AGENT

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
CSV_PATH = DATA_DIR / "soccer_transfermarkt_seasons.csv"

_HF_BASE = "https://huggingface.co/datasets/ngeorgea/transfermarkt-player-scores/resolve/main"

MIN_SEASON = 2012      # dataset has only stray friendly-sized fragments before this
MIN_APPEARANCES = 5    # squad member, not cameo

# If at least this share of a (competition, season)'s games fall in the calendar year
# after the season label, it's a cross-year (European Aug–May) season and the catalog
# year is label+1; otherwise it's a calendar-year season and the label stands. European
# seasons put ~half their games in the second year; a calendar league with one stray
# rescheduled January fixture stays comfortably below this.
_CROSS_YEAR_SHARE = 0.25

_POSITION_MAP = {"Attack": "FW", "Midfield": "MF", "Defender": "DF", "Goalkeeper": "GK"}

# Transfermarkt club_id → the short code the existing catalog already uses (seed codes
# first — MCI/LIV/CHE/... must match soccer_seed.csv exactly so rosters merge — then
# common broadcast codes for other famous clubs where the derived fallback is ugly).
_KNOWN_CODES = {
    # England
    "281": "MCI", "985": "MUN", "31": "LIV", "631": "CHE", "11": "ARS", "148": "TOT",
    "405": "AVL", "1132": "BUR", "762": "NEW", "379": "WHU", "29": "EVE", "543": "WOL",
    "873": "CRY", "1237": "BHA", "703": "NFO", "989": "BOU", "1148": "BRE", "399": "LEE",
    # Spain
    "418": "RMA", "131": "FCB", "13": "ATM", "368": "SEV", "1049": "VAL", "1050": "VIL",
    "150": "BET", "621": "ATH", "681": "RSO",
    # Germany
    "27": "BAY", "16": "BVB", "15": "LEV", "23826": "RBL", "18": "BMG", "24": "EIN",
    "33": "S04", "79": "STU", "82": "WOB",
    # Italy
    "506": "JUV", "46": "INT", "5": "MIL", "6195": "NAP", "12": "ROM", "398": "LAZ",
    "800": "ATA", "430": "FIO",
    # France
    "583": "PSG", "244": "MAR", "1041": "LYO", "162": "MON", "1082": "LIL",
    # Portugal / Netherlands / Scotland / Turkey
    "720": "POR", "294": "BEN", "336": "SPO",
    "610": "AJA", "383": "PSV", "234": "FEY",
    "371": "CEL", "124": "RAN",
    "141": "GAL", "36": "FEN", "114": "BES",
}

# Tokens that are legal/organizational boilerplate in Transfermarkt's long-form club
# names ("Manchester City Football Club", "Real Madrid Club de Fútbol"), not identity.
_FILLER = {
    "fc", "cf", "afc", "cfc", "ssc", "ac", "as", "ss", "sv", "sk", "fk", "bk", "jk",
    "nk", "rc", "cd", "ca", "sad", "spa", "ev", "ag",
    "club", "clube", "football", "futbol", "fútbol", "futebol", "fußball", "calcio",
    "balompié", "association", "associazione", "sociedade", "sport", "sports",
    "sporting", "sportive", "spor", "kulübü", "verein", "vereniging",
    "voetbalvereniging", "de", "do", "da", "di", "la", "le", "el", "of", "and", "und",
    "e", "the", "aş", "sa", "sdd", "team",
}

CSV_FIELDS = ["name", "team_abbr", "season_year", "position",
              "appearances", "goals", "assists", "clean_sheets", "headshot"]


# ---------------------------------------------------------------------------
# pure helpers (unit-tested directly)

def _short_code(club_name: str) -> str:
    """Display short code for a club without a curated entry: strip boilerplate tokens,
    then 1 word → first 3 letters, 2+ words → initial + first 2 of the second word
    (reproduces MCI / MUN / RMA from their full names by itself)."""
    words = ["".join(ch for ch in w if ch.isalnum())
             for w in club_name.replace("-", " ").split()]
    words = [w for w in words
             if len(w) > 1 and w.lower() not in _FILLER and not w.isdigit()]
    if not words:  # nothing but boilerplate ("B SAD") — fall back to raw letters
        words = ["".join(ch for ch in club_name if ch.isalnum()) or club_name]
    if len(words) == 1:
        return words[0][:3].upper()
    return (words[0][0] + words[1][:2]).upper()


def _index_games(rows: Iterable[dict]) -> tuple[dict[str, tuple], dict[tuple[str, int], int]]:
    """games.csv rows → (game_id → (comp, season, home_id, home_goals, away_id,
    away_goals), (comp, season) → catalog season END year)."""
    games: dict[str, tuple] = {}
    totals: Counter = Counter()
    in_next: Counter = Counter()
    for row in rows:
        season_txt = (row.get("season") or "").strip()
        if not season_txt.isdigit():
            continue
        season = int(season_txt)
        comp = row["competition_id"]
        try:
            games[row["game_id"]] = (comp, season, row["home_club_id"],
                                     int(row["home_club_goals"]), row["away_club_id"],
                                     int(row["away_club_goals"]))
        except ValueError:  # unplayed/unscored fixture — useless for clean sheets
            continue
        totals[(comp, season)] += 1
        date = (row.get("date") or "")[:4]
        if date.isdigit() and int(date) == season + 1:
            in_next[(comp, season)] += 1
    end_years: dict[tuple[str, int], int] = {}
    for (comp, season), n in totals.items():
        cross_year = in_next[(comp, season)] / n >= _CROSS_YEAR_SHARE
        end_years[(comp, season)] = season + 1 if cross_year else season
    return games, end_years


def _aggregate(appearance_rows: Iterable[dict], games: dict[str, tuple],
               keep_comps: set[str]) -> dict[tuple[str, str, str, int], dict[str, int]]:
    """Per-match appearance rows → (player_id, club_id, comp, season) season lines.
    `clean_sheets` is counted for everyone here (a match where the player's club
    conceded 0); the caller zeroes it for FW/MF to match the seed's convention."""
    agg: dict[tuple[str, str, str, int], dict[str, int]] = defaultdict(
        lambda: {"appearances": 0, "goals": 0, "assists": 0, "clean_sheets": 0})
    for row in appearance_rows:
        comp = row["competition_id"]
        if comp not in keep_comps:
            continue
        game = games.get(row["game_id"])
        if game is None or game[1] < MIN_SEASON:
            continue
        _, season, home_id, home_goals, _, away_goals = game
        club = row["player_club_id"]
        line = agg[(row["player_id"], club, comp, season)]
        line["appearances"] += 1
        line["goals"] += int(row["goals"] or 0)
        line["assists"] += int(row["assists"] or 0)
        if (away_goals if club == home_id else home_goals) == 0:
            line["clean_sheets"] += 1
    return agg


def _real_image(url: str) -> str:
    """Transfermarkt portrait URL, or '' for the shared default.jpg placeholder."""
    url = (url or "").strip()
    return "" if (not url or "default.jpg" in url) else url


# ---------------------------------------------------------------------------
# refresh path (network-heavy, run manually / from CI — never at pipeline runtime)

def _download(name: str, *, ttl_hours: float = 24 * 90) -> Path:
    """Fetch one dataset CSV into .cache/ (streamed — appearances.csv is ~150 MB),
    reusing a fresh cached copy. Returns the local path; callers stream-parse it."""
    path = CACHE_DIR / f"tm_{name}.csv"
    if path.exists() and (time.time() - path.stat().st_mtime) < ttl_hours * 3600:
        return path
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    url = f"{_HF_BASE}/{name}.csv"
    req = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    tmp = path.with_suffix(".part")
    with urllib.request.urlopen(req, timeout=120) as resp, tmp.open("wb") as out:
        shutil.copyfileobj(resp, out, length=1 << 20)
    tmp.replace(path)
    return path


def _read_csv(path: Path) -> Iterator[dict]:
    with path.open(encoding="utf-8", newline="") as f:
        yield from csv.DictReader(f)


def refresh() -> None:
    """Download the four source CSVs, aggregate per-match appearances into full-squad
    (player, club, season) lines, and write the committed CSV."""
    comps_path = _download("competitions")
    games_path = _download("games")
    players_path = _download("players")
    clubs_path = _download("clubs")
    appearances_path = _download("appearances")

    first_tier = {r["competition_id"] for r in _read_csv(comps_path)
                  if r["sub_type"] == "first_tier"}
    print(f"[transfermarkt] {len(first_tier)} first-tier competitions")

    games, end_years = _index_games(_read_csv(games_path))
    print(f"[transfermarkt] indexed {len(games)} games")

    players = {r["player_id"]: (r["name"], _POSITION_MAP.get(r["position"], ""),
                                _real_image(r["image_url"]))
               for r in _read_csv(players_path)}
    club_codes = {r["club_id"]: _KNOWN_CODES.get(r["club_id"]) or _short_code(r["name"])
                  for r in _read_csv(clubs_path)}

    agg = _aggregate(_read_csv(appearances_path), games, first_tier)
    print(f"[transfermarkt] {len(agg)} raw (player, club, season) lines")

    rows: list[dict] = []
    dropped = Counter()
    for (player_id, club_id, comp, season), line in agg.items():
        if line["appearances"] < MIN_APPEARANCES:
            dropped["cameo"] += 1
            continue
        name, position, image = players.get(player_id, ("", "", ""))
        if not name or not position:
            dropped["no_position"] += 1
            continue
        if not image:
            dropped["no_photo"] += 1
            continue
        rows.append({
            "name": name,
            "team_abbr": club_codes.get(club_id) or club_id,
            "season_year": end_years[(comp, season)],
            "position": position,
            "appearances": line["appearances"],
            "goals": line["goals"],
            "assists": line["assists"],
            # Seed convention: clean sheets are a GK/DF stat; attackers carry 0.
            "clean_sheets": line["clean_sheets"] if position in ("GK", "DF") else 0,
            "headshot": image,
        })
    rows.sort(key=lambda r: (r["name"], r["season_year"], r["team_abbr"]))

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with CSV_PATH.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        w.writeheader()
        w.writerows(rows)

    by_pos = Counter(r["position"] for r in rows)
    print(f"[transfermarkt] dropped: {dict(dropped)}")
    print(f"[transfermarkt] wrote {len(rows)} player-seasons "
          f"({', '.join(f'{p}={n}' for p, n in sorted(by_pos.items()))}) → {CSV_PATH} "
          f"({CSV_PATH.stat().st_size / 1e6:.1f} MB)")


# ---------------------------------------------------------------------------
# runtime path (stdlib-only)

def load_seasons() -> list[RawSeason]:
    """Full-squad soccer player-seasons from the committed CSV (empty list until the
    one-time refresh has been run). Identical column layout and stat keys to
    seed.load_soccer, so both sources merge cleanly downstream."""
    if not CSV_PATH.exists():
        return []
    out: list[RawSeason] = []
    with CSV_PATH.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            out.append(RawSeason(
                name=row["name"],
                team_abbr=row["team_abbr"],
                season_year=int(row["season_year"]),
                sport="soccer",
                position=row["position"],
                stats={
                    "appearances": float(row["appearances"]),
                    "goals": float(row["goals"]),
                    "assists": float(row["assists"]),
                    "clean_sheets": float(row["clean_sheets"]),
                },
                source="transfermarkt",
                headshot=row["headshot"],
            ))
    return out


def main() -> int:
    argparse.ArgumentParser(
        description="Refresh the committed Transfermarkt full-squad soccer sweep"
    ).parse_args()
    refresh()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
