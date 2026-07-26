"""Shared soccer club short-code resolution — the single entry point both
`transfermarkt_soccer.py` and `espn_soccer.py` call to derive `team_abbr`, replacing each
provider's previously-uncoordinated call to a bare word-initials heuristic.

Root cause this module fixes: the heuristic (1 word -> first 3 letters, 2+ words -> initial
+ first-2-of-word-2, after stripping legal/organizational boilerplate) was never checked for
global uniqueness, and neither was the curated override table it sits under. Confirmed live:
101 of 657 derived codes collided across differently-named clubs — e.g. BRO was both
Blackburn Rovers (England) and Brisbane Roar (Australia); soccer_espn_seasons.csv rows for
team_abbr=BRO, season_year in {2009,2010,2011} mixed real Blackburn players with real
Brisbane Roar players under one key.

Resolution order (see `resolve_code`):
  1. `_KNOWN_CODES` — Transfermarkt club_id -> curated code. Only usable by a caller that
     has a real TM club_id (i.e. `transfermarkt_soccer.py`'s own aggregation path).
  2. `_NAME_COUNTRY_CODES` — the same curation, but keyed by normalized (club name,
     country) instead of a TM id, so a source with no TM id at all (ESPN only ever has a
     free-text display name + a league->country label) still benefits from it. Every entry
     here is one of `_KNOWN_CODES`'s own clubs, so both providers agree on a famous club's
     code regardless of which one ingests it first.
  3. `_short_code()` — the original word-initials heuristic, unchanged (existing ingested
     data depends on its exact output for every club that doesn't collide — this is the
     compatibility contract with already-ingested rows).
  4. `data/soccer_club_code_overrides.csv` — the committed disambiguation table. Only
     entries for a (name, country) whose heuristic code collides with a DIFFERENT club's
     code somewhere in the known club universe get a row here; every unambiguous code
     (MCI, LIV, ...) is untouched, so this fix never changes an already-correct code.

All four layers are deterministic (same inputs -> same output). Together they must produce
globally unique codes across the known club universe — enforced by each provider's own
refresh()-time uniqueness assertion, and by `tests/test_club_codes.py`'s property test over
`.cache/tm_clubs.csv`.
"""
from __future__ import annotations

import csv
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
OVERRIDES_PATH = DATA_DIR / "soccer_club_code_overrides.csv"

# Tokens that are legal/organizational boilerplate in a club's long-form name
# ("Manchester City Football Club", "Real Madrid Club de Fútbol"), not identity.
_FILLER = {
    "fc", "cf", "afc", "cfc", "ssc", "ac", "as", "ss", "sv", "sk", "fk", "bk", "jk",
    "nk", "rc", "cd", "ca", "sad", "spa", "ev", "ag",
    "club", "clube", "football", "futbol", "fútbol", "futebol", "fußball", "calcio",
    "balompié", "association", "associazione", "sociedade", "sport", "sports",
    "sporting", "sportive", "spor", "kulübü", "verein", "vereniging",
    "voetbalvereniging", "de", "do", "da", "di", "la", "le", "el", "of", "and", "und",
    "e", "the", "aş", "sa", "sdd", "team",
}


def _words(club_name: str) -> list[str]:
    """Club name -> alnum-only tokens with boilerplate/digits stripped (shared by
    `_short_code` and `_normalize_name` so they agree on what counts as "identity")."""
    words = ["".join(ch for ch in w if ch.isalnum())
             for w in club_name.replace("-", " ").split()]
    words = [w for w in words
             if len(w) > 1 and w.lower() not in _FILLER and not w.isdigit()]
    if not words:  # nothing but boilerplate ("B SAD") — fall back to raw letters
        words = ["".join(ch for ch in club_name if ch.isalnum()) or club_name]
    return words


def _short_code(club_name: str) -> str:
    """Display short code for a club without a curated entry: strip boilerplate tokens,
    then 1 word -> first 3 letters, 2+ words -> initial + first 2 of the second word
    (reproduces MCI / MUN / RMA from their full names by itself). Unchanged from the
    pre-fix heuristic — existing ingested data depends on this exact output for every
    club that doesn't collide with another."""
    words = _words(club_name)
    if len(words) == 1:
        return words[0][:3].upper()
    return (words[0][0] + words[1][:2]).upper()


def normalize_name(club_name: str) -> str:
    """Club name -> a lowercase, boilerplate-stripped key so e.g. Transfermarkt's
    'Manchester City Football Club' and ESPN's 'Manchester City' resolve to the same
    curated/override entry."""
    return " ".join(w.lower() for w in _words(club_name))


def normalize_country(country: str | None) -> str:
    return (country or "").strip()


# ---------------------------------------------------------------------------
# Layer 1 — Transfermarkt club_id -> curated code (seed codes first — MCI/LIV/CHE/...
# must match soccer_seed.csv exactly so rosters merge — then common broadcast codes for
# other famous clubs where the derived heuristic is ugly or, as discovered while fixing
# this bug, collides with an unrelated club: e.g. Burnley (curated BUR) collides with
# Bursaspor's heuristic BUR; Ajax (curated AJA) collides with AC Ajaccio's heuristic AJA).
_KNOWN_CODES: dict[str, str] = {
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

# Layer 1b — clubs the M17 collision audit confirmed need protecting even though they
# aren't in the Transfermarkt dataset this pipeline currently sweeps (Blackburn Rovers
# never appears in `.cache/tm_clubs.csv`'s current snapshot — it's ESPN-only coverage).
# Live data already has real player-seasons under team_abbr=BRO for Blackburn (verified in
# `soccer_espn_seasons.csv`), so BRO must keep meaning Blackburn, not silently flip.
_EXTRA_KNOWN: dict[tuple[str, str], str] = {
    ("blackburn rovers", "England"): "BRO",
}

# Layer 2 — the name+country-keyed counterpart to `_KNOWN_CODES`, for providers (ESPN)
# that only ever see a free-text display name, never a Transfermarkt club_id. Every value
# here matches `_KNOWN_CODES`'s corresponding entry; each key is that club's Transfermarkt
# long-form name (what `transfermarkt_soccer.py`'s `clubs.csv` actually contains) plus its
# common short display name (closer to what ESPN's `roster.team.displayName` returns),
# both normalized, so either source lands on the same code for the same famous club.
_CURATED_ALIASES: list[tuple[list[str], str, str]] = [
    # England
    (["Manchester City Football Club", "Manchester City"], "England", "MCI"),
    (["Manchester United Football Club", "Manchester United"], "England", "MUN"),
    (["Liverpool Football Club", "Liverpool"], "England", "LIV"),
    (["Chelsea Football Club", "Chelsea"], "England", "CHE"),
    (["Arsenal Football Club", "Arsenal"], "England", "ARS"),
    (["Tottenham Hotspur Football Club", "Tottenham Hotspur", "Tottenham"], "England", "TOT"),
    (["Aston Villa Football Club", "Aston Villa"], "England", "AVL"),
    (["Burnley Football Club", "Burnley"], "England", "BUR"),
    (["Newcastle United Football Club", "Newcastle United"], "England", "NEW"),
    (["West Ham United Football Club", "West Ham United"], "England", "WHU"),
    (["Everton Football Club", "Everton"], "England", "EVE"),
    (["Wolverhampton Wanderers Football Club", "Wolverhampton Wanderers"], "England", "WOL"),
    (["Crystal Palace Football Club", "Crystal Palace"], "England", "CRY"),
    (["Brighton and Hove Albion Football Club", "Brighton and Hove Albion", "Brighton & Hove Albion"], "England", "BHA"),
    (["Nottingham Forest Football Club", "Nottingham Forest"], "England", "NFO"),
    (["Association Football Club Bournemouth", "AFC Bournemouth", "Bournemouth"], "England", "BOU"),
    (["Brentford Football Club", "Brentford"], "England", "BRE"),
    (["Leeds United Association Football Club", "Leeds United"], "England", "LEE"),
    (["Blackburn Rovers Football Club", "Blackburn Rovers"], "England", "BRO"),
    # Spain
    (["Real Madrid Club de Fútbol", "Real Madrid"], "Spain", "RMA"),
    (["Futbol Club Barcelona", "Barcelona"], "Spain", "FCB"),
    (["Club Atlético de Madrid S.A.D.", "Atletico Madrid", "Atlético Madrid"], "Spain", "ATM"),
    (["Sevilla Fútbol Club S.A.D.", "Sevilla"], "Spain", "SEV"),
    (["Valencia Club de Fútbol S. A. D.", "Valencia"], "Spain", "VAL"),
    (["Villarreal Club de Fútbol S.A.D.", "Villarreal"], "Spain", "VIL"),
    (["Real Betis Balompié S.A.D.", "Real Betis"], "Spain", "BET"),
    (["Athletic Club Bilbao", "Athletic Bilbao", "Athletic Club"], "Spain", "ATH"),
    (["Real Sociedad de Fútbol S.A.D.", "Real Sociedad"], "Spain", "RSO"),
    # Germany
    (["FC Bayern München", "Bayern Munich", "Bayern München"], "Germany", "BAY"),
    (["Borussia Dortmund"], "Germany", "BVB"),
    (["Bayer 04 Leverkusen Fußball", "Bayer Leverkusen"], "Germany", "LEV"),
    (["RasenBallsport Leipzig", "RB Leipzig"], "Germany", "RBL"),
    (["Borussia Verein für Leibesübungen 1900 Mönchengladbach",
      "Borussia Monchengladbach", "Borussia Mönchengladbach"], "Germany", "BMG"),
    (["Eintracht Frankfurt Fußball AG", "Eintracht Frankfurt"], "Germany", "EIN"),
    (["FC Schalke 04", "Schalke 04", "Schalke"], "Germany", "S04"),
    (["Verein für Bewegungsspiele Stuttgart 1893", "VfB Stuttgart", "Stuttgart"], "Germany", "STU"),
    (["Verein für Leibesübungen Wolfsburg", "VfL Wolfsburg", "Wolfsburg"], "Germany", "WOB"),
    # Italy
    (["Juventus Football Club", "Juventus"], "Italy", "JUV"),
    (["Football Club Internazionale Milano S.p.A.", "Inter Milan", "Internazionale"], "Italy", "INT"),
    (["Associazione Calcio Milan", "AC Milan", "Milan"], "Italy", "MIL"),
    (["Società Sportiva Calcio Napoli", "Napoli"], "Italy", "NAP"),
    (["Associazione Sportiva Roma", "AS Roma", "Roma"], "Italy", "ROM"),
    (["Società Sportiva Lazio S.p.A.", "Lazio"], "Italy", "LAZ"),
    (["Atalanta Bergamasca Calcio S.p.a.", "Atalanta"], "Italy", "ATA"),
    (["Associazione Calcio Fiorentina", "Fiorentina"], "Italy", "FIO"),
    # France
    (["Paris Saint-Germain Football Club", "Paris Saint-Germain", "PSG"], "France", "PSG"),
    (["Olympique de Marseille", "Marseille"], "France", "MAR"),
    (["Olympique Lyonnais", "Lyon"], "France", "LYO"),
    (["Association sportive de Monaco Football Club", "AS Monaco", "Monaco"], "France", "MON"),
    (["Lille Olympique Sporting Club", "Lille"], "France", "LIL"),
    # Portugal / Netherlands / Scotland / Turkey
    (["Futebol Clube do Porto", "FC Porto", "Porto"], "Portugal", "POR"),
    (["Sport Lisboa e Benfica", "Benfica"], "Portugal", "BEN"),
    (["Sporting Clube de Portugal", "Sporting CP", "Sporting Lisbon"], "Portugal", "SPO"),
    (["AFC Ajax Amsterdam", "Ajax", "AFC Ajax"], "Netherlands", "AJA"),
    (["Eindhovense Voetbalvereniging Philips Sport Vereniging", "PSV Eindhoven", "PSV"], "Netherlands", "PSV"),
    (["Feyenoord Rotterdam", "Feyenoord"], "Netherlands", "FEY"),
    (["The Celtic Football Club", "Celtic"], "Scotland", "CEL"),
    (["Rangers Football Club", "Rangers"], "Scotland", "RAN"),
    (["Galatasaray Spor Kulübü", "Galatasaray"], "Turkey", "GAL"),
    (["Fenerbahçe Spor Kulübü", "Fenerbahce", "Fenerbahçe"], "Turkey", "FEN"),
    (["Beşiktaş Jimnastik Kulübü", "Besiktas", "Beşiktaş"], "Turkey", "BES"),
]


def _build_name_country_codes() -> dict[tuple[str, str], str]:
    table: dict[tuple[str, str], str] = dict(_EXTRA_KNOWN)
    for names, country, code in _CURATED_ALIASES:
        for name in names:
            table[(normalize_name(name), country)] = code
    return table


_NAME_COUNTRY_CODES: dict[tuple[str, str], str] = _build_name_country_codes()


# ---------------------------------------------------------------------------
# Layer 4 — committed collision-override table

def _load_overrides() -> dict[tuple[str, str], str]:
    if not OVERRIDES_PATH.exists():
        return {}
    with OVERRIDES_PATH.open(encoding="utf-8", newline="") as f:
        return {(row["normalized_name"], row["country"]): row["code"]
                for row in csv.DictReader(f)}


_OVERRIDES: dict[tuple[str, str], str] = _load_overrides()


def reload_overrides() -> None:
    """Re-read `soccer_club_code_overrides.csv` from disk (tests monkeypatch
    `OVERRIDES_PATH` then call this to pick up a fixture file)."""
    global _OVERRIDES
    _OVERRIDES = _load_overrides()


# ---------------------------------------------------------------------------
# public entry point

def resolve_code(club_name: str, country: str | None = None,
                  club_key: str | None = None) -> str:
    """The single short-code resolution path for both soccer providers.

    Order: curated club_id lookup (`club_key`, e.g. a Transfermarkt club_id) -> curated
    (normalized name, country) lookup -> the `_short_code()` heuristic -> the committed
    collision-override table. `country` should be the same country/league label both
    providers already write to `player_seasons.league` (e.g. "England"), so all three
    lookup layers agree with each other.
    """
    if club_key and club_key in _KNOWN_CODES:
        return _KNOWN_CODES[club_key]

    name_key = (normalize_name(club_name), normalize_country(country))
    if name_key in _NAME_COUNTRY_CODES:
        return _NAME_COUNTRY_CODES[name_key]

    code = _short_code(club_name)

    override = _OVERRIDES.get(name_key)
    return override or code


def assert_globally_unique(rows: list[dict]) -> None:
    """Group already-resolved rows by `team_abbr`; raise if two different (name, country)
    club identities share a code. Call this at the end of each provider's `refresh()` —
    the CI regression guard that should have caught the BRO/BRE/BUR collisions originally.
    `rows` must have `team_abbr` plus either `club_name`/`league` or `name`/`league` keys
    identifying the club (callers pass whatever they have; see the two providers'
    `refresh()` for the exact shape).

    Identity is compared on the NORMALIZED name, not the raw display string — two records
    that normalize alike in one country are the same club by this module's own definition
    (it is the key every resolution layer above is written against), so treating them as
    distinct here would contradict `resolve_code` and flag a collision no override could
    ever fix. Transfermarkt is full of these: a refounded club keeps a separate club_id for
    its predecessor ('Karpaty Lviv (-2021)' alongside 'FK Karpaty Lviv', 'Metalist Kharkiv
    (- 2016)' alongside 'Metalist Kharkiv'), and `normalize_name` strips the era suffix, so
    both records legitimately share one code and one continuous club history. The real
    collisions this guards against — Blackburn Rovers vs Brisbane Roar, both heuristic
    'BRO' — normalize differently and are still caught."""
    by_code: dict[str, set[tuple[str, str]]] = {}
    for row in rows:
        code = row["team_abbr"]
        identity = (normalize_name(row["club_identity"]), row.get("league") or "")
        by_code.setdefault(code, set()).add(identity)
    collisions = {code: identities for code, identities in by_code.items()
                  if len(identities) > 1}
    if collisions:
        details = "; ".join(
            f"{code} -> {sorted(identities)}" for code, identities in sorted(collisions.items()))
        raise ValueError(f"club_codes: {len(collisions)} team_abbr collision(s) across "
                          f"distinct clubs: {details}")
