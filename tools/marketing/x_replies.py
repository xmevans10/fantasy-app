"""Reply targeting: find *rising* posts worth replying to, rank them by reply reach, and emit
briefs an agent (or, later, an LLM) writes from.

The core insight is in `x_algo.reply_opportunity`: reach on a reply is a **timing + competition**
problem, not a wit problem. An early reply to a post with 4 replies is seen; a late reply to a
post with 106 is not. So this ranks by (reach per sibling) × freshness × topical fit, and hard-skips
anything that risks the -234 report weight.

Deterministic templates cannot be genuinely hip — that is Phase 2 (an LLM). So the default output
is a **brief**, not a post: the target, its numbers, and the angles that fit, ready for a writer.
Posting is available (`--post-id` + `--text`) but off unless you ask for it.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import urllib.error
import urllib.parse
import urllib.request

from . import x_algo, x_engine, x_oauth1

# Accounts whose posts move sports Twitter. Reply here, early.
ACCOUNTS = (
    "ShamsCharania", "AdamSchefter", "NFL", "NBA", "MLB", "ESPN", "SportsCenter",
    "BleacherReport", "statmuse", "HoopCentral", "ClutchPoints", "TheNBACentral",
    "overtime", "PFTCommenter", "BarstoolSports", "DovKleiman",
)

VOICE = ("first person, confident, lowercase-leaning, <=140 chars, no hashtags, no links; "
         "add one true thing or ask one sharp question; never an ad")


def _auth():
    """Prefer OAuth1 (non-rotating, and present in CI via Supabase); fall back to the app-only
    bearer from the local file for laptop use."""
    creds = x_oauth1.credentials()
    if creds:
        return ("oauth1", creds)
    from . import x_client
    return ("bearer", urllib.parse.unquote(x_client.load_env()["X_BEARER_TOKEN"]))


def _get(path: str, auth) -> dict:
    url = "https://api.x.com/2" + path
    kind, tok = auth
    if kind == "oauth1":
        base, _, qs = url.partition("?")
        return x_oauth1.get_json(base, tok, dict(urllib.parse.parse_qsl(qs)) if qs else {})
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def fetch_candidates(*, minutes: int = 30, accounts=ACCOUNTS, auth=None) -> list[dict]:
    """Recent original posts from the watchlist, still young enough to reply into."""
    auth = auth or _auth()
    now = dt.datetime.now(dt.timezone.utc)
    out: list[dict] = []
    for acct in accounts:
        try:
            uid = _get(f"/users/by/username/{urllib.parse.quote(acct)}", auth)["data"]["id"]
            data = _get(f"/users/{uid}/tweets?max_results=10&exclude=retweets,replies"
                        f"&tweet.fields=created_at,public_metrics", auth)
        except (urllib.error.HTTPError, KeyError):
            continue
        for tw in data.get("data", []):
            age = (now - dt.datetime.fromisoformat(tw["created_at"].replace("Z", "+00:00"))
                   ).total_seconds() / 60
            if age > minutes:
                continue
            m = tw["public_metrics"]
            out.append({"acct": acct, "id": tw["id"], "age": round(age, 1),
                        "likes": m.get("like_count", 0), "replies": m.get("reply_count", 0),
                        "text": tw["text"]})
    return out


def rank(candidates: list[dict]) -> list[dict]:
    """Drop risky posts and the ones we have nothing to add to, then sort by reach-per-sibling."""
    ranked = []
    for c in candidates:
        if x_algo.is_risky(c["text"]):
            continue
        opp = x_algo.reply_opportunity(c["likes"], c["replies"], c["age"])
        ranked.append({**c, "opportunity": opp})
    ranked.sort(key=lambda c: -c["opportunity"])
    return ranked


def brief(c: dict) -> str:
    """A writing brief: the target, its numbers, and the angles that fit the algo."""
    return (f'@ {c["acct"]}  ·  {c["age"]}m old  ·  {c["likes"]} likes / {c["replies"]} replies  '
            f'·  opportunity {c["opportunity"]}\n'
            f'   post : {c["text"].strip()[:280]}\n'
            f'   chose: reach per sibling × freshness (reply is weight {x_algo.WEIGHTS["reply"]}; '
            f'+{x_algo.WEIGHTS["reply_mutual_original_boost"]} if you mutually follow)\n'
            f'   angle: add one true stat, or ask one sharp question\n'
            f'   voice: {VOICE}\n'
            f'   post a reply with: x_replies --post-id {c["id"]} --text "..."')


def post_reply(tweet_id: str, text: str) -> str:
    """Reply with the OAuth1 user token; recorded in the ledger so a re-run cannot double-post."""
    creds = x_oauth1.credentials()
    if not creds:
        raise SystemExit("[replies] OAuth1 credentials required")
    tid = x_oauth1.post_tweet(text, creds, reply_to=tweet_id)
    x_engine.ledger_record(f"reply:{tweet_id}", tid, dt.date.today().isoformat(), "reply", "")
    return tid


def main() -> int:
    ap = argparse.ArgumentParser(description="Reply targeting / drafting for X.")
    ap.add_argument("--minutes", type=int, default=30, help="only posts younger than this")
    ap.add_argument("--cap", type=int, default=5)
    ap.add_argument("--accounts", default=None, help="comma list; default the watchlist")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--post-id", default=None, help="reply to this tweet id")
    ap.add_argument("--text", default=None, help="the reply text (with --post-id)")
    args = ap.parse_args()

    if args.post_id:
        if not args.text:
            raise SystemExit("--post-id needs --text")
        if x_algo.is_risky(args.text):
            raise SystemExit("refusing: reply text looks risky")
        print("posted:", post_reply(args.post_id, args.text))
        return 0

    accounts = tuple(a.strip() for a in args.accounts.split(",")) if args.accounts else ACCOUNTS
    ranked = rank(fetch_candidates(minutes=args.minutes, accounts=accounts))[:args.cap]
    if args.json:
        print(json.dumps(ranked, indent=1))
        return 0
    if not ranked:
        print(f"[replies] no non-risky posts under {args.minutes}m in the watchlist right now")
        return 0
    print(f"# Reply targets ({len(ranked)})\n")
    for c in ranked:
        print(brief(c), "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
