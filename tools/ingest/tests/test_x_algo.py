"""The published X ranking weights and the two scoring functions built on them."""
from __future__ import annotations

from tools.marketing import x_algo

_FIXTURE = '''
param!(FavoriteWeight, f64, "rust_home_mixer_favorite_weight", 0.5);
param!(ReplyWeight, f64, "rust_home_mixer_reply_weight", 5.0);
param!(
    BidirectionalFollowReplyWeightBoost,
    f64,
    "rust_home_mixer_bidirectional_follow_reply_weight_boost",
    15.0
);
param!(ReportWeight, f64, "rust_home_mixer_report_weight", -234.0);
param!(MuteAuthorWeight, f64, "rust_home_mixer_mute_author_weight", -58.8);
param!(SomeUntrackedKnob, f64, "rust_home_mixer_untracked", 3.0);
'''


def test_parse_weights_reads_multiline_params_and_ignores_untracked():
    w = x_algo.parse_weights(_FIXTURE)
    assert w["favorite"] == 0.5
    assert w["reply"] == 5.0
    assert w["reply_mutual_original_boost"] == 15.0
    assert w["report"] == -234.0
    assert w["mute"] == -58.8
    # only tracked params are kept; SomeUntrackedKnob is ignored
    assert set(w) == {"favorite", "reply", "reply_mutual_original_boost", "report", "mute"}


def test_weights_match_the_documented_table():
    assert x_algo.WEIGHTS["share_via_copy_link"] == 20.0
    assert x_algo.WEIGHTS["reply"] == 5.0
    assert x_algo.WEIGHTS["report"] == -234.0
    # share-via-copy-link is the highest-valued action, by design of the strategy.
    assert max(x_algo.WEIGHTS.values()) == x_algo.WEIGHTS["share_via_copy_link"]


def test_score_is_a_weighted_sum():
    assert x_algo.score({"favorite": 1.0}) == 0.5
    assert x_algo.score({"reply": 1.0}) == 5.0
    assert x_algo.score({"favorite": 0.1, "reply": 0.1}) == 0.55


def test_mutual_original_reply_boost_and_oon_discount():
    assert x_algo.score({"reply": 1.0}, mutual_original=True) == 20.0     # 5 + 15
    assert x_algo.score({"favorite": 1.0}, out_of_network=True) == 0.375  # 0.5 * 0.75


def test_reply_opportunity_prefers_fresh_and_uncrowded():
    fresh = x_algo.reply_opportunity(100, 3, 5)
    old = x_algo.reply_opportunity(100, 3, 300)
    crowded = x_algo.reply_opportunity(100, 300, 5)
    assert fresh > old > 0
    assert fresh > crowded
    assert x_algo.reply_opportunity(100, 3, 5, topical=0.5) < fresh
    assert x_algo.reply_opportunity(100, 3, 5, risky=True) == 0.0


def test_risk_filter_blocks_the_topics_that_earn_reports():
    assert x_algo.is_risky("Star QB tears his ACL, out for the season")
    assert x_algo.is_risky("Coach addresses the shooting")
    assert not x_algo.is_risky("Jokic posts a 30-15-15 line in the win")
