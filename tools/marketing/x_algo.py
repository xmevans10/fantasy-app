"""The X For You ranking model, as **published** at github.com/xai-org/x-algorithm.

Source of truth: `home-mixer/params/param.rs` (production defaults; last synced 2026-09-21).
Weights multiply the model's *predicted probability* of an action, not raw counts, so the
numbers below are the ranking value of each action, not a count equivalence — the repo itself
calls out the "1 report cancels 468 likes" reading as wrong.

Two consequences drive this repo's growth engine:

* **share-via-copy-link (20) and reply (5, +15 for mutual-follow originals) are the actions worth
  farming**; likes are worth 0.5.
* **mute (-58.8) and report (-234.0) are catastrophic.** Nothing that risks them ships.

`parse_weights` is pure and pinned to a fixture in the tests, so `--sync-algo` can diff our copy
against upstream without network in CI.
"""
from __future__ import annotations

import re
import urllib.request

PARAM_URL = ("https://raw.githubusercontent.com/xai-org/x-algorithm/main/"
             "home-mixer/params/param.rs")

# key -> value. Positive actions first, then the negatives that end reach.
WEIGHTS: dict[str, float] = {
    "share_via_copy_link": 20.0,
    "reply": 5.0,
    "reply_mutual_original_boost": 15.0,
    "quote": 5.0,
    "share_via_dm": 5.0,
    "follow_author": 4.0,
    "share": 2.0,
    "retweet": 1.0,
    "favorite": 0.5,
    "click": 0.4,
    "open_link": 0.2,
    "video_open": 0.07,
    "photo_expand": 0.05,
    "dwell": 0.05,
    "dwell_time_cont": 0.004,
    "quoted_click": 0.05,
    "profile_click": 0.0,
    "vqv": 0.0,
    "not_dwelled": -0.02,
    "block": -31.2,
    "not_interested": -43.2,
    "mute": -58.8,
    "report": -234.0,
}

# Structural adjustments (from the same file) — not per-action scores.
OON_WEIGHT_FACTOR = 0.75              # out-of-network posts are multiplied by this
AUTHOR_DIVERSITY_DECAY = 0.5          # 2nd post from one author in a feed
AUTHOR_DIVERSITY_FLOOR = 0.25
COLD_START_IMPRESSION_THRESHOLD = 1000
COLD_START_FOLLOWER_CAP = 1000
COLD_START_SLOT_MIN, COLD_START_SLOT_MAX = 15, 16
MAX_POST_AGE_HOURS = 48

# What we optimize for. Everything else is secondary.
TARGET_ACTIONS = ("share_via_copy_link", "reply")

# `RustName -> our key`, for parsing the upstream file.
_PARAM_TO_KEY = {
    "ShareViaCopyLinkWeight": "share_via_copy_link",
    "ReplyWeight": "reply",
    "BidirectionalFollowReplyWeightBoost": "reply_mutual_original_boost",
    "QuoteWeight": "quote",
    "ShareViaDmWeight": "share_via_dm",
    "FollowAuthorWeight": "follow_author",
    "ShareWeight": "share",
    "RetweetWeight": "retweet",
    "FavoriteWeight": "favorite",
    "ClickWeight": "click",
    "OpenLinkWeight": "open_link",
    "VideoOpenWeight": "video_open",
    "PhotoExpandWeight": "photo_expand",
    "DwellWeight": "dwell",
    "ContDwellTimeWeight": "dwell_time_cont",
    "QuotedClickWeight": "quoted_click",
    "ProfileClickWeight": "profile_click",
    "VqvWeight": "vqv",
    "NotDwelledWeight": "not_dwelled",
    "BlockAuthorWeight": "block",
    "NotInterestedWeight": "not_interested",
    "MuteAuthorWeight": "mute",
    "ReportWeight": "report",
}

_PARAM_RE = re.compile(
    r"param!\(\s*(\w+),\s*f64,\s*\"[^\"]+\",\s*(-?\d+(?:\.\d+)?)\s*\)", re.S)


def parse_weights(text: str) -> dict[str, float]:
    """Extract the known f64 weights from an upstream `param.rs` body. Pure; ignores params we
    don't track (retrieval knobs, experiment ids)."""
    out: dict[str, float] = {}
    for name, value in _PARAM_RE.findall(text):
        key = _PARAM_TO_KEY.get(name)
        if key:
            out[key] = float(value)
    return out


def sync_algo() -> dict[str, float]:
    """Fetch the upstream params and return the first key whose value drifted from ours."""
    with urllib.request.urlopen(PARAM_URL, timeout=60) as r:
        upstream = parse_weights(r.read().decode())
    return {k: v for k, v in upstream.items() if k in WEIGHTS and WEIGHTS[k] != v}


# ── scoring ──────────────────────────────────────────────────────────────────────

def score(actions: dict[str, float], *, mutual_original: bool = False,
          out_of_network: bool = False) -> float:
    """Ranking score for one post from predicted/observed action values (all in the same units,
    e.g. rates per impression). Mirrors `RankingScorer`: weighted sum, then the OON discount."""
    total = sum(WEIGHTS.get(k, 0.0) * v for k, v in actions.items())
    if mutual_original:
        total += WEIGHTS["reply_mutual_original_boost"] * actions.get("reply", 0.0)
    if out_of_network:
        total *= OON_WEIGHT_FACTOR
    return total


# ── reply targeting ──────────────────────────────────────────────────────────────

# Topics we never touch. A joke on any of these reads as cruel and risks the -234 report weight.
RISK_TERMS = (
    "injur", "acl", "torn", "surgery", "out for the season", "concussion", "hospital",
    "died", "death", "passed away", "rip ", "cancer", "diagnos", "illness", "hospice",
    "arrest", "charged", "lawsuit", "domestic", "assault", "suspended by",
    "election", "president", "senator", "congress", "immigration", "war", "shooting",
)


def is_risky(text: str) -> bool:
    low = (text or "").lower()
    return any(term in low for term in RISK_TERMS)


def reply_opportunity(likes: int, replies: int, age_minutes: float, *,
                      topical: float = 1.0, risky: bool = False) -> float:
    """How worth replying a post is. Reach on a reply is a timing-and-competition problem, not a
    wit problem: a fresh post with few replies (high reach-per-sibling) beats a viral-but-old one.

    * reach-per-sibling = (likes + 1) / (replies + 1)
    * freshness = 1 / (1 + age/30min)   — halves over half an hour
    * topical   = how much our data can add (1.0 = neutral; 0 = can't add anything)
    """
    if risky:
        return 0.0
    age = max(0.0, age_minutes)
    competition = (likes + 1) / (replies + 1)
    freshness = 1.0 / (1.0 + age / 30.0)
    return round(competition * freshness * topical, 4)


def main() -> int:
    import argparse
    import json
    ap = argparse.ArgumentParser(description="X algorithm weights (published).")
    ap.add_argument("--sync-algo", action="store_true",
                    help="diff our weights against the upstream param.rs")
    args = ap.parse_args()
    if args.sync_algo:
        drift = sync_algo()
        print(json.dumps(drift, indent=1) if drift else "in sync")
        return 0
    print(json.dumps(WEIGHTS, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
