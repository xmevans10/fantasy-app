"""Retroactively fix minted Keep4 cards that show a stat their position never records.

Every minted board freezes its own copy of the rendered `stats` array at mint time, so a
`themes.columns_for` fix only reaches boards minted AFTER it — the same gap `headshots.py`'s
ledger exists to close for photos (see the 0015 repoint migration). Measured when this was
written: 23 of 356 live keep4 rows carried at least one such column, including that day's own
NFL daily, `gen-any-all-towering-09-daily-20260906`, which served Travis Kelce as
"Pass Yds 0 · Pass TD 0 · Rush Yds 5 · Rush TD 0 · Rec 110" — four dead tiles and neither of
the two numbers that describe his season.

The rebuild does not reconstruct the theme. Generated theme keys aren't all re-derivable from
a row id (team slices come from the data, so `generate._candidates` alone doesn't emit them),
and it isn't necessary: `columns_for` composes a broken card purely from the position's
canonical card, and for every shape that is actually broken the "theme extras" tail is empty
because the canonical card already fills the five-column cap. So this reads each card's own
labels back to stat keys, asks whether the position produces them, and re-renders from
`POSITION_CARD` when it doesn't. `test_repoint_stats.py` locks that against `columns_for`.
"""
from __future__ import annotations

import json
from pathlib import Path

from .themes import (POSITION_CARD, POSITION_CARD_GAME, _FILL_COLUMNS, _MAX_CARD_COLUMNS,
                     KEEP4_THEMES, StatColumn, fmt_value, produces)
from . import curation


def _label_index() -> dict[str, dict[str, str]]:
    """sport → on-card label → raw stat key, over every label the pipeline can emit (curated
    theme columns, generated spec/quirk columns, and the fill registry).

    Injective per sport — locked by `test_repoint_stats.py::test_labels_are_unambiguous`, and
    it must stay that way: two stats sharing a label would make a frozen card unreadable."""
    index: dict[str, dict[str, str]] = {}

    def add(sport: str, column: StatColumn) -> None:
        index.setdefault(sport, {})[column.label] = column.stat

    for theme in KEEP4_THEMES:
        for column in theme.columns:
            add(theme.sport, column)
    for cfg in curation.SPORTS.values():
        for spec in cfg.positions.values():
            for column in spec.columns:
                add(cfg.sport, column)
        for quirk in cfg.quirks:
            for column in quirk.columns:
                add(cfg.sport, column)
    for sport, columns in _FILL_COLUMNS.items():
        for column in columns.values():
            add(sport, column)
    return index


LABELS = _label_index()


def card_is_broken(sport: str, position: str | None, stats: list[dict]) -> bool:
    """Whether this frozen card shows a stat `position` never records.

    An unrecognized label is NOT treated as broken: a label this build can't resolve is a
    column some other version of the catalog emitted, and guessing about it would rewrite
    cards that are fine."""
    if not position or not stats:
        return False
    keys = [LABELS.get(sport, {}).get(s.get("label", "")) for s in stats]
    return any(k is not None and not produces(sport, position, k) for k in keys)


def _as_number(value: str) -> float | None:
    try:
        return float(value.replace(",", "").replace("%", ""))
    except (AttributeError, ValueError):
        return None


def corroborated(sport: str, stats: list[dict], raw: dict[str, float]) -> bool:
    """Whether the frozen card and the catalog row describe the same performance.

    A frozen card carries only rendered strings, so the only way to know the catalog row it
    resolves to is still the row it was minted from is to check that they agree on a number.
    They can disagree: `baseball-babe-ruth-career` is minted as his HITTING career (714 HR,
    .342) while the catalog row under that same id holds his PITCHING career (94 W, 2.28 ERA)
    — one id, two careers, last writer wins. Rebuilding from that row would have printed
    "W 94 · ERA 2.28 · K 488" onto a career-hitters board. Ty Cobb is the same collision with
    5 novelty innings behind it.

    So: require at least one stat key present on both sides, non-zero on the frozen card, and
    agreeing to within rendering rounding. No shared number, no rewrite.
    """
    by_label = LABELS.get(sport, {})
    for entry in stats:
        key = by_label.get(entry.get("label", ""))
        if key is None or key not in raw:
            continue
        frozen = _as_number(entry.get("value", ""))
        if frozen is None or frozen == 0:
            continue
        actual = float(raw[key])
        # Tolerance tracks the coarsest format a card uses (`int`/`comma_int` round to whole
        # numbers), scaled for the magnitudes career totals reach.
        if abs(frozen - actual) <= max(0.5, abs(actual) * 0.005):
            return True
    return False


def rebuild_card(sport: str, position: str, grain: str,
                 stats: list[dict], raw: dict[str, float]) -> list[dict] | None:
    """The canonical card for `position`, rendered from `raw`. None when this sport/position
    has no canonical card (NBA/tennis/F1) or none of its keys can be rendered.

    A key the frozen card already carries keeps that card's own label and format, so a
    repointed board still reads in its theme's voice; the rest come from `_FILL_COLUMNS`.
    """
    game = POSITION_CARD_GAME.get(sport, {}).get(position) if grain == "game" else None
    canonical = game or POSITION_CARD.get(sport, {}).get(position)
    if not canonical:
        return None
    declared = {}
    for entry in stats:
        key = LABELS.get(sport, {}).get(entry.get("label", ""))
        if key is not None:
            declared[key] = entry["label"]
    fill = _FILL_COLUMNS.get(sport, {})
    out: list[dict] = []
    for key in canonical[:_MAX_CARD_COLUMNS]:
        column = fill.get(key)
        if column is None:
            continue
        label = declared.get(key, column.label)
        out.append({"label": label, "value": fmt_value(raw.get(key, 0.0), column.fmt)})
    return out or None


def repoint_content(content: dict, catalog: dict[str, dict],
                    skipped: list[str] | None = None) -> tuple[dict, int]:
    """A keep4 `content` blob with every broken card rebuilt. Returns (content, cards fixed).

    Cards whose player isn't in `catalog` are left alone — a row can only be repointed from
    real stats, and a card rebuilt from an empty stat bag would be all zeroes, which is
    strictly worse than the wrong-but-real numbers it replaces. So are cards whose catalog
    row fails `corroborated`; `skipped`, when given, collects those player ids so a run can
    report them rather than silently declining.
    """
    sport = content.get("sport", "")
    grain = content.get("grain", "season")
    skipped = skipped if skipped is not None else []
    fixed = 0
    players = []
    for player in content.get("players", []):
        row = catalog.get(player.get("id", ""))
        if row is None:
            players.append(player)
            continue
        position = row.get("position")
        if not card_is_broken(sport, position, player.get("stats", [])):
            players.append(player)
            continue
        raw = row.get("stats") or {}
        if not corroborated(sport, player["stats"], raw):
            # The catalog row under this id is a different performance — see `corroborated`.
            # Leaving the card alone keeps real (if badly chosen) numbers instead of writing
            # someone else's.
            skipped.append(player.get("id", "?"))
            players.append(player)
            continue
        rebuilt = rebuild_card(sport, position, grain, player["stats"], raw)
        if rebuilt is None or rebuilt == player["stats"]:
            players.append(player)
            continue
        players.append({**player, "stats": rebuilt})
        fixed += 1
    if not fixed:
        return content, 0
    return {**content, "players": players}, fixed


# ── Runners ───────────────────────────────────────────────────────────────────

def _report_skipped(skipped: list[str]) -> None:
    """Say out loud which broken cards were declined. Silence here would hide a genuine data
    defect (the id collision `corroborated` documents) behind a clean-looking run."""
    if not skipped:
        return
    unique = sorted(set(skipped))
    print(f"[repoint-stats] declined {len(unique)} card(s): the catalog row under that id is a "
          f"different performance (see `corroborated`) — {', '.join(unique[:8])}"
          + (f", +{len(unique) - 8} more" if len(unique) > 8 else ""))


def repoint_bundle(puzzles_path: Path, catalog_path: Path, *, dry_run: bool = False) -> int:
    """Repoint the bundled offline puzzles against the bundled catalog. Returns cards fixed."""
    puzzles = json.loads(puzzles_path.read_text(encoding="utf-8"))
    catalog = {r["id"]: r for r in json.loads(catalog_path.read_text(encoding="utf-8"))}
    fixed = 0
    out = []
    skipped: list[str] = []
    for content in puzzles:
        content, n = repoint_content(content, catalog, skipped)
        fixed += n
        out.append(content)
    _report_skipped(skipped)
    if fixed and not dry_run:
        puzzles_path.write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n",
                                encoding="utf-8")
    print(f"[repoint-stats] bundle: {fixed} card(s) rebuilt in {puzzles_path.name}"
          + (" (dry run, not written)" if fixed and dry_run else ""))
    return fixed


def repoint_live(*, dry_run: bool = False) -> int:
    """Repoint every live keep4 row against `player_seasons`. Returns cards fixed."""
    from .upsert import fetch_rows_by_id, fetch_rows_keyset, patch_rows

    puzzles = fetch_rows_keyset("puzzles", "id,sport,content", where="format=eq.keep4")
    print(f"[repoint-stats] fetched {len(puzzles)} live keep4 row(s)")
    wanted = {p.get("id") for row in puzzles for p in (row["content"].get("players") or [])}
    wanted.discard(None)
    catalog = {r["id"]: r for r in fetch_rows_by_id(
        "player_seasons", "id,position,stats", sorted(wanted))}
    print(f"[repoint-stats] resolved {len(catalog)}/{len(wanted)} player rows from the catalog")

    fixed = 0
    updates = []
    skipped: list[str] = []
    for row in puzzles:
        content, n = repoint_content(row["content"], catalog, skipped)
        if not n:
            continue
        fixed += n
        updates.append({"id": row["id"], "content": content})
    _report_skipped(skipped)
    print(f"[repoint-stats] {fixed} card(s) across {len(updates)} row(s) show a stat the "
          f"position never records")
    if updates and not dry_run:
        print(f"[repoint-stats] wrote {patch_rows('puzzles', updates)} row(s)")
    elif updates:
        print("[repoint-stats] dry run — nothing written; rows: "
              + ", ".join(u["id"] for u in updates[:10]))
    return fixed
