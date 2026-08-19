"""Procedural niche-theme generator with a viability gate.

Enumerates `position × era × (bio-quirk | first-name)` combos, synthesizes a `Theme` for
each, and keeps only those that actually build a *fair* puzzle — 8 close, recognizable
seasons with a clean keep/cut boundary (the same `_windows`/validate gate the curated
themes pass). Editorial config (which combos, titles, caps) lives in curation.py.

Pure given a fixed `seasons` list, so the daily archive is reproducible.
"""
from __future__ import annotations

import collections
import itertools
import random

from . import assemble, curation
from .models import slug
from .models import RawSeason
from .themes import Filter, StatColumn, Theme


def _quirk_filters(q: curation.Quirk, spec: curation.PositionSpec) -> tuple[Filter, ...]:
    """A quirk's real filter set — weight-class quirks are position-relative and carry
    empty placeholder filters on the Quirk itself (see curation.weight_filters)."""
    return curation.weight_filters(spec).get(q.key, q.filters)


# On-card columns are capped at five (the curated themes all sit at 4-5, and the card layout
# is built for that) — a quirk's promoted columns take the front, the spec's fill the rest.
_MAX_COLUMNS = 5


def _columns(spec: curation.PositionSpec, quirks: tuple[curation.Quirk, ...]) -> list[StatColumn]:
    """The spec's columns with each quirk's own stat promoted to the front, deduped by stat.

    Without this a puzzle titled "20-20 club seasons" would show HR but not SB — the card
    wouldn't display the stat the theme is named after, which is the one thing the player
    needs to reason about. NFL's quirks are all biographical and promote nothing, so its
    generated cards are unchanged."""
    ordered: list[StatColumn] = [c for q in quirks for c in q.columns] + list(spec.columns)
    seen: set[str] = set()
    out: list[StatColumn] = []
    for col in ordered:
        if col.stat in seen:
            continue
        seen.add(col.stat)
        out.append(col)
    return out[:_MAX_COLUMNS]


def _theme(key: str, title: str, spec: curation.PositionSpec,
           filters: tuple[Filter, ...], sport: str = "nfl",
           quirks: tuple[curation.Quirk, ...] = ()) -> Theme:
    return Theme(
        key=key,
        title=title,
        sport=sport,
        scale=spec.scale,
        positions=spec.position_set,
        min_stats=dict(spec.min_stats),
        columns=_columns(spec, quirks),
        filters=filters,
        grain=spec.grain,
        pool_cap=spec.pool_cap,
    )


def _key_prefix(cfg: curation.SportCuration) -> str:
    """NFL's generated keys predate the cross-sport registry and are recorded verbatim in
    `puzzle_history` signatures, so they keep their original `gen-{pos}-…` shape; every other
    sport is namespaced by sport so keys stay unambiguous as the registry grows."""
    return "" if cfg.sport == "nfl" else f"{cfg.sport}-"


def team_slices(cfg: curation.SportCuration, seasons: list[RawSeason]) -> tuple[curation.Slice, ...]:
    """Franchise slices for `cfg`, derived from the data rather than a hardcoded roster.

    Ranked by how many player-seasons each franchise actually has, so the axis follows coverage
    instead of somebody's memory of which clubs matter — and so relocations, renames and
    expansion teams need no edit here. Season-grain rows only: a franchise's game-grain volume
    says nothing about whether it can field eight close SEASONS.

    Returns both the plain franchise slices and, for sports configured for it, franchise x era
    ("1990s seasons — NYY") — the most specific cut the data supports.
    """
    if not cfg.team_slices:
        return ()
    counts = collections.Counter(
        s.team_abbr for s in seasons
        if s.sport == cfg.sport and s.team_abbr and not s.career and s.week is None)
    ranked = [team for team, _ in counts.most_common(cfg.team_slices)]
    plain = tuple(curation.Slice(key=slug(team), filters=(Filter("team", "eq", team),),
                                 suffix=f" — {team}", axis="club")
                  for team in ranked)
    if not cfg.team_era_slices or not cfg.team_era_decades:
        return plain
    eras = curation.decade_slices(list(cfg.team_era_decades))
    crossed = tuple(curation.combine(era, team_slice)
                    for team_slice in plain[:cfg.team_era_slices]
                    for era in eras)
    return plain + crossed


def _candidates(cfg: curation.SportCuration | None = None,
                extra_slices: tuple[curation.Slice, ...] = ()) -> list[Theme]:
    """Every single-quirk theme we'll *try* — viability is checked separately."""
    cfg = cfg or curation.SPORTS["nfl"]
    pre = _key_prefix(cfg)
    out: list[Theme] = []
    for spec_key, spec in cfg.positions.items():
        for sl in cfg.slices + extra_slices:
            for q in cfg.quirks:
                if not q.applies_to(spec_key):
                    continue
                key = f"gen-{pre}{spec.pos}-{sl.key}-{q.key}".lower()
                if key in curation.DENYLIST:
                    continue
                title = sl.prefix + q.title.format(pos=spec.label) + sl.suffix
                out.append(_theme(key, title, spec,
                                  sl.filters + _quirk_filters(q, spec),
                                  sport=cfg.sport, quirks=(q,)))
    # NOTE: single-first-name Keep4 themes (curation.NAME_VARIANTS) were evaluated and
    # dropped — exact-name pools rarely field 8 *recognizable*, close-graded seasons, so they
    # produced obscure puzzles. That hyper-niche single-name hook belongs in WhoAmI (the
    # NAME_VARIANTS config is retained there for a future niche-WhoAmI generator).
    return out


def _combo_title(prefix: str, q1: curation.Quirk, q2: curation.Quirk, label: str,
                 suffix: str = "") -> str:
    frag = f"{q1.adjective}, {q2.adjective} {label} seasons"
    if not prefix:
        frag = frag[0].upper() + frag[1:]
    return prefix + frag + suffix


def _pairwise_candidates(cfg: curation.SportCuration | None = None,
                         extra_slices: tuple[curation.Slice, ...] = ()) -> list[Theme]:
    """Two-quirk combos (undrafted+sub-6-foot, first-round+under-24, …) — a much bigger,
    more specific niche space than any single quirk alone. Uncapped and not fed into the
    balanced/capped `generate_themes()` picker used by the daily bulk-refresh job; this is
    for the daily novel-puzzle picker (see daily_puzzle.py) to search over, since that job
    wants the full space so it can pick something never served before, not a fixed pool."""
    cfg = cfg or curation.SPORTS["nfl"]
    pre = _key_prefix(cfg)
    out: list[Theme] = []
    for spec_key, spec in cfg.positions.items():
        for sl in cfg.slices + extra_slices:
            for q1, q2 in itertools.combinations(cfg.quirks, 2):
                if curation.redundant_pair(q1, q2):
                    continue
                if not (q1.applies_to(spec_key) and q2.applies_to(spec_key)):
                    continue
                key = f"gen2-{pre}{spec.pos}-{sl.key}-{q1.key}-{q2.key}".lower()
                if key in curation.DENYLIST:
                    continue
                title = _combo_title(sl.prefix, q1, q2, spec.label, sl.suffix)
                filters = sl.filters + _quirk_filters(q1, spec) + _quirk_filters(q2, spec)
                out.append(_theme(key, title, spec, filters, sport=cfg.sport, quirks=(q1, q2)))
    return out


def _is_viable(theme: Theme, seasons: list[RawSeason]) -> bool:
    rows = assemble.build_keep4_rows(theme, seasons)
    if not rows:                                  # <8 close candidates / no clean boundary
        return False
    players = rows[0].content["players"]          # recognizability on the first variant
    recognizable = sum(1 for p in players if p.get("headshot"))
    return recognizable >= curation.MIN_RECOGNIZABLE


def _angle(theme: Theme) -> str:
    """The niche 'angle' of a theme (name / undrafted / sub6 / first-round …) — used to
    spread the final pick across kinds instead of 16 near-identical quirks."""
    if "-name-" in theme.key:
        return "name"
    return "-".join(theme.key.split("-")[3:])     # drops 'gen-POS-DECADE-' prefix


def generate_themes(seasons: list[RawSeason]) -> list[Theme]:
    """Return viable generated themes, capped and balanced across both angle and position so
    the archive gets variety (names + each quirk), not a wall of one kind. Deterministic."""
    viable = [t for t in _candidates() if _is_viable(t, seasons)]

    # Bucket by angle, each bucket key-sorted; round-robin across angles for variety.
    buckets: dict[str, list[Theme]] = {}
    for t in sorted(viable, key=lambda t: t.key):
        buckets.setdefault(_angle(t), []).append(t)

    picked: list[Theme] = []
    per_pos: dict[str, int] = {}
    order = sorted(buckets)                        # deterministic angle order
    while len(picked) < curation.MAX_GENERATED and any(buckets.values()):
        for angle in order:
            queue = buckets.get(angle) or []
            while queue:
                theme = queue.pop(0)
                pos = next(iter(theme.positions))
                if per_pos.get(pos, 0) >= curation.PER_POSITION_CAP:
                    continue                       # try next in this angle for a freer position
                picked.append(theme)
                per_pos[pos] = per_pos.get(pos, 0) + 1
                break
            if len(picked) >= curation.MAX_GENERATED:
                break
    return picked


def all_niche_candidates(seasons: list[RawSeason]) -> list[Theme]:
    """Every viable niche theme — single-quirk *and* pairwise combos, uncapped. Unlike
    `generate_themes()` (capped at MAX_GENERATED for the daily bulk-refresh pool), this is
    for the daily novel-puzzle picker (daily_puzzle.py), which wants the full candidate
    space so it can find something never served before rather than a fixed balanced set."""
    candidates: list[Theme] = []
    for cfg in curation.SPORTS.values():
        if not any(s.sport == cfg.sport for s in seasons):
            continue          # nothing pulled for this sport this run — skip the build work
        teams = team_slices(cfg, seasons)
        candidates += _candidates(cfg, teams)
        if cfg.pairwise:
            # Franchise slices are already narrow; crossing them with a SECOND quirk on top
            # mostly produces empty pools that cost a build each. Pairwise stays on the
            # era/league axes, where the pool is wide enough to survive two predicates.
            candidates += _pairwise_candidates(cfg)
    return [t for t in candidates if _is_viable(t, seasons)]


# ── Rolled themes ────────────────────────────────────────────────────────────────
#
# The enumerated path above builds every (position x slice x quirk) combination there is,
# viability-checks all of them, and hands the lot to the daily picker. Measured on the live
# catalog once franchises joined the grid: 14,888 candidates, 20.9 minutes, to choose FIVE
# puzzles. That is the wrong shape twice over — it pays for 14,883 boards nobody sees, and the
# space it can reach is capped at whatever the grid happens to enumerate.
#
# Rolling inverts it: compose ONE spec at random from the axes, test it, keep it or roll again.
# Cost drops to the number of attempts (tens of builds, seconds), and the reachable space is
# the full product of the axes rather than a hand-drawn subset — an era AND a club AND two
# quirks is a combination the grid never enumerated, because crossing every axis with every
# other was exactly what made it unaffordable.
#
# Keys are composed from the parts, so a rolled theme and the same combination enumerated
# produce the SAME key. `puzzle_history`'s theme cooldown therefore works across both paths
# without knowing which one produced a given row.

# How often each optional axis is included. Tuned so most boards carry some context (a bare
# "20-20 club seasons" is the least interesting thing this can produce) without stacking so
# many predicates that the pool empties and every roll fails.
P_ERA = 0.55          # narrow to a decade
P_CLUB = 0.30         # narrow to a franchise
P_SCOPE = 0.30        # narrow to a league / nationality, where the sport has them
P_SECOND_QUIRK = 0.45 # two quirks rather than one

# Composition order, outermost first — see `roll_theme`.
_AXIS_ORDER = ["era", "club", "scope"]


def roll_theme(cfg: curation.SportCuration, rng: random.Random,
               teams: tuple[curation.Slice, ...] = ()) -> Theme | None:
    """Compose one random theme spec for `cfg`. `None` if the roll produced nothing usable.

    At most one value per axis: two eras ANDed is an empty pool, but an era AND a club is
    exactly the specific-but-real cut worth minting. Deterministic given `rng`, so a day's
    mint is reproducible.
    """
    spec_key, spec = rng.choice(sorted(cfg.positions.items()))

    chosen: list[curation.Slice] = []
    eras = [s for s in cfg.slices if s.axis == "era" and s.filters]
    scopes = [s for s in cfg.slices if s.axis == "scope"]
    if eras and rng.random() < P_ERA:
        chosen.append(rng.choice(eras))
    # Plain franchises only. `team_slices` also returns pre-crossed era x franchise slices for
    # the enumerated path; taking one here could stack a second era on the one rolled above.
    plain_teams = [t for t in teams if t.axis == "club"]
    if plain_teams and rng.random() < P_CLUB:
        chosen.append(rng.choice(plain_teams))
    elif scopes and rng.random() < P_SCOPE:
        chosen.append(rng.choice(scopes))

    usable = [q for q in cfg.quirks if q.applies_to(spec_key)]
    if not usable:
        return None
    quirks: list[curation.Quirk] = [rng.choice(usable)]
    if len(usable) > 1 and rng.random() < P_SECOND_QUIRK:
        second = rng.choice([q for q in usable if q.key != quirks[0].key])
        # Same-axis pairs narrow one dimension twice instead of crossing two — the exact
        # thing `redundant_pair` exists to skip in the enumerated path.
        if not curation.redundant_pair(quirks[0], second):
            quirks.append(second)

    # Compose in a FIXED axis order, era outermost. `team_slices` builds its era x franchise
    # cross as `combine(era, team)`, so folding the other way would key the identical theme
    # "lad-2020" here and "2020-lad" there — two keys for one puzzle, and the `puzzle_history`
    # theme cooldown would stop recognising rolled themes it had already served.
    chosen.sort(key=lambda part: _AXIS_ORDER.index(part.axis)
                if part.axis in _AXIS_ORDER else len(_AXIS_ORDER))
    sl = chosen[0] if chosen else curation.Slice(key="all")
    for part in chosen[1:]:
        sl = curation.combine(sl, part)

    pre = _key_prefix(cfg)
    if len(quirks) == 1:
        q = quirks[0]
        key = f"gen-{pre}{spec.pos}-{sl.key}-{q.key}".lower()
        title = sl.prefix + q.title.format(pos=spec.label) + sl.suffix
    else:
        q1, q2 = quirks
        key = f"gen2-{pre}{spec.pos}-{sl.key}-{q1.key}-{q2.key}".lower()
        title = _combo_title(sl.prefix, q1, q2, spec.label, sl.suffix)
    if key in curation.DENYLIST:
        return None

    filters = sl.filters
    for q in quirks:
        filters += _quirk_filters(q, spec)
    return _theme(key, title, spec, filters, sport=cfg.sport, quirks=tuple(quirks))


def roll_viable_themes(cfg: curation.SportCuration, seasons: list[RawSeason],
                       rng: random.Random, wanted: int, attempts: int,
                       teams: tuple[curation.Slice, ...] | None = None,
                       label: str | None = None) -> list[Theme]:
    """Roll until `wanted` viable themes are found or `attempts` rolls are spent.

    Reports how hard it had to work: a sport whose rolls mostly miss is a coverage signal, not
    something to silently absorb.
    """
    if teams is None:
        teams = team_slices(cfg, seasons)
    found: list[Theme] = []
    seen: set[str] = set()
    rolled = 0
    for _ in range(attempts):
        if len(found) >= wanted:
            break
        rolled += 1
        theme = roll_theme(cfg, rng, teams)
        if theme is None or theme.key in seen:
            continue
        seen.add(theme.key)
        if _is_viable(theme, seasons):
            found.append(theme)
    # `label` is the registry KEY, not `cfg.sport` — baseball has two cohorts (hitters and
    # pitchers) under one sport, and logging both as "baseball" reads like a duplicate run.
    print(f"[roll] {label or cfg.sport}: {len(found)} viable from {rolled} rolls "
          f"(wanted {wanted})")
    return found
