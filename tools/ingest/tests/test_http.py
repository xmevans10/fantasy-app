"""HTTP retry behavior — the balldontlie pipeline 429s without backoff otherwise.

Regression guard for the NBA-isn't-live bug: a 429 must be retried (it's the one
4xx that resolves on its own), while other 4xx must still fail fast.
"""
import io
import urllib.error

from tools.ingest.providers import http


class _Resp:
    """Minimal stand-in for an HTTP response usable as a context manager."""
    def __init__(self, body: bytes):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _http_error(code: int, retry_after: str | None = None) -> urllib.error.HTTPError:
    headers = {"Retry-After": retry_after} if retry_after is not None else {}
    return urllib.error.HTTPError("http://x", code, "err", headers, io.BytesIO(b""))


def test_get_retries_on_429_then_succeeds(monkeypatch):
    calls = []

    def fake_urlopen(req, timeout=60):
        calls.append(1)
        if len(calls) < 3:
            raise _http_error(429, retry_after="0")  # rate limited twice
        return _Resp(b"OK")

    monkeypatch.setattr(http.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(http.time, "sleep", lambda *_: None)  # don't actually wait

    assert http._get("http://x") == "OK"
    assert len(calls) == 3  # two 429s, then success — it backed off instead of giving up


def test_get_fails_fast_on_non_429_4xx(monkeypatch):
    calls = []

    def fake_urlopen(req, timeout=60):
        calls.append(1)
        raise _http_error(401)  # missing key — never resolves on retry

    monkeypatch.setattr(http.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(http.time, "sleep", lambda *_: None)

    try:
        http._get("http://x")
        assert False, "expected HTTPError"
    except urllib.error.HTTPError as err:
        assert err.code == 401
    assert len(calls) == 1  # no wasted retries on a permanent error


def test_is_cached_false_when_no_file(tmp_path, monkeypatch):
    monkeypatch.setattr(http, "CACHE_DIR", tmp_path)
    assert http.is_cached("missing.json", 24.0) is False


def test_is_cached_true_for_a_fresh_file(tmp_path, monkeypatch):
    monkeypatch.setattr(http, "CACHE_DIR", tmp_path)
    (tmp_path / "fresh.json").write_text("{}")
    assert http.is_cached("fresh.json", 24.0) is True


def test_is_cached_false_for_a_stale_file(tmp_path, monkeypatch):
    import os
    import time as time_module
    monkeypatch.setattr(http, "CACHE_DIR", tmp_path)
    path = tmp_path / "stale.json"
    path.write_text("{}")
    old = time_module.time() - 25 * 3600   # older than a 24h ttl
    os.utime(path, (old, old))
    assert http.is_cached("stale.json", 24.0) is False


def test_is_cached_false_when_ttl_disabled_or_no_key():
    assert http.is_cached(None, 24.0) is False
    assert http.is_cached("x.json", 0) is False
