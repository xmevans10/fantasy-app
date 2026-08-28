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
import typing

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


def _grain_noun(spec: curation.PositionSpec) -> str:
    """The word a card of this grain is counted in."""
    return {"game": "games", "career": "careers"}.get(spec.grain, "seasons")


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
                                 suffix=f", {team}", axis="club")
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
                 suffix: str = "", noun: str = "seasons") -> str:
    """`noun` is the grain's word. Single-quirk titles get theirs from `curation.game_quirks`,
    which rewords the quirk itself, but a COMBO title is composed here from two adjectives and
    never touches either quirk's title, so it needs telling separately. Without this a
    game-grain board came out as "2024 Week 7: bruiser, undrafted player seasons" over eight
    single games."""
    frag = f"{q1.adjective}, {q2.adjective} {label} {noun}"
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
                title = _combo_title(sl.prefix, q1, q2, spec.label, sl.suffix,
                                     noun=_grain_noun(spec))
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
# Retuned 2026-08-28 against 38 real BallGame Pod "Keep 4, Cut 4" titles, which are the
# closest public reference for this format. What that sample actually looks like:
#   50%  position only, with NO qualifying hook at all ("NFL Cornerbacks")
#   21%  a division or conference ("All-Time AFC East Seasons")
#   100% carry either zero or ONE qualifier. Not one of the 38 stacks two.
#    3%  reference a draft pick, once, in the whole sample.
# The previous values did close to the opposite: a quirk every single time, two of them 45% of
# the time, and no way to express a division at all. A season replay under the old numbers
# produced a draft-themed board in 8 of 18 weeks.
P_ERA = 0.40          # narrow to a decade or to "Active"
P_CLUB = 0.16         # narrow to a single franchise
P_DIVISION = 0.20     # narrow to a division or conference
P_SCOPE = 0.22        # narrow to a league / nationality, where the sport has them
P_NO_QUIRK = 0.45     # no hook at all: the bare position cohort, the reference's commonest shape
P_SECOND_QUIRK = 0.12 # two quirks rather than one, now the exception it should always have been

# Composition order, outermost first — see `roll_theme`. `period` leads: a fresh-drop theme
# reads "2026 Week 3: Undrafted WR games", never "Undrafted WR games, 2026 Week 3". The order
# has to stay FIXED for the same reason era already did — folding two axes the other way
# keys one identical puzzle two different ways, and `puzzle_history`'s theme cooldown then
# stops recognising a theme it has already served.
_AXIS_ORDER = ["period", "era", "division", "club", "scope"]


def _weighted_quirk(usable: list[curation.Quirk], rng: random.Random) -> curation.Quirk:
    """Draw a quirk by FAMILY share, then uniformly inside the family.

    Two-stage because inventory share and output share diverge badly otherwise. Draft quirks
    are 6 of NFL's 25, but at game grain most stat quirks fail viability (no one meets a
    300-carry threshold in one game), so uniform sampling over the survivors handed draft 44%
    of a replayed season. Weighting the FAMILY makes the target independent of how many quirks
    happen to sit in it, so adding a fifth age quirk does not quietly steal share from stats.
    """
    families: dict[str, list[curation.Quirk]] = {}
    for q in usable:
        families.setdefault(q.group, []).append(q)
    pinned = {g: w for g, w in curation.QUIRK_GROUP_SHARE.items() if g in families}
    free = [g for g in families if g not in pinned]
    remainder = max(0.0, 1.0 - sum(pinned.values()))
    weights = dict(pinned)
    for g in free:
        weights[g] = remainder / len(free)
    if not any(weights.values()):                    # every present family pinned at 0
        weights = {g: 1.0 for g in families}
    groups = sorted(weights)
    group = rng.choices(groups, weights=[weights[g] for g in groups], k=1)[0]
    return rng.choice(sorted(families[group], key=lambda q: q.key))


class RolledSpec(typing.NamedTuple):
    """What a roll chose, before it is rendered into a `Theme`.

    Returned separately so callers (and tests) can inspect the actual quirks and slices rather
    than parsing them back out of the composed key — quirk keys contain hyphens themselves
    ("all-or-nothing", "power-arm"), so any positional or suffix parse of a key is ambiguous:
    `empty-average` + `contact` composes a key ending in the same characters as the genuinely
    forbidden pair `average` + `contact`.
    """
    spec_key: str
    spec: curation.PositionSpec
    slices: tuple[curation.Slice, ...]
    quirks: tuple[curation.Quirk, ...]


def roll_spec(cfg: curation.SportCuration, rng: random.Random,
              teams: tuple[curation.Slice, ...] = ()) -> RolledSpec | None:
    """Choose one random combination of axes for `cfg`. `None` if nothing usable was drawn.

    At most one value per axis: two eras ANDed is an empty pool, but an era AND a club is
    exactly the specific-but-real cut worth minting. Deterministic given `rng`, so a day's
    mint is reproducible.
    """
    spec_key, spec = rng.choice(sorted(cfg.positions.items()))

    chosen: list[curation.Slice] = []
    eras = [s for s in cfg.slices if s.axis == "era" and s.filters]
    scopes = [s for s in cfg.slices if s.axis == "scope"]
    divisions = [s for s in cfg.slices if s.axis == "division"]
    if eras and rng.random() < P_ERA:
        chosen.append(rng.choice(eras))
    # One geography axis at most, and they are alternatives, not a chain: a division is a set
    # of clubs, so ANDing it with a single club is either a no-op or an empty pool.
    # Plain franchises only. `team_slices` also returns pre-crossed era x franchise slices for
    # the enumerated path; taking one here could stack a second era on the one rolled above.
    plain_teams = [t for t in teams if t.axis == "club"]
    if divisions and rng.random() < P_DIVISION:
        chosen.append(rng.choice(divisions))
    elif plain_teams and rng.random() < P_CLUB:
        chosen.append(rng.choice(plain_teams))
    elif scopes and rng.random() < P_SCOPE:
        chosen.append(rng.choice(scopes))

    usable = [q for q in cfg.quirks if q.applies_to(spec_key)]
    quirks: list[curation.Quirk] = []
    # A bare cohort with no hook at all is the single commonest shape in the reference sample
    # (half of it), and was previously unreachable: the roller always attached a quirk. It
    # needs a slice to be interesting, though, or every roll of a given position collapses to
    # one key ("gen-wr-all") and the space is one theme deep.
    want_quirk = not (chosen and rng.random() < P_NO_QUIRK)
    if usable and want_quirk:
        quirks.append(_weighted_quirk(usable, rng))
        if len(usable) > 1 and rng.random() < P_SECOND_QUIRK:
            second = _weighted_quirk([q for q in usable if q.key != quirks[0].key], rng)
            # Same-axis pairs narrow one dimension twice instead of crossing two — the exact
            # thing `redundant_pair` exists to skip in the enumerated path.
            if not curation.redundant_pair(quirks[0], second):
                quirks.append(second)
    if not quirks and not chosen:
        return None                 # neither a hook nor a slice: that is just "all WRs"

    # Order the axes FIXED, era outermost. `team_slices` builds its era x franchise cross as
    # `combine(era, team)`, so folding the other way would key the identical theme "lad-2020"
    # here and "2020-lad" there — two keys for one puzzle, and `puzzle_history`'s theme
    # cooldown would stop recognising rolled themes it had already served.
    chosen.sort(key=lambda part: _AXIS_ORDER.index(part.axis)
                if part.axis in _AXIS_ORDER else len(_AXIS_ORDER))
    return RolledSpec(spec_key, spec, tuple(chosen), tuple(quirks))


def roll_theme(cfg: curation.SportCuration, rng: random.Random,
               teams: tuple[curation.Slice, ...] = ()) -> Theme | None:
    """Compose one random theme for `cfg`. `None` if the roll produced nothing usable."""
    rolled = roll_spec(cfg, rng, teams)
    if rolled is None:
        return None
    spec, chosen, quirks = rolled.spec, list(rolled.slices), list(rolled.quirks)

    sl = chosen[0] if chosen else curation.Slice(key="all")
    for part in chosen[1:]:
        sl = curation.combine(sl, part)

    pre = _key_prefix(cfg)
    if not quirks:
        # The bare cohort: "All-Time RB seasons", "AFC East WR seasons". Half the reference
        # catalogue is this shape and the roller could not previously produce one at all.
        key = f"gen-{pre}{spec.pos}-{sl.key}-plain".lower()
        frag = f"{spec.label} {_grain_noun(spec)}"
        title = sl.prefix + (frag if sl.prefix else frag[0].upper() + frag[1:]) + sl.suffix
    elif len(quirks) == 1:
        q = quirks[0]
        key = f"gen-{pre}{spec.pos}-{sl.key}-{q.key}".lower()
        title = sl.prefix + q.title.format(pos=spec.label) + sl.suffix
    else:
        q1, q2 = quirks
        key = f"gen2-{pre}{spec.pos}-{sl.key}-{q1.key}-{q2.key}".lower()
        title = _combo_title(sl.prefix, q1, q2, spec.label, sl.suffix,
                             noun=_grain_noun(spec))
    if key in curation.DENYLIST:
        return None

    filters = sl.filters
    for q in quirks:
        filters += _quirk_filters(q, spec)
    return _theme(key, title, spec, filters, sport=cfg.sport, quirks=tuple(quirks))


def theme_family(key: str) -> str:
    """Which quirk family a composed theme key belongs to. Read off the key's trailing quirk
    fragment(s), so it works for rolled and enumerated themes alike."""
    for family, keys in (("draft", curation._DRAFT_KEYS), ("size", curation._SIZE_KEYS),
                         ("age", curation._AGE_KEYS)):
        if any(f"-{k}" in key for k in keys):
            return family
    return "plain" if key.endswith("-plain") else "other"


def _cap_families(themes: list[Theme], wanted: int) -> list[Theme]:
    """Hold each quirk family to its `QUIRK_GROUP_SHARE` of the SURVIVING set.

    Weighting the roll is not enough on its own, and the gap is not small. Rolls came out at
    9.5% draft, but a replayed 2024 season still minted draft boards in 5 of 18 weeks, because
    the viability gate is not family-neutral: at game grain most stat quirks cannot be met at
    all (nobody takes 300 carries in one game) while a biographical predicate like "went
    undrafted" is as true of a game as of a season. So draft survives at a far higher rate
    than it is rolled at, and the share that matters is the share that reaches the picker.

    A soft cap: the leftovers are appended after, so a sport that can only produce one family
    still fills its quota rather than starving.
    """
    if not themes:
        return themes
    caps: dict[str, int] = {}
    for family, share in curation.QUIRK_GROUP_SHARE.items():
        caps[family] = max(1, round(share * wanted))
    kept: list[Theme] = []
    spare: list[Theme] = []
    used: dict[str, int] = {}
    for theme in themes:
        family = theme_family(theme.key)
        limit = caps.get(family)
        if limit is not None and used.get(family, 0) >= limit:
            spare.append(theme)
            continue
        used[family] = used.get(family, 0) + 1
        kept.append(theme)
    return (kept + spare)[:wanted]


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
    found = _cap_families(found, wanted)
    # `label` is the registry KEY, not `cfg.sport` — baseball has two cohorts (hitters and
    # pitchers) under one sport, and logging both as "baseball" reads like a duplicate run.
    print(f"[roll] {label or cfg.sport}: {len(found)} viable from {rolled} rolls "
          f"(wanted {wanted})")
    return found
