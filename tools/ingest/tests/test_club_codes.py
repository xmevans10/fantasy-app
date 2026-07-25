"""Club short-code resolution tests — the collision fix (root cause: the word-initials
heuristic and the curated club_id map were each never checked for GLOBAL uniqueness, so
101 of 657 derived codes collided across differently-named clubs).

`resolve_code` is the single entry point both `transfermarkt_soccer.py` and
`espn_soccer.py` call; this file tests it directly, no network, no provider imports."""
import csv
from pathlib import Path

import pytest

from tools.ingest.providers import club_codes
from tools.ingest.providers.club_codes import (
    normalize_name, reload_overrides, resolve_code)

TM_CLUBS_CACHE = Path(__file__).resolve().parent.parent / ".cache" / "tm_clubs.csv"
TM_COMPETITIONS_CACHE = Path(__file__).resolve().parent.parent / ".cache" / "tm_competitions.csv"

# The seven collision pairs confirmed live in the M17 audit — each pair's two clubs
# derived the SAME code from the pre-fix heuristic/curated-map combo before this fix.
_COLLISION_PAIRS = [
    ("Blackburn Rovers Football Club", "England", "Brisbane Roar FC", "Australia"),
    ("Brentford Football Club", "England", "Brescia Calcio", "Italy"),
    ("Burnley Football Club", "England", "Bursaspor", "Turkey"),
    ("AFC Ajax Amsterdam", "Netherlands", "AC Ajaccio", "France"),
    ("Football Club Internazionale Milano S.p.A.", "Italy",
     "Sport Club Internacional", "Brazil"),
    ("Athletic Club Bilbao", "Spain", "Aris Thessalonikis", "Greece"),
    ("Hamburger Sport Verein", "Germany", "Hamarkameratene", "Norway"),
]


@pytest.mark.parametrize("name_a,country_a,name_b,country_b", _COLLISION_PAIRS)
def test_named_collision_pairs_resolve_to_distinct_codes(name_a, country_a, name_b, country_b):
    code_a = resolve_code(name_a, country=country_a)
    code_b = resolve_code(name_b, country=country_b)
    assert code_a != code_b, f"{name_a} and {name_b} still collide on {code_a!r}"


def test_famous_club_keeps_its_original_code_in_a_collision():
    # The more famous/major-league club of a colliding pair keeps the plain heuristic/
    # curated code; only the other one gets reassigned via the override table.
    assert resolve_code("Blackburn Rovers Football Club", country="England") == "BRO"
    assert resolve_code("Brentford Football Club", country="England") == "BRE"
    assert resolve_code("Burnley Football Club", country="England") == "BUR"
    assert resolve_code("AFC Ajax Amsterdam", country="Netherlands") == "AJA"
    assert resolve_code(
        "Football Club Internazionale Milano S.p.A.", country="Italy") == "INT"
    assert resolve_code("Athletic Club Bilbao", country="Spain") == "ATH"
    assert resolve_code("Hamburger Sport Verein", country="Germany") == "HAM"


def test_disambiguated_codes_stay_short():
    for _, _, loser_name, loser_country in _COLLISION_PAIRS:
        code = resolve_code(loser_name, country=loser_country)
        assert 3 <= len(code) <= 4


def test_unambiguous_codes_are_unchanged_by_the_override_layer():
    # Non-colliding famous clubs must be untouched — the compatibility contract with
    # already-ingested data.
    assert resolve_code("Manchester City Football Club", country="England") == "MCI"
    assert resolve_code("Liverpool Football Club", country="England") == "LIV"
    assert resolve_code("Real Madrid Club de Fútbol", country="Spain") == "RMA"


def test_resolve_code_is_deterministic():
    for name, country, *_ in _COLLISION_PAIRS:
        assert resolve_code(name, country=country) == resolve_code(name, country=country)
    for _ in range(3):
        assert resolve_code("Some Rare Club FC", country="Nowhereland") == \
            resolve_code("Some Rare Club FC", country="Nowhereland")


def test_resolve_code_prefers_club_id_curated_map_over_name_lookup():
    # A club_key hit is checked before the name+country table or the heuristic.
    assert resolve_code("Manchester City Football Club", country="England",
                        club_key="281") == "MCI"


def test_resolve_code_falls_back_to_heuristic_for_unknown_clubs():
    # "Football Club" is stripped as boilerplate, leaving [Some, Rare] -> S + first-2("Rare").
    assert resolve_code("Some Rare Club Football Club", country="Nowhereland") == "SRA"


def test_espn_style_display_name_matches_transfermarkt_long_name_for_curated_clubs():
    # ESPN only ever has a free-text display name (no TM club_id) — the shared
    # name+country layer must still land the same famous club on the same code.
    assert resolve_code("Manchester City", country="England") == \
        resolve_code("Manchester City Football Club", country="England") == "MCI"
    assert resolve_code("Real Madrid", country="Spain") == \
        resolve_code("Real Madrid Club de Fútbol", country="Spain") == "RMA"


def test_overrides_csv_reload_picks_up_a_fixture_file(tmp_path, monkeypatch):
    fixture = tmp_path / "overrides.csv"
    key = normalize_name("Fixture Athletic FC")
    fixture.write_text(f"normalized_name,country,code\n{key},Testland,FXC\n",
                       encoding="utf-8")
    monkeypatch.setattr(club_codes, "OVERRIDES_PATH", fixture)
    reload_overrides()
    try:
        assert resolve_code("Fixture Athletic FC", country="Testland") == "FXC"
    finally:
        monkeypatch.setattr(club_codes, "OVERRIDES_PATH",
                            club_codes.DATA_DIR / "soccer_club_code_overrides.csv")
        reload_overrides()


def test_overrides_csv_has_no_duplicate_keys_or_duplicate_codes():
    path = club_codes.DATA_DIR / "soccer_club_code_overrides.csv"
    with path.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    keys = [(r["normalized_name"], r["country"]) for r in rows]
    assert len(keys) == len(set(keys))
    codes = [r["code"] for r in rows]
    assert len(codes) == len(set(codes)), "override codes must be globally unique"


def test_overrides_csv_only_covers_names_that_actually_collide():
    # Every entry in the committed table must be for a club whose plain heuristic code
    # collided with something else — the override table should never touch an
    # already-unique code (that would gratuitously break an unrelated club's code).
    path = club_codes.DATA_DIR / "soccer_club_code_overrides.csv"
    with path.open(encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for row in rows:
        heuristic = club_codes._short_code(row["normalized_name"])
        override = row["code"]
        assert heuristic != override, (
            f"{row['normalized_name']} ({row['country']}): override {override!r} is "
            f"identical to its own heuristic code — shouldn't be in the table")


@pytest.mark.skipif(not TM_CLUBS_CACHE.exists() or not TM_COMPETITIONS_CACHE.exists(),
                    reason="requires the locally-cached Transfermarkt club/competition "
                          "dump (.cache/tm_clubs.csv) — not committed, so absent in CI")
def test_globally_unique_across_the_known_club_universe():
    """Property test: resolve_code() must never produce the same code for two distinct
    (name, country) club identities across the full cached Transfermarkt club list —
    the exact regression this module exists to prevent."""
    comps: dict[str, str] = {}
    with TM_COMPETITIONS_CACHE.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            comps[row["competition_id"]] = row["country_name"]
    country_alias = {"Türkiye": "Turkey", "Korea, South": "South Korea"}

    by_code: dict[str, set[tuple[str, str]]] = {}
    with TM_CLUBS_CACHE.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            country = comps.get(row["domestic_competition_id"], "")
            country = country_alias.get(country, country)
            code = resolve_code(row["name"], country=country, club_key=row["club_id"])
            identity = (normalize_name(row["name"]), country)
            by_code.setdefault(code, set()).add(identity)

    collisions = {code: identities for code, identities in by_code.items()
                 if len(identities) > 1}
    assert not collisions, f"{len(collisions)} club-code collision(s) remain: {collisions}"
