"""Curated seed provider — real, factual player-seasons hand-sourced from
Basketball-Reference.

Used for NBA when no BALLDONTLIE_API_KEY is configured, so the pipeline still
produces real (not fictional) content offline. Every row is a real stat line;
see data/nba_seed.csv. NFL needs no seed — nflverse covers it live.
"""
from __future__ import annotations

import csv
from pathlib import Path

from ..models import RawSeason

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def _f(row: dict, key: str) -> float:
    raw = row.get(key, "")
    return float(raw) if raw not in ("", None) else 0.0


def load_nba() -> list[RawSeason]:
    path = DATA_DIR / "nba_seed.csv"
    out: list[RawSeason] = []
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            stats = {
                "games": _f(row, "games"),
                "ppg": _f(row, "ppg"),
                "rpg": _f(row, "rpg"),
                "apg": _f(row, "apg"),
                "spg": _f(row, "spg"),
                "bpg": _f(row, "bpg"),
                "fg_pct": _f(row, "fg_pct"),
                "ts_pct": _f(row, "ts_pct"),
            }
            out.append(
                RawSeason(
                    name=row["name"],
                    team_abbr=row["team_abbr"],
                    season_year=int(row["season_year"]),
                    sport="nba",
                    position=row["position"],
                    stats=stats,
                    source="seed",
                )
            )
    return out
