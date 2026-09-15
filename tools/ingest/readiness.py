"""Is this league-week's data good enough to mint a Week Pack from?

Every sport is ON. What decides whether a sport gets a pack in a given week is this contract,
not a hardcoded list: if the ingested week passes, the pack is minted; if not, the verdict says
exactly which clause failed. A sport with no source simply fails the first clause.

THE CONTRACT ("appropriate weekly data")

  1. SOURCED    The sport has a full-league weekly box-score source (`weekly.SOURCES`). A sample
                of the league (a marquee list, a "notable games" sweep) does not count: a board
                titled "top performances" drawn from a sample is wrong without looking wrong.
  2. SCORABLE   The sport has a single-game scoring cohort (`fresh_drop.GAME_COHORTS`), so a
                game line can be ranked on a scale the app already ships.
  3. A REAL WEEK  At least `min_games` games went final in the window. Fewer means preseason,
                the offseason, or a break (All-Star week), not a thin week to dress up.
  4. SETTLED    No game in the window is still pending. Postponed, cancelled and suspended
                games are excluded rather than waited on; anything else unfinished means the
                week is not over yet.
  5. COMPLETE   Every final game has box-score rows for BOTH teams on that game's date. The
                schedule is the oracle and the stats feed is checked against it, because the
                two are posted by different jobs and can disagree for hours.
  6. FRESH      The latest row is dated the window's last game day. Redundant with COMPLETE
                on purpose: it names the failure a stale cache produces.
  7. CLEAN      No player appears twice in one game (a join or paging bug), and enough rows
                carry a provider photo that boards can clear the photo gate.

Clauses 1 to 3 SKIP (exit 0: nothing is wrong, there is just no pack this week). Clauses 4 to 7
BLOCK (exit 1: the data is late or broken upstream, the evergreen daily stays, and a re-run
after the feed catches up fixes it). A pack is then only published if at least
`pack.MIN_ITEMS` boards survive assembly and the photo gate, which is `pack.py`'s job.
"""
from __future__ import annotations

import collections
import dataclasses
import enum

from .periods import Period
from .weekly import WeekData


class Status(enum.Enum):
    READY = "ready"
    SKIP = "skip"
    BLOCKED = "blocked"


@dataclasses.dataclass(frozen=True)
class Rule:
    # A normal regular-season week clears these with room to spare (measured: NFL 13 to 16,
    # MLB about 90, NBA about 50). They are set to catch breaks and season edges, not to
    # police the size of a normal week.
    min_games: int
    min_photo_share: float = 0.8


RULES: dict[str, Rule] = {
    "nfl": Rule(min_games=10),
    "baseball": Rule(min_games=40),
    "nba": Rule(min_games=25),
}
DEFAULT_RULE = Rule(min_games=10)


@dataclasses.dataclass
class Verdict:
    status: Status
    reasons: list[str]
    metrics: dict

    @property
    def ready(self) -> bool:
        return self.status is Status.READY

    def summary(self) -> str:
        head = f"{self.status.value.upper()}"
        detail = "; ".join(self.reasons) if self.reasons else "all clauses pass"
        numbers = ", ".join(f"{k}={v}" for k, v in self.metrics.items())
        return f"{head}: {detail}" + (f" ({numbers})" if numbers else "")


def evaluate(sport: str, period: Period, data: WeekData | None,
             scorable: bool) -> Verdict:
    if data is None:
        return Verdict(Status.SKIP, [f"SOURCED: no full-league weekly box-score source for "
                                     f"{sport} yet"], {})
    if not scorable:
        return Verdict(Status.SKIP, [f"SCORABLE: {sport} has no single-game scoring cohort"], {})

    rule = RULES.get(sport, DEFAULT_RULE)
    counted = [g for g in data.games if not g.excluded]
    final = [g for g in counted if g.final]
    pending = [g for g in counted if not g.final]
    metrics = {"games": len(counted), "final": len(final), "excluded": len(data.games) - len(counted),
               "rows": len(data.rows)}

    if len(final) < rule.min_games:
        return Verdict(Status.SKIP, [f"A REAL WEEK: {len(final)} final game(s), fewer than "
                                     f"{rule.min_games}; out of season or a break"], metrics)

    blocked: list[str] = []
    if pending:
        blocked.append(f"SETTLED: {len(pending)} game(s) not final yet, e.g. "
                       f"{pending[0].away}@{pending[0].home} {pending[0].date}")

    present = {(r.team_abbr, r.event_date) for r in data.rows}
    missing = [g for g in final
               if (g.home, g.date) not in present or (g.away, g.date) not in present]
    metrics["games_with_box_scores"] = len(final) - len(missing)
    if missing:
        sample = ", ".join(f"{g.away}@{g.home} {g.date}" for g in missing[:3])
        blocked.append(f"COMPLETE: {len(missing)} final game(s) have no box score for one or "
                       f"both teams ({sample})")

    last_game_day = max(g.date for g in final)
    last_row_day = max((r.event_date for r in data.rows), default="")
    metrics["last_row_day"] = last_row_day or "none"
    if last_row_day < last_game_day:
        blocked.append(f"FRESH: newest row is {last_row_day or 'absent'}, but games went final "
                       f"through {last_game_day}")

    dupes = [k for k, n in collections.Counter((r.player_id, r.position, r.event_date)
                                               for r in data.rows).items() if n > 1]
    if dupes:
        blocked.append(f"CLEAN: {len(dupes)} player-game line(s) appear twice, e.g. {dupes[0][0]}")
    with_photo = sum(1 for r in data.rows if r.headshot)
    share = round(with_photo / len(data.rows), 3) if data.rows else 0.0
    metrics["photo_share"] = share
    if data.rows and share < rule.min_photo_share:
        blocked.append(f"CLEAN: only {share:.0%} of rows carry a photo (need "
                       f"{rule.min_photo_share:.0%})")

    if blocked:
        return Verdict(Status.BLOCKED, blocked, metrics)
    return Verdict(Status.READY, [], metrics)
