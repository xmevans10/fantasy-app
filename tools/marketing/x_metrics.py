"""Calibration: measure our own posts against the published ranking weights.

We cannot see the model's predicted probabilities, so we use observed actions per impression as
the proxy, weight them with `x_algo`, and rank our posts by the algorithm's own objective. That
turns "is this good?" into a number, weekly, per format and per hour.

Pulls `organic_metrics` + `non_public_metrics` (impressions, link clicks, profile clicks) with the
OAuth1 user token. Note the limit, stated plainly: X does not expose *share-via-copy-link* per post,
and that is the single highest-weighted action (20) — so the score here under-counts the artifact
our share grid is built to produce. Reconcile that with the store-link `ct=` click-throughs.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json

from . import x_algo, x_engine, x_oauth1

# X metric field -> our weight key. Unmapped metrics (bookmark_count, etc.) carry no published
# weight, so including them would be inventing signal.
_METRIC_KEYS = {
    "like_count": "favorite",
    "reply_count": "reply",
    "retweet_count": "retweet",
    "quote_count": "quote",
    "url_link_clicks": "open_link",
    "user_profile_clicks": "profile_click",
}


def action_rates(metrics: dict) -> dict[str, float]:
    """Observed action values normalised by impressions — the units `x_algo.score` expects."""
    impressions = max(int(metrics.get("impression_count", 0) or 0), 1)
    return {key: (metrics.get(field, 0) or 0) / impressions
            for field, key in _METRIC_KEYS.items()}


def weighted_score(metrics: dict, *, out_of_network: bool = True) -> float:
    """The algorithm's objective, as a per-post proxy. OON is the honest default: most viewers of
    a small account's post do not follow it."""
    return x_algo.score(action_rates(metrics), out_of_network=out_of_network)


def fetch_posts(user_id: str, *, days: int = 7, creds: dict | None = None,
                max_results: int = 100) -> list[dict]:
    """Our own recent posts with organic + non-public metrics (user context required)."""
    # KV-aware: reads .env locally and the Supabase store in CI (see x_engine.oauth1_creds).
    creds = creds or x_engine.oauth1_creds()
    if not creds:
        raise SystemExit("[metrics] OAuth1 credentials required (run x_engine --oauth1-begin/pin)")
    out: list[dict] = []
    token = None
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
    while True:
        # No `start_time`: the API rejects it on this plan tier (400); filter client-side instead.
        query = {"max_results": min(max_results, 100),
                 "tweet.fields": "created_at,public_metrics,organic_metrics,non_public_metrics",
                 "exclude": "retweets"}
        if token:
            query["pagination_token"] = token
        data = x_oauth1.get_json(f"https://api.x.com/2/users/{user_id}/tweets", creds, query)
        for post in data.get("data", []):
            created = post.get("created_at")
            if created and dt.datetime.fromisoformat(created.replace("Z", "+00:00")) < cutoff:
                return out                                    # newest-first: everything after is older
            out.append(post)
        token = data.get("meta", {}).get("next_token")
        if not token or len(out) >= max_results:
            break
    return out


def _merged_metrics(post: dict) -> dict:
    return {**(post.get("public_metrics") or {}), **(post.get("organic_metrics") or {})}


def report(posts: list[dict], *, top: int = 12) -> str:
    """Markdown: our posts ranked by the algorithm's objective, with the standout/bottom lines."""
    rows = []
    for p in posts:
        m = _merged_metrics(p)
        imp = m.get("impression_count", 0) or 0
        # Organic impressions lag by hours on a fresh post; until they land we cannot form a rate,
        # so the post is not ranked (else a 0-impression post with one reply scores top).
        rows.append({"id": p["id"], "at": (p.get("created_at") or "")[:16], "imp": imp,
                     "like": m.get("like_count", 0), "re": m.get("reply_count", 0),
                     "rt": m.get("retweet_count", 0),
                     "score": weighted_score(m) if imp else 0.0,
                     "text": p["text"].replace("\n", " ")[:80]})
    rows.sort(key=lambda r: -r["score"])
    lines = ["| score | imp | like | repl | rt | when | post |",
             "|---|---|---|---|---|---|---|"]
    for r in rows[:top]:
        lines.append(f'| {r["score"]:.4f} | {r["imp"]} | {r["like"]} | {r["re"]} | {r["rt"]} '
                     f'| {r["at"]} | {r["text"]} |')
    if rows:
        lines += ["", f"**{len(rows)} posts. Best:** {rows[0]['text']!r} "
                      f"({rows[0]['score']:.4f}). **Worst:** {rows[-1]['text']!r} "
                      f"({rows[-1]['score']:.4f})."]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Calibrate our X posts against the ranking weights.")
    ap.add_argument("--user-id", default="1903083286047387648", help="@_Playbook_ (default)")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--json", action="store_true", help="raw JSON instead of the markdown report")
    args = ap.parse_args()
    posts = fetch_posts(args.user_id, days=args.days)
    if args.json:
        print(json.dumps(posts, indent=1))
    else:
        md = report(posts)
        print(md or "(no posts in window)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
