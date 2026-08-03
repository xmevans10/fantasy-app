#!/usr/bin/env python3
"""Minimal X (Twitter) API v2 helper: OAuth2 refresh + post + identity check.

X rotates the refresh token on every use — a successful refresh invalidates the old
refresh token immediately, so this always rewrites .env with the new access/refresh
pair. Never call the token endpoint without persisting the result, or the next run
fails against an already-consumed token.
"""
import json
import sys
import base64
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path

ENV_PATH = Path(__file__).parent / ".env"
TOKEN_URL = "https://api.twitter.com/2/oauth2/token"
API_BASE = "https://api.twitter.com/2"


def load_env() -> dict:
    env = {}
    for line in ENV_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
    return env


def save_env(env: dict) -> None:
    lines = ENV_PATH.read_text().splitlines()
    out = []
    seen = set()
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            k = stripped.split("=", 1)[0].strip()
            if k in env:
                out.append(f"{k}={env[k]}")
                seen.add(k)
                continue
        out.append(line)
    for k, v in env.items():
        if k not in seen:
            out.append(f"{k}={v}")
    ENV_PATH.write_text("\n".join(out) + "\n")


def refresh_access_token(env: dict) -> dict:
    """Exchange the current refresh token for a fresh access/refresh pair, persist
    the result immediately (rotation means the old refresh token is now dead), and
    return the updated env dict."""
    basic = base64.b64encode(
        f"{env['X_CLIENT_ID']}:{env['X_CLIENT_SECRET']}".encode()
    ).decode()
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": env["X_REFRESH_TOKEN"],
        "client_id": env["X_CLIENT_ID"],
    }).encode()
    req = urllib.request.Request(
        TOKEN_URL, data=body, method="POST",
        headers={
            "Authorization": f"Basic {basic}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"token refresh failed: {e.code} {e.read().decode()}") from e

    env["X_ACCESS_TOKEN"] = data["access_token"]
    if "refresh_token" in data:
        env["X_REFRESH_TOKEN"] = data["refresh_token"]
    save_env(env)
    return env


def api_call(env: dict, method: str, path: str, body: dict | None = None):
    req = urllib.request.Request(
        API_BASE + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={
            "Authorization": f"Bearer {env['X_ACCESS_TOKEN']}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def whoami(env: dict):
    return api_call(env, "GET", "/users/me")


def post_tweet(env: dict, text: str):
    return api_call(env, "POST", "/tweets", {"text": text})


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "whoami"
    e = load_env()
    e = refresh_access_token(e)
    if cmd == "whoami":
        status, out = whoami(e)
        print(status)
        print(json.dumps(out, indent=1))
    elif cmd == "post":
        text = sys.argv[2]
        status, out = post_tweet(e, text)
        print(status)
        print(json.dumps(out, indent=1))
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
