#!/usr/bin/env python3
"""The automated growth engine: post Playbook's daily content to X with no human in the loop.

Read `prompts/HANDOFF-growth-agent.md` and `docs/BALLIQ_SPEC.md` §9.3 for the why. This is the
"post the daily board every day, automatically — build it as a scheduled workflow, not a manual
habit" half of that brief. The assets it posts are the ones `x_assets.py` already mints from what
the daily mint just published; this module is only the posting half.

What it posts, and why only some kinds
--------------------------------------
The board threads (`keep4`, `resume`, `career`) are **image** posts: the stat lines a player
answers from live only in the rendered PNG, so the caption alone ("Player A or Player B?") is
unanswerable. `whoami` is the exception — it is designed as a text thread, one clue per reply.

So the engine posts `whoami` by default and refuses to post a board kind unless it can actually
attach the image. Attaching needs the `media.write` OAuth2 scope, which the current grant does
not carry: `POST /2/media/upload` returns **403 Forbidden** (verified 2026-09-21). Once that
scope is added and the token is re-consented, pass `--media` and the board posts come online with
no code change — the upload path is already here.

Why the credentials live in Supabase
------------------------------------
X rotates the OAuth2 refresh token on every use, and a GitHub Actions runner cannot persist a
modified secret (and this environment has no management token to set one). The refresh token
therefore lives in `public.marketing_secrets` (service-role only), which the engine both reads
and rewrites each run. `X_CLIENT_ID`/`X_CLIENT_SECRET` are seeded there too, so the workflow
needs no X secret at all — only `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY`, which already exist.

Idempotency
-----------
Every tweet the engine sends has a stable key (`{date}:{kind}:{sport}:main`, `:reply:{n}`,
`:reveal`) recorded in `public.marketing_posts`. A cron that fires twice, or a dispatch for a
date already posted, is a no-op rather than a duplicate post.

Usage
-----
    python -m tools.marketing.x_engine --seed              # one-time: seed secrets from .env
    python -m tools.marketing.x_engine --dry-run           # show today's posts, send nothing
    python -m tools.marketing.x_engine                     # post today's whoami threads
    python -m tools.marketing.x_engine --media             # also post board threads (needs scope)
    python -m tools.marketing.x_engine --reveals --date 2026-09-20
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import urllib.error
import urllib.parse
import urllib.request

from . import x_assets, x_client
from tools.ingest import validate as _validate
from tools.ingest.assemble import PuzzleRow
from tools.ingest.pack import MIN_PHOTOS

DEFAULT_CAP = 2

# A whoami thread posts the caption's clue plus this many replies, then stops. The clue ladder is
# six deep and its tail is a giveaway ("Peaked in 1999 with the Browns: 107 tackles" names the
# answer to anyone who knows the team-year), so a timeline post must not dump all six — the app
# is where you spend for clue 6. Three clues is a teaser people can actually reply to.
WHOAMI_REPLY_CAP = 2

# Which asset kinds carry their answer in the image (media required) versus in the text.
MEDIA_KINDS = ("keep4", "resume", "career")
TEXT_KINDS = ("whoami",)

TOKEN_URL = "https://api.twitter.com/2/oauth2/token"
API_BASE = "https://api.x.com/2"


# ── Supabase (service-role; the rotating-value store) ────────────────────────────

def _rest(method: str, path: str, *, data: dict | None = None,
          extra: dict | None = None):
    base, key = x_assets._env()
    headers = {"apikey": key, "Authorization": f"Bearer {key}",
               "Content-Type": "application/json", **(extra or {})}
    req = urllib.request.Request(
        f"{base}/rest/v1/{path}",
        data=json.dumps(data).encode() if data is not None else None,
        method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
            return json.loads(body) if body.strip() else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {path} -> {e.code} {e.read().decode()[:300]}") from e


def kv_get(key: str) -> str | None:
    rows = _rest("GET", f"marketing_secrets?select=value&key=eq.{urllib.parse.quote(key)}")
    return rows[0]["value"] if rows else None


def kv_set(key: str, value: str) -> None:
    _rest("POST", "marketing_secrets?on_conflict=key",
          data={"key": key, "value": value,
                "updated_at": dt.datetime.now(dt.timezone.utc).isoformat()},
          extra={"Prefer": "resolution=merge-duplicates,return=minimal"})


def ledger_get(post_id: str) -> str | None:
    rows = _rest("GET", f"marketing_posts?select=tweet_id&id=eq.{urllib.parse.quote(post_id)}"
                        f"&limit=1")
    return rows[0]["tweet_id"] if rows else None


def ledger_has(post_id: str) -> bool:
    return ledger_get(post_id) is not None


def ledger_record(post_id: str, tweet_id: str, date: str, kind: str, sport: str) -> None:
    _rest("POST", "marketing_posts?on_conflict=id",
          data={"id": post_id, "tweet_id": tweet_id, "date": date, "kind": kind, "sport": sport},
          extra={"Prefer": "resolution=merge-duplicates,return=minimal"})


# ── credentials ─────────────────────────────────────────────────────────────────

def _file_env() -> dict:
    try:
        return x_client.load_env()
    except FileNotFoundError:
        return {}


def seed() -> None:
    """One-time bootstrap: copy the static client id/secret and the current refresh token from
    `tools/marketing/.env` into Supabase, so a runner that has only the Supabase secret can post."""
    env = _file_env()
    pairs = [("X_CLIENT_ID", "x_client_id"), ("X_CLIENT_SECRET", "x_client_secret"),
             ("X_REFRESH_TOKEN", "x_refresh_token"), *_OAUTH1_KV.items(),
             ("OPENAI_API_KEY", "openai_api_key"), ("OPENAI_MODEL", "openai_model")]
    for env_key, kv_key in pairs:
        value = env.get(env_key)
        if value:
            kv_set(kv_key, value)
            print(f"[growth] seeded {kv_key}")
        else:
            print(f"[growth] {env_key} not in .env; skipped")


def client_creds() -> tuple[str, str]:
    env = _file_env()
    cid = os.getenv("X_CLIENT_ID") or kv_get("x_client_id") or env.get("X_CLIENT_ID")
    secret = os.getenv("X_CLIENT_SECRET") or kv_get("x_client_secret") or env.get("X_CLIENT_SECRET")
    if not (cid and secret):
        raise SystemExit("[growth] X client credentials missing — run `--seed` or set X_CLIENT_ID/"
                         "X_CLIENT_SECRET")
    return cid, secret


def refresh_token_value() -> str:
    token = kv_get("x_refresh_token")
    if token:
        return token
    token = os.getenv("X_REFRESH_TOKEN") or _file_env().get("X_REFRESH_TOKEN")
    if not token:
        raise SystemExit("[growth] no X refresh token — run `--seed` from a machine with .env")
    kv_set("x_refresh_token", token)      # bootstrap a first-time store
    return token


def access_token() -> str:
    """Exchange the stored refresh token for an access token, persisting the NEW refresh token
    (rotation means the old one is dead the moment this succeeds)."""
    cid, secret = client_creds()
    basic = base64.b64encode(f"{cid}:{secret}".encode()).decode()
    body = urllib.parse.urlencode({"grant_type": "refresh_token",
                                   "refresh_token": refresh_token_value(),
                                   "client_id": cid}).encode()
    req = urllib.request.Request(TOKEN_URL, data=body, method="POST",
                                 headers={"Authorization": f"Basic {basic}",
                                          "Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"token refresh failed: {e.code} {e.read().decode()[:300]}") from e
    if data.get("refresh_token"):
        kv_set("x_refresh_token", data["refresh_token"])
    return data["access_token"]


# ── X API ────────────────────────────────────────────────────────────────────────

def _tweet(access: str | None, text: str, *, reply_to: str | None = None,
           media_ids: list[str] | None = None, oauth1: dict | None = None) -> str:
    if oauth1:
        from . import x_oauth1
        return x_oauth1.post_tweet(text, oauth1, reply_to=reply_to, media_ids=media_ids)
    payload: dict = {"text": text}
    if reply_to:
        payload["reply"] = {"in_reply_to_tweet_id": reply_to}
    if media_ids:
        payload["media"] = {"media_ids": media_ids}
    req = urllib.request.Request(API_BASE + "/tweets", data=json.dumps(payload).encode(),
                                 method="POST",
                                 headers={"Authorization": f"Bearer {access}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())["data"]["id"]
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"post failed: {e.code} {e.read().decode()[:300]}") from e


_OAUTH1_KV = {"X_CONSUMER_KEY": "x_consumer_key",
              "X_CONSUMER_SECRET": "x_consumer_secret",
              "X_OAUTH1_ACCESS_TOKEN": "x_oauth1_access_token",
              "X_OAUTH1_ACCESS_TOKEN_SECRET": "x_oauth1_access_token_secret"}


def oauth1_creds() -> dict | None:
    """The four OAuth 1.0a values from the process env, `tools/marketing/.env`, or Supabase — in
    that order — or None when the account's Access Token pair has not been provided yet."""
    env = {**_file_env(), **os.environ}
    out = {k: env.get(k) or kv_get(kv) for k, kv in _OAUTH1_KV.items()}
    return out if all(out.values()) else None


def upload_media(access: str, png: bytes) -> str | None:
    """Attach an image, preferring the OAuth 1.0a v1.1 endpoint (non-rotating app + access tokens)
    and falling back to the OAuth2 v2 endpoint. Returns None when neither grant can upload — the
    caller then skips the board rather than posting an unanswerable caption."""
    from . import x_oauth1
    creds = oauth1_creds()
    if creds:
        media_id = x_oauth1.upload_media(png, creds)
        if media_id:
            return media_id
    boundary = "----playbook" + base64.urlsafe_b64encode(os.urandom(9)).decode().rstrip("=")
    body = (f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="media"; filename="board.png"\r\n'
            f"Content-Type: image/png\r\n\r\n").encode() + png + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(API_BASE + "/media/upload", data=body, method="POST",
                                 headers={"Authorization": f"Bearer {access}",
                                          "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read())["data"]["id"]
    except urllib.error.HTTPError as e:
        print(f"[growth] media upload unavailable ({e.code}); board posts skipped "
              f"(add the media.write scope and re-consent, then pass --media)")
        return None


def download(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url), timeout=120) as r:
        return r.read()


# ── selection (pure) ─────────────────────────────────────────────────────────────

def bucket_url(date: str, filename: str) -> str:
    base, _ = x_assets._env()
    return f"{base}/storage/v1/object/public/{x_assets.BUCKET}/x/{date}/{filename}"


def post_id(date: str, kind: str, sport: str, slot: str) -> str:
    return f"{date}:{kind}:{sport}:{slot}"


def select_assets(assets: list[dict], *, cap: int, sports: set[str] | None,
                  kinds: tuple[str, ...]) -> list[dict]:
    """The assets to post, in `x_assets`' own order (sport-major), filtered and capped so a
    seven-sport daily is not seven threads from an account nobody follows yet."""
    chosen = []
    for a in assets:
        if a.get("kind") not in kinds:
            continue
        if sports and a.get("sport") not in sports:
            continue
        if not (a.get("caption") or "").strip():
            continue
        chosen.append(a)
        if len(chosen) >= cap:
            break
    return chosen


# ── trust (what may be posted) ───────────────────────────────────────────────────
#
# The engine posts unattended, so "is this asset good enough to publish under the brand" has to
# be a check, not a judgement made each morning. It is deliberately the SAME bar the content
# pipeline already holds boards to — `validate.validate()` (shape, ambiguous keep/cut boundary,
# headshots frozen from our store, a clue that does not leak the answer) plus `pack.MIN_PHOTOS`
# (six of eight real faces) — rather than a second, weaker gate that would drift from the first.

def fetch_rows(puzzle_ids: list[str]) -> dict[str, dict]:
    """The live `puzzles` rows for these ids, keyed by id (PostgREST `in.()`)."""
    ids = [i for i in puzzle_ids if i]
    if not ids:
        return {}
    query = "puzzles?select=id,sport,format,content&id=" + urllib.parse.quote(x_assets._in(ids))
    rows = _rest("GET", query)
    return {r["id"]: r for r in rows}


def _faces(content: dict) -> int:
    return sum(1 for p in content.get("players", []) if p.get("headshot"))


def trust_reason(asset: dict, row: dict | None) -> str | None:
    """None when the asset is safe to post, else a short reason it is not. Pure given its row."""
    if row is None:
        return "no live row for this board"
    if row.get("sport") not in _validate.WIRE_SAFE_SPORTS:
        return f"unreleased sport {row.get('sport')!r}"
    try:
        _validate.validate(PuzzleRow(id=row["id"], sport=row["sport"],
                                     format=row.get("format", asset.get("kind", "")),
                                     content=row["content"]))
    except ValueError as e:
        return f"failed validation: {e}"
    if row.get("format") == "keep4":
        faces = _faces(row["content"])
        if faces < MIN_PHOTOS:
            return f"only {faces} real faces (need {MIN_PHOTOS})"
    return None


def image_ready(url: str) -> bool:
    """The rendered PNG actually exists in the bucket — never attach a 404 to a post."""
    try:
        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status == 200 and int(r.headers.get("Content-Length", "0")) > 1_000
    except Exception:  # noqa: BLE001 — any failure means "not ready"
        return False


# ── posting ──────────────────────────────────────────────────────────────────────

def post_assets(assets: list[dict], access: str | None, *, date: str, cap: int,
                sports: set[str] | None, kinds: tuple[str, ...], use_media: bool,
                dry_run: bool, force: bool, rows: dict[str, dict],
                oauth1: dict | None = None) -> int:
    posted = 0
    for a in select_assets(assets, cap=cap, sports=sports, kinds=kinds):
        main = post_id(date, a["kind"], a["sport"], "main")
        if not force and not dry_run and ledger_has(main):
            print(f"[growth] skip {main} (already posted)")
            continue

        reason = trust_reason(a, rows.get(a.get("puzzle_id")))
        if reason:
            print(f"[growth] skip {main}: {reason}")
            continue

        needs_media = a["kind"] in MEDIA_KINDS
        if needs_media and not use_media:
            continue                                       # only reachable if caller overrode kinds
        if needs_media and not a.get("file"):
            continue
        image_url = a.get("url") or (bucket_url(date, a["file"]) if a.get("file") else "")
        if needs_media and not image_ready(image_url):
            print(f"[growth] skip {main}: rendered image is not in the bucket yet")
            continue

        replies = list(a.get("replies") or ())
        if a["kind"] == "whoami":
            replies = replies[:WHOAMI_REPLY_CAP]

        if dry_run:
            kind = "with image" if needs_media else "text only"
            lines = [f"[growth] DRY RUN {main}  ·  {kind}  ·  {a['sport']}"]
            if needs_media:
                lines.append(f"    image : {image_url}")
            lines.append("    post  : " + a["caption"].replace("\n", "\n            "))
            for i, rep in enumerate(replies, 1):
                lines.append(f"    reply {i}: {rep}")
            reveal = (a.get("reveal") or {}).get("text")
            if reveal:
                when = (a.get("reveal") or {}).get("when", "later")
                lines.append(f"    reveal ({when}): {reveal.replace(chr(10), ' / ')}")
            print("\n".join(lines) + "\n")
            posted += 1
            continue

        media_ids = None
        if needs_media:
            media_id = upload_media(access, download(image_url))
            if not media_id:
                continue                                   # never post a board without its image
            media_ids = [media_id]

        tid = _tweet(access, a["caption"], media_ids=media_ids, oauth1=oauth1)
        ledger_record(main, tid, date, a["kind"], a["sport"])
        parent = tid
        for i, reply in enumerate(replies, 1):
            slot = post_id(date, a["kind"], a["sport"], f"reply:{i}")
            if not force and ledger_has(slot):
                parent = ledger_get(slot) or parent
                continue
            parent = _tweet(access, reply, reply_to=parent, oauth1=oauth1)
            ledger_record(slot, parent, date, a["kind"], a["sport"])
        print(f"[growth] posted {main} -> {tid}")
        posted += 1
    return posted


def post_reveals(assets: list[dict], access: str | None, *, date: str, sports: set[str] | None,
                 kinds: tuple[str, ...], dry_run: bool, force: bool,
                 oauth1: dict | None = None) -> int:
    """Reply each board's answer to the main tweet it belongs to, the next day. A no-op for any
    main the ledger has never seen (so this is safe to schedule before the poster has run)."""
    posted = 0
    for a in assets:
        if kinds and a["kind"] not in kinds:
            continue
        if sports and a.get("sport") not in sports:
            continue
        reveal = (a.get("reveal") or {}).get("text")
        if not reveal:
            continue
        main = post_id(date, a["kind"], a["sport"], "main")
        slot = post_id(date, a["kind"], a["sport"], "reveal")
        if not force and not dry_run and ledger_has(slot):
            continue
        if dry_run:
            print(f"[growth] DRY RUN {slot}:\n{reveal}\n")
            posted += 1
            continue
        parent = ledger_get(main)
        if not parent:
            continue
        tid = _tweet(access, reveal, reply_to=parent, oauth1=oauth1)
        ledger_record(slot, tid, date, a["kind"], a["sport"])
        print(f"[growth] revealed {slot} -> {tid}")
        posted += 1
    return posted


# ── OAuth 1.0a login (mint the account's non-rotating token pair) ─────────────────
#
# Preferred over the rotating OAuth2 refresh token for exactly the reason the Supabase store
# exists: these tokens do not expire or rotate, so a scheduled run cannot lose the account by
# missing a persist step, and the same pair posts AND uploads media (v1.1).

REQUEST_TOKEN_FILE = x_assets.brand.ROOT / "build" / "x-oauth1-request.json"


def oauth1_begin() -> str:
    """Request a token and return the URL the account owner approves."""
    from . import x_oauth1
    env = _file_env()
    rt = x_oauth1.request_token(env["X_CONSUMER_KEY"], env["X_CONSUMER_SECRET"])
    REQUEST_TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    REQUEST_TOKEN_FILE.write_text(json.dumps(rt))
    return x_oauth1.authorize_url(rt["oauth_token"])


def oauth1_login(pin: str) -> int:
    from . import x_oauth1
    env = _file_env()
    rt = json.loads(REQUEST_TOKEN_FILE.read_text())
    out = x_oauth1.exchange_access_token(env["X_CONSUMER_KEY"], env["X_CONSUMER_SECRET"],
                                         rt["oauth_token"], rt["oauth_token_secret"], pin)
    env["X_OAUTH1_ACCESS_TOKEN"] = out["oauth_token"]
    env["X_OAUTH1_ACCESS_TOKEN_SECRET"] = out["oauth_token_secret"]
    x_client.save_env(env)
    seed()
    print(f"[growth] OAuth1 access token for @{out.get('screen_name', '?')} stored")
    return 0


# ── CLI ──────────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--date", default=None, help="YYYY-MM-DD (default: today, UTC)")
    ap.add_argument("--cap", type=int, default=DEFAULT_CAP, help="max threads per run")
    ap.add_argument("--sport", default=None, help="comma list; default every sport")
    ap.add_argument("--kind", default=None, help="comma list; default whoami, or all with --media")
    ap.add_argument("--media", action="store_true", help="also post board kinds (needs media.write)")
    ap.add_argument("--reveals", action="store_true", help="post reveals for --date instead")
    ap.add_argument("--dry-run", action="store_true", help="print what would post; send nothing")
    ap.add_argument("--force", action="store_true", help="repost even if the ledger has it")
    ap.add_argument("--seed", action="store_true", help="seed Supabase secrets from marketing/.env")
    ap.add_argument("--oauth1-pin", metavar="PIN", default=None,
                    help="exchange the 3-legged verifier for the account's OAuth1 access token")
    ap.add_argument("--oauth1-begin", action="store_true", help="start OAuth1 login; prints the URL")
    args = ap.parse_args()

    if args.seed:
        seed()
        return 0

    if args.oauth1_begin:
        print("[growth] approve at:", oauth1_begin())
        return 0

    if args.oauth1_pin:
        return oauth1_login(args.oauth1_pin)

    date = args.date or dt.date.today().isoformat()
    sports = {s for s in (args.sport.split(",") if args.sport else []) if s} or None
    if args.kind:
        kinds = tuple(k.strip() for k in args.kind.split(",") if k.strip())
    else:
        kinds = MEDIA_KINDS + TEXT_KINDS if args.media else TEXT_KINDS

    assets = x_assets.collect(daily=date, packs=None, sport=sorted(sports) if sports else None)
    for a in assets:                                        # board posts fetch the rendered PNG
        if a.get("file"):
            a["url"] = bucket_url(date, a["file"])
    rows = fetch_rows([a.get("puzzle_id") for a in assets])  # the trust gate's source of truth

    # Prefer the OAuth 1.0a user context: non-rotating, and the same pair also uploads media.
    # Only fall back to the rotating OAuth2 token when it is absent, and never fetch it for a
    # dry run (a dry run must not rotate anything).
    oauth1 = oauth1_creds()
    access = None if (args.dry_run or oauth1) else access_token()

    if args.reveals:
        n = post_reveals(assets, access, date=date, sports=sports, kinds=kinds,
                         dry_run=args.dry_run, force=args.force, oauth1=oauth1)
    else:
        n = post_assets(assets, access, date=date, cap=args.cap, sports=sports, kinds=kinds,
                        use_media=args.media, dry_run=args.dry_run, force=args.force, rows=rows,
                        oauth1=oauth1)
    print(f"[growth] {n} post(s) {'would be ' if args.dry_run else ''}made for {date}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
