"""The fresh-drop workflow's cron wiring.

`fresh-drop.yml` runs one matrix job per sport and gates each on `github.event.schedule`
matching that sport's own cron. That is the mechanism giving every sport its own clock, and it
fails SILENTLY in both directions:

  - a cron in `on.schedule` that no matrix row claims fires five jobs that all skip, so the
    sport never mints and nothing errors;
  - a cron on a matrix row that is not in `on.schedule` never fires at all, so that sport is
    simply switched off.

Neither shows up as a failure anywhere, which is exactly why it is worth a test. Parsed with
the stdlib rather than PyYAML, matching this pipeline's no-third-party-deps contract
(see providers/http.py's module docstring).
"""
from __future__ import annotations

import re
from pathlib import Path

WORKFLOW = (Path(__file__).resolve().parents[3] / ".github" / "workflows" / "fresh-drop.yml")


def _text() -> str:
    assert WORKFLOW.exists(), f"missing workflow: {WORKFLOW}"
    return WORKFLOW.read_text(encoding="utf-8")


def _schedule_crons(text: str) -> list[str]:
    """The crons under `on: schedule:`, i.e. everything before the `workflow_dispatch:` key."""
    head = text.split("workflow_dispatch:", 1)[0]
    return re.findall(r'^\s*-\s*cron:\s*"([^"]+)"', head, re.M)


def _matrix_rows(text: str) -> list[tuple[str, str]]:
    """`(sport, cron)` for each matrix include entry."""
    body = text.split("matrix:", 1)[1]
    return re.findall(r'-\s*sport:\s*(\S+)\s*\n\s*cron:\s*"([^"]+)"', body)


def test_every_scheduled_cron_is_claimed_by_a_sport():
    text = _text()
    scheduled = set(_schedule_crons(text))
    claimed = {cron for _, cron in _matrix_rows(text)}
    assert scheduled - claimed == set(), (
        f"cron(s) fire but no sport claims them, so every job skips: {scheduled - claimed}")


def test_every_sport_has_a_cron_that_actually_fires():
    text = _text()
    scheduled = set(_schedule_crons(text))
    for sport, cron in _matrix_rows(text):
        assert cron in scheduled, (
            f"{sport} is gated on {cron!r}, which is not in `on.schedule`, so it never runs")


def test_all_five_sports_are_present():
    sports = {sport for sport, _ in _matrix_rows(_text())}
    assert sports == {"nfl", "nba", "baseball", "soccer", "tennis"}


def test_the_sports_are_staggered_across_more_than_one_day():
    """The cadence decision, pinned: if every sport ends up on one day again it should be
    because someone changed it deliberately, not because a cron got copy-pasted."""
    days = {cron.split()[-1] for _, cron in _matrix_rows(_text())}
    assert len(days) > 1, f"every sport drops on the same weekday: {days}"


def test_the_cache_eviction_step_runs_before_the_mint():
    """The single most likely silent failure: the nflverse weekly file caches for 30 days, so a
    mint without eviction can serve month-old data and look completely normal."""
    text = _text()
    evict = text.index("--evict-current-season")
    mint = text.index("tools.ingest.fresh_drop")
    assert evict < mint, "the mint must not run before the current-season cache is evicted"


def test_jobs_do_not_fail_fast():
    """One sport's thin week or upstream outage must never cancel the others."""
    assert "fail-fast: false" in _text()
