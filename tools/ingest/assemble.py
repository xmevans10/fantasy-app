"""Assemble graded real seasons into puzzle rows in the exact camelCase shape the
Swift Codable models decode (Keep4Puzzle / WhoAmIPuzzle).

A "row" mirrors the `puzzles` table: {id, sport, format, content, active_date}.
`content` is the JSON the app reads.
"""
from __future__ import annotations

import json
from dataclasses import dataclass

from . import whoami_clues
from .grade import BaselineTable, grade, grade_era
from .models import RawSeason, WhoAmIEntry, slug
from .themes import Theme, format_columns

KEEP_COUNT = 8

# Sources whose photo-less rows are catalog/roster depth only, never puzzle cards
# (see the gate in `grade_pool`). Their photo-CARRYING rows compete normally.
# `espn` joined 2026-07-26 with the lower-division soccer sweeps: `--allow-missing-photos`
# keeps player-seasons Wikipedia has no photo for (11 of 609 ger.2 players did), which is
# right for a Draft & Spin roster row — the client renders an initial-avatar circle — and
# wrong for a Keep4 card, which IS the photo.
DEPTH_ONLY_WITHOUT_PHOTO = {"bref", "pfr", "espn"}


@dataclass
class PuzzleRow:
    id: str
    sport: str
    format: str          # 'keep4' | 'whoami'
    content: dict
    active_date: str | None = None


# ── Keep4 ─────────────────────────────────────────────────────────────────────

def _player_content(theme: Theme, season: RawSeason, value: float) -> dict:
    content = {
        "id": season.player_id,
        "name": season.name,
        "teamAbbr": season.team_abbr,
        "seasonYear": season.season_year,
        "grade": value,
        "stats": format_columns(theme, season.stats, season.position),
    }
    if season.headshot:
        content["headshot"] = season.headshot
    if season.week is not None:        # game-grain card context (Swift renders "vs OPP · Wk W")
        content["week"] = season.week
        content["opponent"] = season.opponent
        if season.game_date:           # non-NFL game grain (Swift renders "vs OPP · Apr 8")
            content["gameDate"] = season.game_date
    if season.career:                  # career-grain card context (Swift renders "CAREER · 1996-2016")
        content["firstYear"] = int(season.meta.get("first_year", season.season_year))
        content["lastYear"] = int(season.meta.get("last_year", season.season_year))
    return content


def grade_pool(theme: Theme, seasons: list[RawSeason],
               baselines: BaselineTable | None = None) -> list[tuple[RawSeason, float]]:
    """Filter `seasons` to the theme and grade them, best-first.

    Dedupes by *person* (keeps each player's single best graded season) so the
    same star can't appear twice in one puzzle, then caps to the candidate pool.
    Era-adjusted themes grade via `grade_era` (raw points × era volume index);
    `baselines` must be provided for them.
    """
    use_era = theme.era_adjusted and baselines is not None
    graded: dict[str, tuple[RawSeason, float]] = {}
    for s in seasons:
        if s.sport != theme.sport or s.position not in theme.positions:
            continue
        # Keep season/game/career pools strictly separate — a career row has week=None
        # just like a season row, so this can't collapse to a single boolean check.
        s_grain = "career" if s.career else ("game" if s.week is not None else "season")
        if s_grain != theme.grain:
            continue
        if any(s.stats.get(k, 0.0) < v for k, v in theme.min_stats.items()):
            continue
        if not all(f.matches(s) for f in theme.filters):
            continue
        # M16, made structural (2026-07-10): the historical depth sweeps (bref = NBA
        # 1950–2001, pfr = NFL 1970–1998) deliberately carry photo-less rows for
        # catalog/roster depth (Draft & Spin, Create-search) — those rows must never
        # become puzzle CARDS, or the bundle headshot guard trips on every refresh
        # (caught live: Mark Clayton/James Wilder 1984), and the same now applies to the
        # photo-less lower-division soccer rows. Scoped to those sources so the curated seed
        # fallback (whose offline puzzles are the whole point) and test fixtures are
        # untouched — the remaining sources guarantee a headshot URL.
        if not s.headshot and s.source in DEPTH_ONLY_WITHOUT_PHOTO:
            continue
        g = (grade_era(s.stats, theme.scale, s.sport, s.position, s.season_year, baselines)
             if use_era else grade(s.stats, theme.scale))
        # Keyed by PERSON normally (one row per human, their best), but by the row's own id
        # when a theme is deliberately about one player's several seasons — see
        # `Theme.dedupe_person`. Keying by person there would collapse a career ladder to a
        # single card.
        key = slug(s.name) if theme.dedupe_person else s.player_id
        prev = graded.get(key)
        if prev is None or g > prev[1]:
            graded[key] = (s, g)
    ranked = sorted(graded.values(), key=lambda t: (-t[1], slug(t[0].name)))
    return ranked[: theme.pool_cap]


def _same_person(a: str, b: str) -> bool:
    """Whether two card names are one human under two spellings.

    Providers list the same player under a short display name and a formal full one, as
    separate rows with separate ids — Transfermarkt carries both "Cristiano Ronaldo" and
    "Cristiano Ronaldo dos Santos Aveiro", so four live boards asked players to rank Ronaldo
    against himself (found 2026-08-19). Neither the id check nor an exact-name check can see
    it, because both genuinely differ.

    A strict prefix on a word boundary is the shape this actually takes: the formal name
    EXTENDS the display name. Requiring the shorter side to be a full name itself (two or more
    words) keeps it from firing on a shared surname."""
    a, b = a.casefold().strip(), b.casefold().strip()
    if a == b:
        return True
    short, long = (a, b) if len(a) < len(b) else (b, a)
    return " " in short and long.startswith(short + " ")


Window = list[tuple[RawSeason, float]]


def _is_valid_window(win: Window, *, allow_same_person: bool) -> bool:
    """The two rules every window must satisfy regardless of how it was chosen: an
    unambiguous keep/cut split, and no human appearing twice."""
    if win[3][1] == win[4][1]:                # no clean keep/cut boundary
        return False
    if allow_same_person:
        return True
    names = [season.name for season, _ in win]
    return not any(_same_person(names[x], names[y])
                   for x in range(len(names)) for y in range(x + 1, len(names)))


def _sample(items: list, count: int) -> list:
    """`count` items spread evenly across `items`, endpoints included."""
    if count <= 0:
        return []
    if len(items) <= count:
        return list(items)
    if count == 1:                        # a single pick is the first, not a div-by-zero
        return [items[0]]
    step = (len(items) - 1) / (count - 1)
    return [items[round(k * step)] for k in range(count)]


def _windows(ranked: Window, max_variants: int, *, mode: str = "close",
             allow_same_person: bool = False) -> list[Window]:
    """Eight-row windows out of a grade-ranked pool. See `Theme.window_mode` for the modes.

    'close' is the original behaviour and stays the default: contiguous windows clustered in
    grade, evenly sampled for variety. 'top' returns exactly one window (the actual best
    eight) — a period theme called "Top Performances" that quietly served the 9th-to-16th
    best would be lying in its title. 'spread' samples across the YEAR range so a franchise
    or career ladder covers its history instead of one peak cluster.
    """
    n = len(ranked)
    if n < KEEP_COUNT:
        return []

    if mode == "top":
        win = ranked[:KEEP_COUNT]
        return [win] if _is_valid_window(win, allow_same_person=allow_same_person) else []

    if mode == "spread":
        # Walk the pool oldest-first, sample evenly across it, then re-rank the eight by
        # grade so the keep/cut boundary is still a grade boundary. Several offsets are
        # tried so one unlucky sample (a tie on the boundary) doesn't lose the theme.
        by_year = sorted(ranked, key=lambda t: (t[0].season_year, slug(t[0].name)))
        out: list[Window] = []
        seen: set[tuple[str, ...]] = set()
        for offset in range(min(len(by_year) - KEEP_COUNT + 1, max(max_variants, 1))):
            win = sorted(_sample(by_year[offset:], KEEP_COUNT), key=lambda t: -t[1])
            ids = tuple(sorted(s.player_id for s, _ in win))
            if ids in seen:
                continue
            seen.add(ids)
            if _is_valid_window(win, allow_same_person=allow_same_person):
                out.append(win)
        return out[:max_variants]

    candidates: list[Window] = []
    for i in range(n - KEEP_COUNT + 1):
        win = ranked[i:i + KEEP_COUNT]
        if _is_valid_window(win, allow_same_person=allow_same_person):
            candidates.append(win)
    if not candidates:
        return []
    return _sample(candidates, max_variants) if len(candidates) > max_variants else candidates


def build_keep4_rows(theme: Theme, seasons: list[RawSeason],
                     baselines: BaselineTable | None = None,
                     max_variants: int | None = None) -> list[PuzzleRow]:
    """`max_variants` overrides `theme.max_variants` for callers that want to see every
    distinct player-set window a theme can produce (the daily novel-puzzle picker) rather
    than the one variant curated content ships with."""
    ranked = grade_pool(theme, seasons, baselines)
    rows: list[PuzzleRow] = []
    windows = _windows(ranked, max_variants or theme.max_variants,
                       mode=theme.window_mode, allow_same_person=not theme.dedupe_person)
    for variant, window in enumerate(windows):
        # Store players in a stable, non-grade order so the JSON doesn't leak the answer.
        players = sorted(
            (_player_content(theme, s, g) for s, g in window),
            key=lambda p: p["id"],
        )
        row_id = f"{theme.key}-{variant:02d}"
        content = {
            "id": row_id,
            "theme": theme.title,
            "sport": theme.sport,
            "players": players,
            "grain": theme.grain,
            # The grade scale that ranked this pool — lets the app show the exact formula
            # (generated themes aren't in keep4_themes.json, so a title match can't recover
            # it client-side). Mirrors Keep4Puzzle.scale.
            "scale": theme.scale,
        }
        rows.append(PuzzleRow(id=row_id, sport=theme.sport, format="keep4", content=content))
    return rows


# ── Who Am I? ─────────────────────────────────────────────────────────────────

def build_whoami_row(entry: WhoAmIEntry, seed: str = "") -> PuzzleRow:
    """One Who Am I? row for `entry`, with its six clues drawn fresh from every dimension
    the subject supports (see whoami_clues) rather than the fixed era/position/teams/
    statLine/fact/jersey list this used to emit for every player in the game.

    `seed` varies the draw: daily_whoami passes the serve date, so the same subject coming
    back around months later is a genuinely different puzzle, not a rerun. Default "" is
    the stable archival draw for main.py's undated pool copy.

    `difficulty` rides along in `content` as an additive field. Clients that predate it
    ignore it and score off the flat table, which is why the tier multiplier lives on the
    client (see whoami_clues.POINT_MULTIPLIER) rather than being applied to a score here.
    """
    difficulty = whoami_clues.difficulty_of(entry)
    clues = whoami_clues.select_clues(entry, seed=seed, difficulty=difficulty)
    row_id = f"{entry.sport}-whoami-{slug(entry.canonical)}"
    content = {
        "id": row_id,
        "sport": entry.sport,
        "clues": [c.to_content(i + 1) for i, c in enumerate(clues)],
        "answer": {"canonical": entry.canonical, "aliases": entry.aliases},
        "difficulty": difficulty,
    }
    return PuzzleRow(id=row_id, sport=entry.sport, format="whoami", content=content)


def load_whoami_entries(path) -> list[WhoAmIEntry]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return [WhoAmIEntry(**e) for e in raw]
