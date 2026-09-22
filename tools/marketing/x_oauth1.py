"""Minimal OAuth 1.0a request signing (HMAC-SHA1) for the X v1.1 media upload endpoint.

Why this exists: `POST /2/media/upload` documents "OAuth 1.0a User Context, OAuth 2.0 User
Context" as its accepted auth, and the OAuth2 grant in use does not carry `media.write` (it
returns 403), while the app-only Bearer is refused outright ("OAuth 2.0 Application-Only is
forbidden for this endpoint"). The OAuth 1.0a route uses the app's Consumer Key/Secret plus the
account's Access Token/Secret — neither rotates, so unlike the OAuth2 refresh token it needs no
server-side store.

`sign()` is the whole algorithm and is unit-tested against the worked example in X's own OAuth 1.0a
signing documentation (see test_x_oauth1.py), so a change that breaks the base string fails there
rather than as an opaque 401.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request
import uuid


def _enc(value: str) -> str:
    """RFC 3986 percent-encoding as OAuth 1.0a defines it: unreserved = A-Za-z0-9-._~."""
    return urllib.parse.quote(str(value), safe="-._~")


def signature_base_string(method: str, url: str, params: dict[str, str]) -> str:
    parts = urllib.parse.urlsplit(url)
    base_url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, "", ""))
    encoded = "&".join(f"{_enc(k)}={_enc(v)}" for k, v in sorted(params.items()))
    return "&".join([method.upper(), _enc(base_url), _enc(encoded)])


def sign(method: str, url: str, params: dict[str, str],
         consumer_secret: str, token_secret: str) -> str:
    base = signature_base_string(method, url, params)
    key = f"{_enc(consumer_secret)}&{_enc(token_secret)}"
    digest = hmac.new(key.encode(), base.encode(), hashlib.sha1).digest()
    return base64.b64encode(digest).decode()


def auth_header(method: str, url: str, consumer_key: str, consumer_secret: str,
                token: str, token_secret: str, *, nonce: str | None = None,
                timestamp: str | None = None, extra: dict[str, str] | None = None) -> str:
    """Build the `Authorization: OAuth …` header. `token`/`token_secret` are empty for the
    two-legged `oauth/request_token` call; `extra` adds params that must be signed (e.g.
    `oauth_callback`) and is included in the header, which X accepts for those."""
    oauth = {
        "oauth_consumer_key": consumer_key,
        "oauth_nonce": nonce or uuid.uuid4().hex,
        "oauth_signature_method": "HMAC-SHA1",
        "oauth_timestamp": timestamp or str(int(time.time())),
        "oauth_version": "1.0",
    }
    if token:
        oauth["oauth_token"] = token
    oauth.update(extra or {})
    oauth["oauth_signature"] = sign(method, url, oauth, consumer_secret, token_secret)
    return "OAuth " + ", ".join(f'{_enc(k)}="{_enc(v)}"' for k, v in sorted(oauth.items()))


# ── live path ────────────────────────────────────────────────────────────────────

UPLOAD_URL = "https://upload.twitter.com/1.1/media/upload.json"
TWEET_URL = "https://api.x.com/2/tweets"


def credentials() -> dict | None:
    """The four OAuth 1.0a values, from the process env or `tools/marketing/.env`. None when the
    account's Access Token pair has not been supplied yet — the consumer pair alone cannot upload
    (media needs user context)."""
    from . import x_client
    env = {**x_client.load_env(), **os.environ}
    have = ("X_CONSUMER_KEY", "X_CONSUMER_SECRET",
            "X_OAUTH1_ACCESS_TOKEN", "X_OAUTH1_ACCESS_TOKEN_SECRET")
    if all(env.get(k) for k in have):
        return {k: env[k] for k in have}
    return None


# ── 3-legged flow (to mint the account's Access Token/Secret) ─────────────────────

def _post_form(url: str, data: dict, header: str) -> dict:
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), method="POST",
                                 headers={"Authorization": header,
                                          "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return dict(urllib.parse.parse_qsl(r.read().decode()))


def request_token(consumer_key: str, consumer_secret: str, callback: str = "oob") -> dict:
    url = "https://api.twitter.com/oauth/request_token"
    header = auth_header("POST", url, consumer_key, consumer_secret, "", "",
                         extra={"oauth_callback": callback})
    return _post_form(url, {}, header)


def authorize_url(token: str) -> str:
    return f"https://api.twitter.com/oauth/authenticate?oauth_token={_enc(token)}"


def exchange_access_token(consumer_key: str, consumer_secret: str, request_token_value: str,
                          request_token_secret: str, verifier: str) -> dict:
    url = "https://api.twitter.com/oauth/access_token"
    header = auth_header("POST", url, consumer_key, consumer_secret, request_token_value,
                         request_token_secret, extra={"oauth_verifier": verifier})
    return _post_form(url, {}, header)


def post_tweet(text: str, creds: dict, *, reply_to: str | None = None,
               media_ids: list[str] | None = None) -> str:
    """Create a post with OAuth 1.0a user context. The JSON body is NOT part of the signature
    (only form-encoded bodies are), so only the oauth_* params are signed."""
    payload: dict = {"text": text}
    if reply_to:
        payload["reply"] = {"in_reply_to_tweet_id": reply_to}
    if media_ids:
        payload["media"] = {"media_ids": media_ids}
    header = auth_header("POST", TWEET_URL, creds["X_CONSUMER_KEY"], creds["X_CONSUMER_SECRET"],
                         creds["X_OAUTH1_ACCESS_TOKEN"], creds["X_OAUTH1_ACCESS_TOKEN_SECRET"])
    req = urllib.request.Request(TWEET_URL, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Authorization": header, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["data"]["id"]


def upload_media(png: bytes, creds: dict | None = None) -> str | None:
    """Upload via v1.1 with OAuth 1.0a user context. Returns the media id, or None if the
    credentials are incomplete or X refuses."""
    creds = creds or credentials()
    if not creds:
        return None
    boundary = "----playbook" + uuid.uuid4().hex
    body = (f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="media"; filename="board.png"\r\n'
            f"Content-Type: image/png\r\n\r\n").encode() + png + f"\r\n--{boundary}--\r\n".encode()
    header = auth_header("POST", UPLOAD_URL, creds["X_CONSUMER_KEY"], creds["X_CONSUMER_SECRET"],
                         creds["X_OAUTH1_ACCESS_TOKEN"], creds["X_OAUTH1_ACCESS_TOKEN_SECRET"])
    req = urllib.request.Request(UPLOAD_URL, data=body, method="POST",
                                 headers={"Authorization": header,
                                          "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        import json
        with urllib.request.urlopen(req, timeout=120) as r:
            return str(json.loads(r.read())["media_id"])
    except Exception as e:  # noqa: BLE001 — caller falls back / skips
        print(f"[growth] OAuth1 media upload failed: {e}")
        return None
