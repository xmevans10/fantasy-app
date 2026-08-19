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
                                 suffix=f" — {team}")
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
