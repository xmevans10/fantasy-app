"""Procedural niche-theme generator with a viability gate.

Enumerates `position × era × (bio-quirk | first-name)` combos, synthesizes a `Theme` for
each, and keeps only those that actually build a *fair* puzzle — 8 close, recognizable
seasons with a clean keep/cut boundary (the same `_windows`/validate gate the curated
themes pass). Editorial config (which combos, titles, caps) lives in curation.py.

Pure given a fixed `seasons` list, so the daily archive is reproducible.
"""
from __future__ import annotations

import itertools

from . import assemble, curation
from .models import RawSeason
from .themes import Filter, Theme


def _quirk_filters(q: curation.Quirk, spec: curation.PositionSpec) -> tuple[Filter, ...]:
    """A quirk's real filter set — weight-class quirks are position-relative and carry
    empty placeholder filters on the Quirk itself (see curation.weight_filters)."""
    return curation.weight_filters(spec).get(q.key, q.filters)


def _theme(key: str, title: str, spec: curation.PositionSpec,
           filters: tuple[Filter, ...]) -> Theme:
    return Theme(
        key=key,
        title=title,
        sport="nfl",
        scale=spec.scale,
        positions=frozenset({spec.pos}),
        min_stats=dict(spec.min_stats),
        columns=spec.columns,
        filters=filters,
        grain="season",
    )


def _candidates() -> list[Theme]:
    """Every single-quirk theme we'll *try* — viability is checked separately."""
    out: list[Theme] = []
    for spec in curation.POSITIONS.values():
        for decade in curation.DECADES:
            dfilter = () if decade is None else (Filter("decade", "eq", decade),)
            prefix = curation.decade_prefix(decade)
            # bio-quirk themes
            for q in curation.QUIRKS:
                key = f"gen-{spec.pos}-{decade or 'all'}-{q.key}".lower()
                if key in curation.DENYLIST:
                    continue
                title = prefix + q.title.format(pos=spec.label)
                out.append(_theme(key, title, spec, dfilter + _quirk_filters(q, spec)))
    # NOTE: single-first-name Keep4 themes (curation.NAME_VARIANTS) were evaluated and
    # dropped — exact-name pools rarely field 8 *recognizable*, close-graded seasons, so they
    # produced obscure puzzles. That hyper-niche single-name hook belongs in WhoAmI (the
    # NAME_VARIANTS config is retained there for a future niche-WhoAmI generator).
    return out


def _combo_title(prefix: str, q1: curation.Quirk, q2: curation.Quirk, label: str) -> str:
    frag = f"{q1.adjective}, {q2.adjective} {label} seasons"
    if not prefix:
        frag = frag[0].upper() + frag[1:]
    return prefix + frag


def _pairwise_candidates() -> list[Theme]:
    """Two-quirk combos (undrafted+sub-6-foot, first-round+under-24, …) — a much bigger,
    more specific niche space than any single quirk alone. Uncapped and not fed into the
    balanced/capped `generate_themes()` picker used by the daily bulk-refresh job; this is
    for the daily novel-puzzle picker (see daily_puzzle.py) to search over, since that job
    wants the full space so it can pick something never served before, not a fixed pool."""
    out: list[Theme] = []
    for spec in curation.POSITIONS.values():
        for decade in curation.DECADES:
            dfilter = () if decade is None else (Filter("decade", "eq", decade),)
            prefix = curation.decade_prefix(decade)
            for q1, q2 in itertools.combinations(curation.QUIRKS, 2):
                if curation.redundant_pair(q1, q2):
                    continue
                key = f"gen2-{spec.pos}-{decade or 'all'}-{q1.key}-{q2.key}".lower()
                if key in curation.DENYLIST:
                    continue
                title = _combo_title(prefix, q1, q2, spec.label)
                filters = dfilter + _quirk_filters(q1, spec) + _quirk_filters(q2, spec)
                out.append(_theme(key, title, spec, filters))
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
    candidates = _candidates() + _pairwise_candidates()
    return [t for t in candidates if _is_viable(t, seasons)]
