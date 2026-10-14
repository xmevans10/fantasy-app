"""Offline tests for the golf provider (ESPN PGA Tour core-API sweep). No network: the
season-stat and bio parsing are pure functions fed captured payload shapes."""
import csv

from tools.ingest.grade import grade
from tools.ingest.providers import golf_pga


def _stats_payload(**overrides):
    """One `.../athletes/{id}/statistics` response, general category only (the shape this
    provider actually reads — see `_parse_season_stats`)."""
    values = {
        "tournamentsPlayed": 20.0, "wins": 1.0, "topTenFinishes": 5.0, "cutsMade": 16.0,
        "officialAmount": 4_500_000.0, "scoringAverage": 70.2, "cupPoints": 450.0,
    }
    values.update(overrides)
    return {"splits": {"categories": [{"name": "general",
                                       "stats": [{"name": k, "value": v}
                                                for k, v in values.items()]}]}}


def test_parse_season_stats_reads_the_general_category():
    stats = golf_pga._parse_season_stats(_stats_payload())
    assert stats == {
        "events": 20.0, "wins": 1.0, "top10s": 5.0, "cuts_made": 16.0,
        "earnings": 4_500_000.0, "scoring_avg": 70.2, "fedex_points": 450.0,
    }


def test_parse_season_stats_returns_none_with_no_categories():
    """A handful of leader-list entries point at a season with an incomplete/withdrawn stat
    record — no categories at all, not zeros. Must not fabricate a zero-stat season."""
    assert golf_pga._parse_season_stats({"splits": {"categories": []}}) is None
    assert golf_pga._parse_season_stats({"splits": {}}) is None


def test_country_from_flag_parses_the_espn_filename():
    assert golf_pga._country_from_flag(
        "https://a.espncdn.com/i/teamlogos/countries/500/eng.png") == "ENG"
    assert golf_pga._country_from_flag(
        "https://a.espncdn.com/i/teamlogos/countries/500/rsa.png") == "RSA"
    assert golf_pga._country_from_flag("") == ""
    assert golf_pga._country_from_flag("https://example.com/not-a-flag.png") == ""


def test_load_seasons_round_trips_committed_csv(tmp_path, monkeypatch):
    csv_path = tmp_path / "golf_seasons.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=golf_pga.CSV_FIELDS)
        w.writeheader()
        w.writerow({
            "name": "Test Golfer", "athlete_id": "123", "country": "USA",
            "season_year": 2022, "events": 22, "wins": 2, "top10s": 9, "cuts_made": 18,
            "earnings": 8_200_000.0, "scoring_avg": 69.4, "fedex_points": 900.0,
            "headshot": "https://a.espncdn.com/i/headshots/golf/players/full/123.png",
        })
    monkeypatch.setattr(golf_pga, "CSV_PATH", csv_path)

    seasons = golf_pga.load_seasons()
    assert len(seasons) == 1
    s = seasons[0]
    assert s.sport == "golf" and s.position == "Golfer"
    assert s.team_abbr == "USA" and s.season_year == 2022
    assert s.person_id == "123"
    assert s.headshot == "https://a.espncdn.com/i/headshots/golf/players/full/123.png"
    assert s.stats["wins"] == 2.0 and s.stats["cuts_made"] == 18.0
    assert s.stats["scoring_avg"] == 69.4
    # Derived grading term: (BASELINE_SCORING_AVG - scoring_avg) * events.
    expected_margin = round((golf_pga.BASELINE_SCORING_AVG - 69.4) * 22, 1)
    assert s.stats["scoring_margin"] == expected_margin


def test_load_seasons_is_empty_with_no_committed_csv(tmp_path, monkeypatch):
    monkeypatch.setattr(golf_pga, "CSV_PATH", tmp_path / "does_not_exist.csv")
    assert golf_pga.load_seasons() == []


def test_a_dominant_season_outranks_a_replacement_level_one():
    """A multi-win, low-scoring-average season must clearly outrank a season that barely
    keeps its tour card — the same monotonicity bar every other sport's fantasy scale holds."""
    elite = {"wins": 3.0, "top10s": 12.0, "cuts_made": 20.0, "events": 23.0,
             "earnings": 12_000_000.0, "scoring_margin": (71.0 - 68.9) * 23.0}
    replacement = {"wins": 0.0, "top10s": 1.0, "cuts_made": 14.0, "events": 22.0,
                  "earnings": 900_000.0, "scoring_margin": (71.0 - 71.8) * 22.0}
    assert grade(elite, "golf_fantasy") > grade(replacement, "golf_fantasy") + 100


def test_scoring_margin_rewards_a_lower_average_at_equal_volume():
    """The whole point of `scoring_margin`: two golfers with identical counting stats must be
    separated by who actually scored better, in the direction a fan expects (lower wins)."""
    better_scorer = {"wins": 1.0, "top10s": 6.0, "cuts_made": 17.0, "events": 20.0,
                     "earnings": 3_000_000.0, "scoring_margin": (71.0 - 69.0) * 20.0}
    worse_scorer = {"wins": 1.0, "top10s": 6.0, "cuts_made": 17.0, "events": 20.0,
                    "earnings": 3_000_000.0, "scoring_margin": (71.0 - 71.5) * 20.0}
    assert grade(better_scorer, "golf_fantasy") > grade(worse_scorer, "golf_fantasy")


def test_golf_has_no_positional_stat_families():
    """Single position "Golfer", like tennis's "Player" and F1's "Driver" — no
    position-specific stat family should ever be declared for golf."""
    from tools.ingest import grid_axes
    assert "golf" not in grid_axes._POSITIONS


def test_golf_is_not_team_mobile():
    """No clubs in golf — `team_abbr` is a nationality code, mirroring tennis, and golf must
    stay out of TEAM_MOBILE_SPORTS the same way tennis does (see grid_axes' own comment)."""
    from tools.ingest import grid_axes
    assert "golf" not in grid_axes.TEAM_MOBILE_SPORTS


def test_golf_has_no_journeyman_entry():
    """No club careers -> no Journeyman board, the same rule that keeps tennis out."""
    from tools.ingest import journeyman
    assert "golf" not in journeyman.MIN_STINTS


def test_missing_scoring_avg_and_fedex_are_omitted_not_zero(tmp_path, monkeypatch):
    """ESPN writes 0.0 where it has no value. A 0 scoring average would rank as the best season
    ever and turn `scoring_margin` into ~71 x events, which swamped every golf board (measured
    p99 of 2,143 points before this fix). Both must be absent, like any stat never recorded."""
    csv_path = tmp_path / "golf_seasons.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=golf_pga.CSV_FIELDS)
        w.writeheader()
        w.writerow({
            "name": "Short Card", "athlete_id": "9", "country": "ESP", "season_year": 2018,
            "events": 15, "wins": 0, "top10s": 3, "cuts_made": 7, "earnings": 878_354.0,
            "scoring_avg": 0.0, "fedex_points": 0.0, "headshot": "",
        })
    monkeypatch.setattr(golf_pga, "CSV_PATH", csv_path)

    (s,) = golf_pga.load_seasons()
    assert "scoring_avg" not in s.stats
    assert "scoring_margin" not in s.stats
    assert "fedex_points" not in s.stats
    assert s.stats["events"] == 15.0


def test_committed_csv_grades_stay_in_a_sane_range():
    """Every real season grades like a résumé, never like a unit error. The real ceiling is
    Vijay Singh's 9-win 2004 at ~499; the worst case before the omission fix was a 0-average
    season at ~2,800 points."""
    seasons = golf_pga.load_seasons()
    if not seasons:
        return
    worst = max(grade(s.stats, "golf_fantasy") for s in seasons)
    assert worst < 600, worst


def test_career_scoring_avg_ignores_seasons_without_one():
    from tools.ingest.career import _aggregate_stats
    from tools.ingest.models import RawSeason

    def season(year, stats):
        return RawSeason(name="G", team_abbr="USA", season_year=year, sport="golf",
                         position="Golfer", stats=stats, source="t")

    rows = [season(2020, {"events": 20.0, "scoring_avg": 70.0}),
            season(2021, {"events": 10.0})]   # no official average that year
    assert _aggregate_stats("golf", rows)["scoring_avg"] == 70.0


# ── Unofficial-event correction (2026-09-27) ───────────────────────────────────
#
# ESPN's season `wins`/`topTenFinishes` double-count small-field exhibitions that pay real
# money but earn no official PGA Tour credit (Hero World Challenge and its earlier sponsor
# names: Target/Chevron/Northwestern Mutual World Challenge). Verified live against the
# official record: Jordan Spieth's 2015 season shows 6 wins/16 top-10s here vs. an official
# 5/15 — the extra credit is the Dec-2014 Hero World Challenge, an 18-player no-cut field
# whose winner's own per-event `officialAmount` reads $0 (every real Tour win reads > 0).
#
# Two things make a single cheap check unsafe on its own, both confirmed live and pinned here:
# - the event's own embedded `competitors[].earnings` is NOT reliable by itself — the same
#   always-unofficial event shows it as 0 some years and a real payout other years;
# - a bare "winner earnings == 0" check false-positives on a genuinely OFFICIAL event with a
#   data gap (the 2015 Barbasol Championship: a corrupted, garbage-id competitor record for
#   that one season) — field SIZE (`_MAX_EXHIBITION_FIELD`) is what keeps a real 70+ player
#   Tour field out of consideration regardless of how broken its record looks that year.

def _ref(path: str) -> dict:
    return {"$ref": f"https://sports.core.api.espn.com/v2/sports/golf/{path}"}


def _competitor(athlete_id: str, event_id: str, *, statistics_ref: str | None = None) -> dict:
    return {
        "athlete": _ref(f"leagues/pga/seasons/2099/athletes/{athlete_id}?lang=en&region=us"),
        "status": _ref(f"leagues/pga/events/{event_id}/competitions/{event_id}/"
                       f"competitors/{athlete_id}/status?lang=en&region=us"),
        "statistics": _ref(statistics_ref) if statistics_ref else
                     _ref(f"leagues/pga/events/{event_id}/competitions/{event_id}/"
                          f"competitors/{athlete_id}/statistics?lang=en&region=us"),
        "earnings": 0.0,   # deliberately unreliable — the fix must not read this field at all
    }


def test_ref_id_reads_the_trailing_numeric_id():
    assert golf_pga._ref_id("https://x/y/athletes/5467?lang=en&region=us") == "5467"
    assert golf_pga._ref_id("https://x/y/athletes/5467") == "5467"
    assert golf_pga._ref_id("") == ""
    # A corrupted record's garbage host doesn't matter — only the trailing id shape does,
    # and a real ESPN athlete id is always a plain integer.
    assert golf_pga._ref_id("https://x/v2/spade/golf/.../athletes/1?lang=en") == "1"


def test_winner_official_amount_reads_the_general_category():
    payload = _stats_payload(officialAmount=0.0)
    assert golf_pga._winner_official_amount(payload) == 0.0
    payload2 = _stats_payload(officialAmount=1_800_000.0)
    assert golf_pga._winner_official_amount(payload2) == 1_800_000.0


def test_winner_official_amount_is_none_with_no_categories():
    """A corrupted per-event record (see the Barbasol note) must read as 'unknown', never as
    a confident $0 — the caller treats None as 'leave this event alone'."""
    assert golf_pga._winner_official_amount({"splits": {"categories": []}}) is None


def _mock_fetch(monkeypatch, responses: dict[str, dict]):
    """Route every `fetch_json` call in `golf_pga` by exact `$ref` URL match, ignoring the
    real cache entirely (no network, no disk) — `is_cached` always reports a miss."""
    def fake_fetch_json(url, *, headers=None, cache_key=None, ttl_hours=24.0):
        try:
            return responses[url]
        except KeyError:
            raise AssertionError(f"unexpected fetch_json call: {url}") from None
    monkeypatch.setattr(golf_pga, "fetch_json", fake_fetch_json)
    monkeypatch.setattr(golf_pga, "is_cached", lambda *a, **k: False)


def test_find_unofficial_events_confirms_via_official_amount_not_embedded_earnings(monkeypatch):
    """The core case: a small no-cut field whose winner reads $0 officialAmount. Every entrant
    loses one event credit; only real top-10 finishers (by their OWN status, not list order)
    lose a top10 credit, and only the winner loses a win credit."""
    comps = [_competitor(str(100 + i), "9001") for i in range(12)]
    responses = {
        golf_pga._EVENTS_URL.format(year=2099):
            {"items": [_ref("leagues/pga/events/9001?lang=en&region=us")]},
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/9001?lang=en&region=us":
            {"competitions": [{"competitors": comps}]},
    }
    # Positions: winner is athlete 100 (pos 1); 101-109 fill 2nd-10th (all "top 10"); 110/111
    # finish 11th/12th (outside top 10, no credit removed for them beyond the event start).
    for i, comp in enumerate(comps):
        aid = str(100 + i)
        pos = i + 1
        responses[comp["status"]["$ref"]] = {"position": {"id": str(pos), "displayName": str(pos)}}
    responses[comps[0]["statistics"]["$ref"]] = _stats_payload(officialAmount=0.0)

    _mock_fetch(monkeypatch, responses)
    deltas = golf_pga._find_unofficial_events(2099)

    assert deltas["100"] == {"events": 1, "wins": 1, "top10s": 1}      # the winner
    assert deltas["105"] == {"events": 1, "wins": 0, "top10s": 1}      # a top-10 finisher
    assert deltas["109"] == {"events": 1, "wins": 0, "top10s": 1}      # exactly 10th, still in
    assert deltas["110"] == {"events": 1, "wins": 0, "top10s": 0}      # 11th — event only
    assert deltas["111"] == {"events": 1, "wins": 0, "top10s": 0}      # 12th — event only


def test_find_unofficial_events_skips_a_real_tour_field(monkeypatch):
    """Field size alone rules out a real Tour event, with NO further calls made — this is
    what protects a genuinely official event with a corrupted/incomplete record for one
    season (verified live: the 2015 Barbasol Championship) from ever being misclassified."""
    comps = [_competitor(str(i), "9002") for i in range(80)]   # a real, 80-player field
    responses = {
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/2099/types/2/"
        "events?limit=200": {"items": [_ref("leagues/pga/events/9002?lang=en&region=us")]},
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/9002?lang=en&region=us":
            {"competitions": [{"competitors": comps}]},
    }
    _mock_fetch(monkeypatch, responses)
    assert golf_pga._find_unofficial_events(2099) == {}


def test_find_unofficial_events_skips_when_winner_is_official(monkeypatch):
    """A real win (officialAmount > 0) must never be touched, even in a small field (a
    limited-field WGC-style invitational is still an official Tour win)."""
    comps = [_competitor(str(200 + i), "9003") for i in range(18)]
    responses = {
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/2099/types/2/"
        "events?limit=200": {"items": [_ref("leagues/pga/events/9003?lang=en&region=us")]},
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/9003?lang=en&region=us":
            {"competitions": [{"competitors": comps}]},
    }
    for i, comp in enumerate(comps):
        responses[comp["status"]["$ref"]] = {"position": {"id": str(i + 1)}}
    responses[comps[0]["statistics"]["$ref"]] = _stats_payload(officialAmount=1_800_000.0)

    _mock_fetch(monkeypatch, responses)
    assert golf_pga._find_unofficial_events(2099) == {}


def test_find_unofficial_events_skips_a_corrupted_small_field(monkeypatch):
    """No competitor resolves to finish position 1 (every status lookup fails or returns
    nothing usable) — exactly the 2015 Barbasol Championship shape, if its 80-player field
    had somehow been small enough to reach this check. Leave it alone rather than guess."""
    comps = [_competitor(str(300 + i), "9004") for i in range(5)]
    responses = {
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/2099/types/2/"
        "events?limit=200": {"items": [_ref("leagues/pga/events/9004?lang=en&region=us")]},
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/9004?lang=en&region=us":
            {"competitions": [{"competitors": comps}]},
    }
    for comp in comps:
        responses[comp["status"]["$ref"]] = {"position": {}}   # no usable id anywhere
    _mock_fetch(monkeypatch, responses)
    assert golf_pga._find_unofficial_events(2099) == {}


def test_find_unofficial_events_ignores_team_events_with_no_competitors(monkeypatch):
    """Presidents Cup / Ryder Cup: team match play, no individual stroke-play competitors —
    there's nothing here to attribute a win or top-10 to."""
    responses = {
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/2099/types/2/"
        "events?limit=200": {"items": [_ref("leagues/pga/events/9005?lang=en&region=us")]},
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/9005?lang=en&region=us":
            {"competitions": [{"competitors": []}]},
    }
    _mock_fetch(monkeypatch, responses)
    assert golf_pga._find_unofficial_events(2099) == {}


def test_refresh_asserts_when_the_leaders_list_hits_the_cap(monkeypatch, tmp_path):
    """No real pagination exists on the leaders endpoint (verified live: `offset=` is a
    no-op). Landing exactly on `_LEADERS_LIMIT` must fail loudly — a silent truncation here
    is exactly the M-golf bug this was written to fix (2015's real 636-entry list was cut to
    250 by the old fixed `limit=250`)."""
    leaders_url = golf_pga._LEADERS_URL.format(year=2099, limit=golf_pga._LEADERS_LIMIT)
    capped = {"categories": [{"name": "officialAmount", "leaders": [
        {"athlete": _ref(f"leagues/pga/seasons/2099/athletes/{i}?lang=en&region=us"),
         "statistics": _ref(f"leagues/pga/seasons/2099/types/2/athletes/{i}/statistics/0")}
        for i in range(golf_pga._LEADERS_LIMIT)
    ]}]}
    events_url = ("https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/"
                 "2099/types/2/events?limit=200")

    def fake_fetch_json(url, *, headers=None, cache_key=None, ttl_hours=24.0):
        if url == leaders_url:
            return capped
        if url == events_url:
            return {"items": []}
        raise AssertionError(f"unexpected fetch_json call: {url}")

    monkeypatch.setattr(golf_pga, "fetch_json", fake_fetch_json)
    monkeypatch.setattr(golf_pga, "is_cached", lambda *a, **k: False)
    monkeypatch.setattr(golf_pga, "CSV_PATH", tmp_path / "golf_seasons.csv")

    import pytest
    with pytest.raises(AssertionError, match="hit the .* cap"):
        golf_pga.refresh(2099, 2099)


def test_refresh_applies_the_unofficial_correction_end_to_end(monkeypatch, tmp_path):
    """Integration shape: a golfer whose raw season line includes one small-field unofficial
    win comes out of `refresh()` with events/wins/top10s already corrected, before the
    MIN_EVENTS gate and before the CSV is written — matching Jordan Spieth's real 2015
    correction (6W/16T10/26 events -> 5W/15T10/25 events)."""
    year = 2099
    leaders_url = golf_pga._LEADERS_URL.format(year=year, limit=golf_pga._LEADERS_LIMIT)
    events_url = ("https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/"
                 f"{year}/types/2/events?limit=200")
    stats_ref = ("https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/seasons/"
                f"{year}/types/2/athletes/700/statistics/0")
    athlete_ref = f"https://sports.core.api.espn.com/v2/sports/golf/athletes/700?lang=en&region=us"

    comps = [_competitor(str(700 + i), "9006") for i in range(15)]   # 700 wins
    responses = {
        leaders_url: {"categories": [{"name": "officialAmount", "leaders": [
            {"athlete": _ref("leagues/pga/seasons/2099/athletes/700?lang=en&region=us"),
             "statistics": _ref(stats_ref.split("golf/")[1])},
        ]}]},
        events_url: {"items": [_ref("leagues/pga/events/9006?lang=en&region=us")]},
        "https://sports.core.api.espn.com/v2/sports/golf/leagues/pga/events/9006?lang=en&region=us":
            {"competitions": [{"competitors": comps}]},
        stats_ref: _stats_payload(tournamentsPlayed=26.0, wins=6.0, topTenFinishes=16.0,
                                  cutsMade=22.0, officialAmount=12_030_465.0,
                                  scoringAverage=68.935, cupPoints=6392.0),
        athlete_ref: {"displayName": "Test Winner",
                     "headshot": {"href": "https://a.espncdn.com/i/headshots/golf/players/"
                                          "full/700.png"},
                     "flag": {"href": "https://a.espncdn.com/i/teamlogos/countries/500/usa.png"}},
    }
    for i, comp in enumerate(comps):
        responses[comp["status"]["$ref"]] = {"position": {"id": str(i + 1)}}
    responses[comps[0]["statistics"]["$ref"]] = _stats_payload(officialAmount=0.0)

    _mock_fetch(monkeypatch, responses)
    monkeypatch.setattr(golf_pga.time, "sleep", lambda *_: None)
    csv_path = tmp_path / "golf_seasons.csv"
    monkeypatch.setattr(golf_pga, "CSV_PATH", csv_path)

    golf_pga.refresh(year, year)

    (row,) = list(csv.DictReader(csv_path.open(encoding="utf-8")))
    assert row["athlete_id"] == "700"
    assert int(row["events"]) == 25      # 26 - 1 (the unofficial start)
    assert int(row["wins"]) == 5         # 6 - 1 (the unofficial win)
    assert int(row["top10s"]) == 15      # 16 - 1 (win is also a top-10)
    assert int(row["cuts_made"]) == 22   # untouched — no-cut event, nothing to correct
