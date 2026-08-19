"""Generate the Journeyman subject pool — one career path per subject, from the live catalog.

A Journeyman board is a player's club history and nothing else: crest, club name, year span,
in chronological order, revealed one club at a time. That makes this module's whole job the
run-length encoding of `player_seasons` by team — plus the honesty gates that decide whether a
path is safe to show at all.

## It reuses Who Am I?'s subject qualification wholesale, on purpose

"Which players are nameable?" is a question this pipeline already answered once, carefully:
`whoami_pool.qualify` enforces a headshot, a name unique within its sport, a real career
length, a production floor within the position cohort, a followed league for soccer, and the
merged-career (two same-name players welded into one row) rejection. Journeyman needs the
identical floor, so it calls the identical code rather than growing a second opinion about who
counts as identifiable (AGENTS.md §4). Fame percentiles and difficulty tiers come from the same
place for the same reason.

## What this module adds on top, and why each gate exists

- **≥ `MIN_STINTS` clubs.** A one-club career has no path to reveal. Soccer needs three: two
  clubs is the *median* soccer career in this catalog, not a journeyman's.
- **Every club nameable.** `whoami_pool.team_display` returns "" for codes that named two
  different franchises depending on the year (`nba NO` was the Hornets and is now the
  Pelicans), for All-Star rosters, and for the ~2k catalog rows with an empty `team_abbr`. A
  board with a "?" in it is not a puzzle, so one unnameable stint drops the whole subject.
- **A contiguous career.** The board claims to be the player's *whole* club history, so a hole
  in it is a lie, not a gap. Soccer's sweep is country-by-country: a player who spent three
  years in a league the sweep doesn't cover would otherwise appear to have gone straight from
  Ajax to Arsenal. `contiguous()` rejects any path with a gap wider than one year (one year is
  a missed/injury season, which is real and shows up inside a stint too).
- **A career that starts inside coverage.** Same lie, at the front, and the one that bit
  hardest in practice — NFL defensive rows only start in 1999 and soccer's sweep only thickens
  in 2013. `coverage_floors()` measures where each position's history actually becomes
  trustworthy rather than assuming the catalog's own first year is it.
- **≤ `MAX_STINTS` clubs shown.** A 14-row board is unreadable and unplayable. Longer paths
  keep their most recent clubs and set `truncated`, which the app states on the board — a
  player counting clubs deserves to know the count is a floor.

Written to `data/journeyman_pool.json` for `daily_journeyman.py` to rotate through, for exactly
the reason `whoami_pool` commits its own file: the nightly mint reads a JSON file in seconds
instead of re-folding ~200k catalog rows.

Examples:
    python -m tools.ingest.journeyman --dry-run                 # what would be generated
    python -m tools.ingest.journeyman --write                   # refresh every sport
    python -m tools.ingest.journeyman --write --write-bundle    # + the app's offline fallback
    python -m tools.ingest.journeyman --upsert                  # archival rows -> Supabase
"""
from __future__ import annotations

import argparse
import collections
import json
import statistics
from dataclasses import asdict, dataclass, field

from . import main as ingest_main
from . import whoami_pool
from .assemble import PuzzleRow
from .models import slug
from .whoami_clues import DIFFICULTIES, tier_for_fame

POOL_FILE = "journeyman_pool.json"

# Clubs needed to make a path worth guessing, per sport. Soccer's three is not a stylistic
# preference: two clubs is an ordinary soccer career, so a two-club soccer board would mostly
# be "name a striker who was at these two clubs", which the Grid already does better.
MIN_STINTS: dict[str, int] = {"nfl": 2, "nba": 2, "baseball": 2, "soccer": 3}

# Clubs rendered. Truncation keeps the MOST RECENT clubs (the end of a career is what a fan
# remembers) and the board says so.
MAX_STINTS = 8

# ── Coverage floors: the year each position's history becomes trustworthy ─────
#
# The board claims to be a player's WHOLE club history, so a career that began before the
# catalog covers it doesn't produce a short board — it produces a false one, missing its first
# clubs entirely. Two measured examples, both live in this catalog today:
#   - NFL defensive rows start in **1999** (0 defenders in 1998, 701 in 1999). Charles Woodson's
#     1998 Raiders debut simply isn't there, and a defender who moved clubs in 1997 would have
#     his first club silently deleted.
#   - Soccer's sweep is thin until **2013** (344 players in 2012, 4,854 in 2013), so Cristiano
#     Ronaldo's catalog career starts at Real Madrid and never mentions Sporting or United.
#
# These are derived from the fetched rows rather than written down, because a literal encoding
# "where coverage starts today" goes stale the moment a provider backfills (AGENTS.md §2) —
# and it would have to be written per position, which is where the NFL case actually lives.
#
# A position's floor is the start of the contiguous run of well-covered years that reaches the
# present, plus a margin: a player whose first season IS the first covered year is exactly the
# player whose earlier seasons were cut off.
DENSITY_SHARE = 0.5      # a year is "covered" at half the position's recent median headcount

# Years of clearance a debut needs above the first covered year, per sport. One is enough where
# a career lives in a single league this catalog sweeps whole. Soccer needs three: its sweep is
# the top divisions of ~38 countries, so a European career routinely begins in a league it never
# saw at all — Mohamed Salah's two Basel seasons simply aren't here, and with one year of
# clearance the board opened his career at Chelsea.
COVERAGE_MARGIN: dict[str, int] = {"soccer": 3}


def coverage_floors(season_rows: list[dict], margin: int = 1) -> dict[str, int]:
    """`position -> earliest debut year a complete club history can be claimed for`."""
    names_by: dict[str, dict[int, set[str]]] = collections.defaultdict(
        lambda: collections.defaultdict(set))
    for row in season_rows:
        names_by[row.get("position") or ""][int(row["season_year"])].add(row["name"])

    floors: dict[str, int] = {}
    for position, years in names_by.items():
        counts = {year: len(names) for year, names in years.items()}
        ordered = sorted(counts)
        threshold = DENSITY_SHARE * statistics.median(
            [counts[y] for y in ordered[-10:]] or [0])
        covered = [y for y in ordered if counts[y] >= threshold]
        if not covered:
            floors[position] = ordered[0] if ordered else 0
            continue
        # Walk back from the most recent well-covered year while the years stay covered, so a
        # sparse pre-history (or a partially-played current season) can't anchor the run.
        year = covered[-1]
        while counts.get(year - 1, 0) >= threshold:
            year -= 1
        floors[position] = year + margin
    return floors

# Years a path may skip before it reads as missing coverage rather than a missed season. One
# covers an injury year, a lockout, or a season out of the league; two in a row is a spell this
# pipeline didn't see.
MAX_PATH_GAP = 1

PER_SPORT_CAP = 150

# Same mix as Who Am I? — easy/medium carry the daily, hard is the spice and the points.
TIER_MIX: dict[str, float] = dict(whoami_pool.TIER_MIX)

# ── Era-aware franchise naming ─────────────────────────────────────────────────
#
# `whoami_pool.FRANCHISES` names a code with ONE nickname, which is right for a clue that says
# "played for the Titans" and wrong here: this board prints a nickname next to a year span, so a
# code its franchise renamed under has to be named per era or the board states a falsehood. The
# live pool's first draft offered "Eddie George — Texans 1996 → Titans 1997-2003": he played for
# the Houston OILERS in 1996, and the Texans did not exist until 2002.
#
# `(sport, abbr) -> ((through_year, name), ...)`, earliest first; a season is named by the first
# window whose `through_year` it does not exceed, falling through to `FRANCHISES` after the last.
# Deliberately tiny — only codes one franchise handed to another, or renamed under. A relocation
# that kept the nickname (San Diego → Los Angeles Chargers) needs no entry, because the nickname
# is what this board prints.
ERA_FRANCHISES: dict[tuple[str, str], tuple[tuple[int, str], ...]] = {
    ("nfl", "HOU"): ((1996, "Oilers"),),          # Oilers through 1996; Texans from 2002
    ("nfl", "TEN"): ((1998, "Oilers"),),          # Tennessee Oilers 1997-98, Titans from 1999
    ("nfl", "BAL"): ((1983, "Colts"),),           # Colts through 1983; Ravens from 1996
    ("baseball", "TB"): ((2007, "Devil Rays"),),  # renamed Rays for 2008
}


@dataclass(frozen=True)
class ClubNames:
    """Soccer club names, keyed the only way that is actually unique: `(code, country)`.

    A bare code is not an identity in this catalog. Deportivo Alavés is `DAL` in Spain and FC
    Dallas is `DAL` in MLS, so the flat `{code: name}` map `whoami_pool` builds resolved Marcos
    Llorente's 2017 Alavés season to "FC Dallas" — a club he has never played for, on a board
    whose entire content is club names. `by_abbr` is the fallback for the rows the catalog left
    without a country, and deliberately holds only codes that ARE unambiguous: guessing between
    two clubs is exactly the failure this class exists to stop.
    """
    by_key: dict[tuple[str, str], str]
    by_abbr: dict[str, str]

    def name(self, abbr: str, league: str) -> str:
        if league:
            return self.by_key.get((abbr, league), "")
        return self.by_abbr.get(abbr, "")

    @classmethod
    def build(cls, rows: list[dict]) -> "ClubNames":
        contested = contested_club_codes(rows)
        by_key: dict[tuple[str, str], str] = {}
        seen: dict[str, set[str]] = collections.defaultdict(set)
        for row in rows:
            if row.get("sport") != "soccer":
                continue
            name = (row.get("full_name") or "").strip()
            league = row.get("league") or ""
            if not name or (row["team_abbr"], league) in contested:
                continue
            by_key[(row["team_abbr"], league)] = name
            seen[row["team_abbr"]].add(name)
        return cls(by_key, {abbr: next(iter(names))
                            for abbr, names in seen.items() if len(names) == 1})


def contested_club_codes(team_rows: list[dict]) -> set[tuple[str, str]]:
    """`(code, country)` pairs where the `teams` sweep's club is **not** the club that code
    means to a fan — so the code cannot be named, and any career touching it is dropped.

    This guards a real, pre-existing defect in the upstream code derivation rather than one
    Journeyman introduced. `providers/club_codes.resolve_code` derives "POR" for both FC Porto
    and Portimonense in Portugal; the `teams` sweep happens to hold Portimonense under it and
    Porto not at all, so Luis Díaz's three Porto seasons rendered as "Portimonense 2020-2022"
    on a live board. The same ambiguity is latent in every surface that shows a soccer club
    name — it is only *loud* here, where club names are the entire puzzle.

    The signal is the curated club table `club_codes` already maintains: it is the list of
    clubs this audience actually knows, keyed by (normalized name, country) and mapped to the
    code each one should own. When the sweep's club sits on a code a *different* curated club
    claims, the code is contested and nobody gets named by it.
    """
    from .providers import club_codes

    claimed: dict[tuple[str, str], set[str]] = collections.defaultdict(set)
    for (norm_name, country), code in club_codes._NAME_COUNTRY_CODES.items():
        claimed[(code, country)].add(norm_name)

    contested: set[tuple[str, str]] = set()
    for row in team_rows:
        if row.get("sport") != "soccer":
            continue
        name = (row.get("full_name") or "").strip()
        league = row.get("league") or ""
        if not name:
            continue
        key = (row["team_abbr"], league)
        owners = claimed.get(key)
        if owners and club_codes.normalize_name(name) not in owners:
            contested.add(key)
    return contested


def load_club_names() -> ClubNames:
    from .upsert import fetch_teams
    return ClubNames.build(fetch_teams())


def stint_name(sport: str, abbr: str, year: int,
               clubs: ClubNames, league: str = "") -> tuple[str, bool]:
    """`(club name for that season, whether it's a historical name)`.

    "Historical" means the code names a *different* franchise today, which is also the signal
    the client needs to skip the crest lookup: ESPN's `nfl/hou` badge is the Texans, and hanging
    it next to "Oilers 1996" would undo the naming fix. Defunct codes that were never reused
    (`SD`, `SEA`, `NJN`) are NOT historical in this sense — their own crest is still the right
    one, and the CDN still serves it.
    """
    modern = (clubs.name(abbr, league) if sport == "soccer"
              else whoami_pool.team_display(sport, abbr, {}))
    for through, name in ERA_FRANCHISES.get((sport, abbr), ()):
        if year <= through:
            return name, name != modern
    return modern, False


@dataclass(frozen=True)
class Stint:
    """One unbroken spell at one club, in the shape the Swift `JourneymanPuzzle.Stint`
    decodes. `league` is "" for the US sports and the country label for soccer, where a club
    code alone is not unique (BRO is Blackburn Rovers and Brisbane Roar)."""
    team_abbr: str
    team_name: str
    league: str
    first_year: int
    last_year: int
    # True when `team_abbr` names a different franchise today, so the modern crest would
    # contradict the label — see `stint_name`. Defaults False so existing pool files load.
    historical: bool = False


@dataclass
class JourneymanEntry:
    sport: str
    canonical: str
    position: str
    headshot: str
    stints: list[Stint]
    difficulty: str
    fame: float
    truncated: bool = False
    aliases: list[str] = field(default_factory=list)

    @property
    def key(self) -> str:
        return slug(self.canonical)


# ── The career path ───────────────────────────────────────────────────────────

def build_stints(sport: str, rows: list[dict],
                 clubs: ClubNames) -> tuple[list[Stint], int]:
    """`(stints, unnameable_count)` — the run-length encoding of `rows` by club, in year order.

    A **run**, not a de-duplication: a player who left and came back gets two stints, which is
    the format's best material (Ronaldo's two United spells are the giveaway, and collapsing
    them would delete the joke). `whoami_pool._career_order_teams` deliberately does the
    opposite for its clue text, which is why this doesn't reuse it.

    A season with two clubs (a mid-season trade) is the one place year order isn't enough, and
    ordering those alphabetically is actively wrong: SF 2019-2020 + NYJ 2020-2021 encodes as
    SF → NYJ → SF → NYJ, inventing a return spell that never happened. The catalog records no
    within-season dates, so the tie is broken on continuity instead — the club the player was
    *already* at comes first, the club they're at *next* year comes last. Both stints then carry
    the shared year, which is exactly what happened.

    Runs are keyed on the **club name**, not the code, because the catalog spells one franchise
    several ways across eras: Charles Woodson's Oakland years arrive as both `OAK` and `LV`, and
    keying on the code split them into "Raiders → Raiders", a transfer to the club he was
    already at. Keying on the name also lets a genuine rebrand (Oilers → Titans, both `TEN`)
    show up as the two clubs a fan remembers.
    """
    years_by_club: dict[str, set[int]] = collections.defaultdict(set)
    for row in rows:
        years_by_club[(row.get("team_abbr") or "").strip()].add(int(row["season_year"]))

    def within_year_rank(row: dict) -> tuple[int, str]:
        abbr = (row.get("team_abbr") or "").strip()
        year = int(row["season_year"])
        seen = years_by_club[abbr]
        if year - 1 in seen:
            return (0, abbr)          # continuing from last season
        if year + 1 in seen:
            return (2, abbr)          # they're still here next season, so they arrived
        return (1, abbr)

    ordered = sorted(rows, key=lambda r: (int(r["season_year"]), within_year_rank(r)))
    stints: list[Stint] = []
    unnameable = 0
    for row in ordered:
        abbr = (row.get("team_abbr") or "").strip()
        if (sport, abbr) in whoami_pool.EXHIBITION_TEAM_CODES:
            continue          # All-Star rosters aren't clubs — not a naming failure
        year = int(row["season_year"])
        league = (row.get("league") or "") if sport == "soccer" else ""
        name, historical = stint_name(sport, abbr, year, clubs, league)
        if not name:
            unnameable += 1
            continue
        if stints and stints[-1].team_name == name:
            last = stints[-1]
            # `league` is only ever the crest/palette qualifier, and the catalog leaves it NULL
            # on some rows (Ronaldo's 2015 Real Madrid season has no country). Comparing it as
            # part of the run key split that spell into "Real Madrid → Real Madrid", so a run
            # keeps the first country it *has* and an unlabelled row joins the run it belongs to.
            stints[-1] = Stint(last.team_abbr, last.team_name, last.league or league,
                               min(last.first_year, year), max(last.last_year, year),
                               last.historical)
        else:
            stints.append(Stint(abbr, name, league, year, year, historical))
    return stints, unnameable


def contiguous(stints: list[Stint]) -> bool:
    """True when the path has no hole wider than `MAX_PATH_GAP` — see the module docstring on
    why a hole is a lie rather than a gap. Overlapping stints (a mid-season move) are fine."""
    for prev, nxt in zip(stints, stints[1:]):
        if nxt.first_year - prev.last_year > MAX_PATH_GAP + 1:
            return False
    return True


def truncate(stints: list[Stint]) -> tuple[list[Stint], bool]:
    """The clubs the board shows, most recent kept, and whether anything was dropped."""
    if len(stints) <= MAX_STINTS:
        return stints, False
    return stints[-MAX_STINTS:], True


def qualifies(sport: str, stints: list[Stint], unnameable: int, first_year: int,
              floor: int = 0) -> bool:
    if unnameable:
        return False
    if first_year < floor:
        return False
    if len(stints) < MIN_STINTS.get(sport, 2):
        return False
    return contiguous(stints)


# ── Pool assembly ─────────────────────────────────────────────────────────────

def _headshot(rows: list[dict]) -> str:
    """The most recent row's photo — the same "latest row wins" rule `WhoAmIAnswerPhoto` uses
    client-side, so the reveal card shows the player as fans last saw them."""
    for row in sorted(rows, key=lambda r: r["season_year"], reverse=True):
        if (row.get("headshot") or "").strip():
            return row["headshot"].strip()
    return ""


def build_entries(career_rows: list[dict], season_rows: list[dict],
                  clubs: ClubNames, sport: str = "") -> list[JourneymanEntry]:
    """Qualified subjects with their career paths attached.

    Qualification is `whoami_pool`'s (see the module docstring); this adds the path gates. The
    season rows are re-grouped by name here because `build_candidates` folds them away, and the
    join key is a name for the same documented reason it is there — the catalog has no id that
    identifies a *person* across grains, which is exactly why `qualify` drops shared names.
    """
    by_name: dict[str, list[dict]] = collections.defaultdict(list)
    for row in season_rows:
        by_name[row["name"]].append(row)

    candidates = whoami_pool.build_candidates(career_rows, season_rows, clubs.by_abbr)
    qualified = [c for c in candidates if c.sport in MIN_STINTS]
    qualified = whoami_pool.qualify(qualified)
    fame = whoami_pool.blended_fame(qualified)
    floors = coverage_floors(season_rows, margin=COVERAGE_MARGIN.get(sport, 1))

    entries: list[JourneymanEntry] = []
    for c in qualified:
        rows = by_name.get(c.name, [])
        stints, unnameable = build_stints(c.sport, rows, clubs)
        if not qualifies(c.sport, stints, unnameable, c.first_year,
                         floor=floors.get(c.position, 0)):
            continue
        shown, was_truncated = truncate(stints)
        entries.append(JourneymanEntry(
            sport=c.sport,
            canonical=c.name,
            position=c.position,
            headshot=_headshot(rows),
            stints=shown,
            difficulty=tier_for_fame(fame[c.key]),
            fame=round(fame[c.key], 4),
            truncated=was_truncated,
        ))
    return entries


def select(entries: list[JourneymanEntry], cap: int = PER_SPORT_CAP) -> list[JourneymanEntry]:
    """`cap` entries, filled per tier best-fame-first — so "45 hard" is the 45 most
    identifiable of the hard tier, not a random 45 from the tail. Same shape as
    `whoami_pool.select`, and unfilled tier quota spills into the others rather than shrinking
    the pool (a sport with few easy subjects should still get a full pool)."""
    by_tier: dict[str, list[JourneymanEntry]] = {t: [] for t in DIFFICULTIES}
    for e in sorted(entries, key=lambda e: -e.fame):
        by_tier[e.difficulty].append(e)
    picked: list[JourneymanEntry] = []
    for tier in DIFFICULTIES:
        picked.extend(by_tier[tier][:round(cap * TIER_MIX[tier])])
    if len(picked) < cap:
        chosen = {id(e) for e in picked}
        for e in sorted(entries, key=lambda e: -e.fame):
            if len(picked) >= cap:
                break
            if id(e) not in chosen:
                picked.append(e)
    return picked


def generate_for_sport(sport: str, clubs: ClubNames) -> list[JourneymanEntry]:
    from .upsert import WHOAMI_CATALOG_COLUMNS, fetch_player_seasons
    cols = WHOAMI_CATALOG_COLUMNS
    career_rows = fetch_player_seasons(sport, career=True, columns=cols)
    season_rows = fetch_player_seasons(sport, columns=cols)
    print(f"[journeyman] {sport}: {len(career_rows)} career + {len(season_rows)} season rows")

    entries = build_entries(career_rows, season_rows, clubs, sport=sport)
    picked = select(entries)
    tiers = collections.Counter(e.difficulty for e in picked)
    paths = collections.Counter(len(e.stints) for e in picked)
    print(f"[journeyman] {sport}: {len(entries)} qualified → {len(picked)} kept "
          f"({', '.join(f'{t}: {tiers[t]}' for t in DIFFICULTIES)}); "
          f"clubs per board {dict(sorted(paths.items()))}")
    return picked


# ── Rows ──────────────────────────────────────────────────────────────────────

def build_row(entry: JourneymanEntry, suffix: str = "") -> PuzzleRow:
    """The `puzzles` row for one subject, in the exact camelCase shape `JourneymanPuzzle`
    decodes. `suffix` distinguishes the dated daily copy from the undated archival one."""
    puzzle_id = f"{entry.sport}-{entry.key}-journeyman{suffix}"
    content = {
        "id": puzzle_id,
        "sport": entry.sport,
        "difficulty": entry.difficulty,
        "answer": {"canonical": entry.canonical, "aliases": entry.aliases},
        "stints": [{
            "order": i + 1,
            "teamAbbr": s.team_abbr,
            "teamName": s.team_name,
            "league": s.league,
            "firstYear": s.first_year,
            "lastYear": s.last_year,
            **({"historical": True} if s.historical else {}),
        } for i, s in enumerate(entry.stints)],
    }
    if entry.position:
        content["position"] = entry.position
    if entry.headshot:
        content["headshot"] = entry.headshot
    if entry.truncated:
        content["truncated"] = True
    return PuzzleRow(id=puzzle_id, sport=entry.sport, format="journeyman", content=content)


# ── Pool file I/O ─────────────────────────────────────────────────────────────

def entry_to_json(entry: JourneymanEntry) -> dict:
    d = asdict(entry)
    d["stints"] = [asdict(s) for s in entry.stints]
    return d


def load_pool(path) -> list[JourneymanEntry]:
    if not path.exists():
        return []
    raw = json.loads(path.read_text(encoding="utf-8"))
    return [JourneymanEntry(**{**e, "stints": [Stint(**s) for s in e["stints"]]}) for e in raw]


def all_entries(data_dir) -> list[JourneymanEntry]:
    """Every pool entry, for the daily picker. Single source today (there is no hand-authored
    editorial layer like `whoami_facts.json`) — kept as its own function so adding one later
    doesn't change the picker."""
    return load_pool(data_dir / POOL_FILE)


def bundle_subset(entries: list[JourneymanEntry], per_sport: int = 30) -> list[JourneymanEntry]:
    """A balanced slice for the app's offline fallback — the bundle ships in the binary, so it
    is a sample of the pool, never the pool."""
    out: list[JourneymanEntry] = []
    for sport in sorted({e.sport for e in entries}):
        pool = [e for e in entries if e.sport == sport]
        for tier in DIFFICULTIES:
            share = round(per_sport * TIER_MIX[tier])
            out.extend([e for e in pool if e.difficulty == tier][:share])
    return out


def _write_bundle(entries: list[JourneymanEntry]) -> int:
    from .validate import validate
    subset = bundle_subset(entries)
    rows = [build_row(e) for e in subset]
    for row in rows:
        validate(row)
    ingest_main.FALLBACK_JOURNEYMAN.write_text(
        json.dumps([r.content for r in rows], indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8")
    sports = collections.Counter(r.sport for r in rows)
    print(f"[journeyman] bundle: {len(rows)} of {len(entries)} puzzles → "
          f"{ingest_main.FALLBACK_JOURNEYMAN}")
    print(f"[journeyman]   sports {dict(sorted(sports.items()))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate the Journeyman subject pool")
    ap.add_argument("--write", action="store_true", help=f"write data/{POOL_FILE}")
    ap.add_argument("--dry-run", action="store_true",
                    help="generate + print a per-tier sample, no file written")
    ap.add_argument("--sport", nargs="*", default=None,
                    help="limit to these sports (default: every team sport)")
    ap.add_argument("--write-bundle", action="store_true",
                    help="also refresh the app's offline fallback JSON from the pool file")
    ap.add_argument("--upsert", action="store_true",
                    help="upsert the pool as undated archival `puzzles` rows")
    args = ap.parse_args()
    if not (args.write or args.upsert or args.write_bundle):
        args.dry_run = True

    ingest_main.load_dotenv()
    path = ingest_main.DATA_DIR / POOL_FILE
    sports = args.sport or sorted(MIN_STINTS)

    if args.write or args.dry_run:
        clubs = load_club_names()
        generated: list[JourneymanEntry] = []
        for sport in sports:
            generated.extend(generate_for_sport(sport, clubs))
        if args.write:
            # Sports not regenerated in this run keep their existing entries, so
            # `--sport nfl` is a refresh of NFL rather than a truncation of the pool.
            kept = [e for e in load_pool(path) if e.sport not in sports]
            merged = kept + generated
            path.write_text(
                json.dumps([entry_to_json(e) for e in merged], indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8")
            print(f"[journeyman] wrote {len(merged)} entries ({len(kept)} kept) → {path}")
        else:
            for sport in sports:
                for tier in DIFFICULTIES:
                    sample = [e for e in generated if e.sport == sport and e.difficulty == tier][:3]
                    for e in sample:
                        path_text = " → ".join(f"{s.team_name} {s.first_year}"
                                               f"{'' if s.first_year == s.last_year else f'-{s.last_year}'}"
                                               for s in e.stints)
                        prefix = "… → " if e.truncated else ""
                        print(f"  {sport:8} {tier:6} {e.canonical:26} {prefix}{path_text}")

    entries = all_entries(ingest_main.DATA_DIR)
    if args.write_bundle:
        _write_bundle(entries)
    if args.upsert:
        from .upsert import upsert
        from .validate import validate
        rows = [build_row(e) for e in entries]
        for row in rows:
            validate(row)
        print(f"[journeyman] upserted {upsert(rows)} archival row(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
