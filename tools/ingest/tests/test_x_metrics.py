"""Calibration math: turn observed metrics into the algorithm's objective, and report it."""
from __future__ import annotations

from tools.marketing import x_algo, x_metrics


def test_action_rates_normalise_by_impressions():
    rates = x_metrics.action_rates({"impression_count": 1000, "like_count": 50, "reply_count": 10})
    assert rates["favorite"] == 0.05
    assert rates["reply"] == 0.01
    assert rates["retweet"] == 0.0


def test_weighted_score_matches_x_algo_and_discounts_oon():
    m = {"impression_count": 1000, "like_count": 100, "reply_count": 20}
    # (0.1 like * 0.5) + (0.02 reply * 5) = 0.05 + 0.10 = 0.15, then * 0.75 OON
    assert abs(x_metrics.weighted_score(m) - 0.15 * x_algo.OON_WEIGHT_FACTOR) < 1e-9
    assert abs(x_metrics.weighted_score(m, out_of_network=False) - 0.15) < 1e-9


def test_zero_impressions_does_not_divide_by_zero():
    assert x_metrics.weighted_score({"like_count": 3}) == 3 * 0.5 * x_algo.OON_WEIGHT_FACTOR


def test_report_ranks_and_names_best_and_worst():
    posts = [
        {"id": "1", "created_at": "2026-09-22T00:00:00Z", "text": "great",
         "public_metrics": {"impression_count": 1000, "like_count": 100, "reply_count": 20}},
        {"id": "2", "created_at": "2026-09-22T01:00:00Z", "text": "meh",
         "public_metrics": {"impression_count": 1000, "like_count": 1, "reply_count": 0}},
    ]
    md = x_metrics.report(posts)
    assert md.index("great") < md.index("meh")       # best first
    assert "Best" in md and "Worst" in md
