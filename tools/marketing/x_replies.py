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

from . import x_algo, x_cache, x_engine, x_oauth1, x_voice

# X bills per post read (~$0.0052, measured 2026-09-22). Cache ids for a week, timelines briefly,
# and hard-stop a run once it has read `max_reads` posts.
UID_TTL = 7 * 24 * 3600
TIMELINE_TTL = 180
DEFAULT_MAX_READS = 250

# Curated account list. Categories have different jobs:
#
# * reply_*      — sources of posts to reply to (news = fast/comps-heavy; banter = where wit
#                  lands; stats = our own register). Sorted in `rank()` by reach-per-sibling.
# * follow_candidates — mid-tier, in-niche accounts we FOLLOW to seek the mutual-follow reply
#                  boost (+15, i.e. reply weight 20). Big accounts never follow back; these might.
#                  Building mutuals is the single most algo-aligned reason to follow.
# * niche        — hockey/F1/soccer/tennis, where the app is differentiated and the giants are not.
# * competitors  — study only; never reply-spam them.
#
# Handles verified by resolution at runtime (`--list-accounts` resolves; failures are skipped).
# Some are best-effort and may 404 once credits return.
ME = "1903083286047387648"                     # @_Playbook_, never follow ourselves

CURATED: dict[str, list[str]] = {
    "reply_news": ["AdamSchefter", "ShamsCharania", "TomPelissero", "RapSheet", "NFL", "NBA",
                   "MLB", "ESPN", "SportsCenter", "BleacherReport"],
    "reply_banter": ["PFTCommenter", "BallsackSports", "NBAMemes", "BarstoolSports",
                     "OldTakesExposed", "SportsMemes", "TimelessSports"],
    "reply_stats": ["statmuse", "OptaSTATS", "ESPNStatsInfo", "ClutchPoints", "HoopCentral",
                    "TheNBACentral", "DovKleiman"],
    "follow_candidates": ["SharpFootball", "PFF", "FantasyLife", "UnderdogNFL", "SleeperHQ",
                          "FieldYates", "minakimes", "TheCheckdown", "Nate_Tice"],
    "niche": ["NHL", "ESPNFC", "F1", "ATPTour", "OptaJoe", "TSN_Sports", "Sportsnet"],
    "competitors": ["immaculategrid", "Sporcle", "SleeperHQ", "UnderdogFantasy", "PuzzGrid"],
}
ACCOUNTS = tuple(dict.fromkeys(
    CURATED["reply_news"] + CURATED["reply_banter"] + CURATED["reply_stats"]))

VOICE = ("first person, confident, lowercase-leaning, <=140 chars, no hashtags, no links; "
         "add one true thing or ask one sharp question; never an ad")


def _auth():
    """Prefer OAuth1 (non-rotating, and present in CI via Supabase); fall back to the app-only
    bearer from the local file for laptop use."""
    creds = x_engine.oauth1_creds()          # KV-aware: works in CI, not just from .env
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


def _uid(acct: str, auth) -> str:
    key = f"uid:{acct}"
    cached = x_cache.get(key, UID_TTL)
    if cached:
        return cached
    uid = _get(f"/users/by/username/{urllib.parse.quote(acct)}", auth)["data"]["id"]
    x_cache.put(key, uid)
    return uid


def fetch_candidates(*, minutes: int = 30, accounts=ACCOUNTS, auth=None,
                     max_results: int = 5, max_reads: int = DEFAULT_MAX_READS) -> list[dict]:
    """Recent original posts from the watchlist, still young enough to reply into. Cached and
    budgeted: X bills per post read, so an unbounded poll is an unbounded bill."""
    auth = auth or _auth()
    now = dt.datetime.now(dt.timezone.utc)
    out: list[dict] = []
    reads = 0
    for acct in accounts:
        if reads >= max_reads:
            print(f"[replies] read budget ({max_reads}) reached; stopping. X bills per post read.")
            break
        try:
            uid = _uid(acct, auth)
        except (urllib.error.HTTPError, KeyError):
            continue
        key = f"tl:{uid}:{max_results}"
        data = x_cache.get(key, TIMELINE_TTL)
        if data is None:
            try:
                data = _get(f"/users/{uid}/tweets?max_results={max_results}"
                            f"&exclude=retweets,replies&tweet.fields=created_at,public_metrics", auth)
            except (urllib.error.HTTPError, KeyError):
                continue
            x_cache.put(key, data)
        for tw in data.get("data", []):
            reads += 1
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


def brief(c: dict, drafts: dict[str, str] | None = None) -> str:
    """A writing brief: the target, its numbers, and (with --draft) one reply per archetype."""
    lines = [f'@ {c["acct"]}  ·  {c["age"]}m old  ·  {c["likes"]} likes / {c["replies"]} replies  '
             f'·  opportunity {c["opportunity"]}',
             f'   post : {c["text"].strip()[:280]}',
             f'   why  : reach per sibling × freshness (reply is weight '
             f'{x_algo.WEIGHTS["reply"]}; +{x_algo.WEIGHTS["reply_mutual_original_boost"]} if mutual)']
    if drafts:
        for aid, text in drafts.items():
            lines.append(f'   [{aid}] {text}')
        lines.append(f'   post : x_replies --post-id {c["id"]} --text "..."')
    else:
        lines.append(f'   voice: {VOICE}')
        lines.append(f'   post : x_replies --post-id {c["id"]} --text "..."')
    return "\n".join(lines)


def post_reply(tweet_id: str, text: str) -> str:
    """Reply with the OAuth1 user token; recorded in the ledger so a re-run cannot double-post."""
    creds = x_engine.oauth1_creds()
    if not creds:
        raise SystemExit("[replies] OAuth1 credentials required")
    tid = x_oauth1.post_tweet(text, creds, reply_to=tweet_id)
    x_engine.ledger_record(f"reply:{tweet_id}", tid, dt.date.today().isoformat(), "reply", "")
    return tid


def follow_accounts(accounts, *, limit: int, dry_run: bool) -> int:
    """Follow a curated category, capped and ledger-deduped. Small by design: mass following is an
    inauthentic-behaviour signal, and X caps new accounts near 400 follows/day anyway."""
    creds = x_engine.oauth1_creds()
    auth = _auth()
    followed = 0
    for acct in accounts:
        if followed >= limit:
            break
        try:
            uid = _get(f"/users/by/username/{urllib.parse.quote(acct)}", auth)["data"]["id"]
        except Exception:  # noqa: BLE001 — a bad handle is skipped, not fatal
            print(f"  {acct}: could not resolve")
            continue
        if uid == ME:
            continue
        key = f"follow:{uid}"
        if x_engine.ledger_has(key):
            continue
        if dry_run:
            print(f"  would follow @{acct} ({uid})")
            followed += 1
            continue
        if not creds:
            raise SystemExit("[replies] OAuth1 credentials required to follow")
        try:
            x_oauth1.follow(ME, uid, creds)
            x_engine.ledger_record(key, "", dt.date.today().isoformat(), "follow", acct)
            print(f"  followed @{acct}")
        except RuntimeError as e:
            x_engine.ledger_record(key, "", dt.date.today().isoformat(), "follow", acct)
            print(f"  {acct}: {e}")
        followed += 1
    return followed


def main() -> int:
    ap = argparse.ArgumentParser(description="Reply targeting / drafting for X.")
    ap.add_argument("--minutes", type=int, default=30, help="only posts younger than this")
    ap.add_argument("--cap", type=int, default=5)
    ap.add_argument("--accounts", default=None, help="comma list; default the watchlist")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--draft", action="store_true", help="write a reply with the LLM voice")
    ap.add_argument("--post-id", default=None, help="reply to this tweet id")
    ap.add_argument("--text", default=None, help="the reply text (with --post-id)")
    ap.add_argument("--list-accounts", action="store_true", help="print the curated lists")
    ap.add_argument("--follow", action="store_true", help="follow a curated category via API")
    ap.add_argument("--follow-category", default="follow_candidates", choices=sorted(CURATED))
    ap.add_argument("--follow-limit", type=int, default=5)
    ap.add_argument("--dry-run", action="store_true", help="preview --follow without acting")
    ap.add_argument("--max-reads", type=int, default=DEFAULT_MAX_READS,
                    help="hard stop after N posts read (X bills per read)")
    ap.add_argument("--max-results", type=int, default=5, help="posts per account per read")
    args = ap.parse_args()

    if args.list_accounts:
        for category, accounts in CURATED.items():
            print(f"{category}: {', '.join(accounts)}")
        return 0
    if args.follow:
        n = follow_accounts(CURATED.get(args.follow_category, []),
                            limit=args.follow_limit, dry_run=args.dry_run)
        print(f"[replies] {n} follow(s) {'would be ' if args.dry_run else ''}made")
        return 0

    if args.post_id:
        if not args.text:
            raise SystemExit("--post-id needs --text")
        if x_algo.is_risky(args.text):
            raise SystemExit("refusing: reply text looks risky")
        print("posted:", post_reply(args.post_id, args.text))
        return 0

    accounts = tuple(a.strip() for a in args.accounts.split(",")) if args.accounts else ACCOUNTS
    ranked = rank(fetch_candidates(minutes=args.minutes, accounts=accounts,
                                   max_results=args.max_results,
                                   max_reads=args.max_reads))[:args.cap]
    if args.json:
        print(json.dumps(ranked, indent=1))
        return 0
    if not ranked:
        print(f"[replies] no non-risky posts under {args.minutes}m in the watchlist right now")
        return 0
    print(f"# Reply targets ({len(ranked)})\n")
    for c in ranked:
        drafts = x_voice.draft_variants(c["text"]) if args.draft else None
        print(brief(c, drafts), "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
