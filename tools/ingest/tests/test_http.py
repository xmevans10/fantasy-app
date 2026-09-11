"""HTTP retry behavior — the balldontlie pipeline 429s without backoff otherwise.

Regression guard for the NBA-isn't-live bug: a 429 must be retried (it's the one
4xx that resolves on its own), while other 4xx must still fail fast.
"""
import inspect
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


# --- 2026-09-05 stall regression -------------------------------------------------------
# A nightly `daily_puzzle` run stalled 24 minutes with zero new cache writes in the last
# 10, `sample`d inside a TLS handshake. Root cause: `_get`'s per-attempt socket timeout
# (60s) x its retry count (4) x a per-id loop of ~900 NBA pool ids meant a run of
# consecutive unreachable/stalled ids could burn minutes each — measured live against a
# black-holed host with the pre-fix settings: 202.6s to give up on ONE url. These guard
# both halves of the fix: a real, bounded socket timeout on every attempt, and a retry
# count that keeps one bad URL's worst case well under a minute.

def test_get_passes_a_bounded_socket_timeout_to_urlopen(monkeypatch):
    seen_timeouts = []

    def fake_urlopen(req, timeout=None):
        seen_timeouts.append(timeout)
        return _Resp(b"OK")

    monkeypatch.setattr(http.urllib.request, "urlopen", fake_urlopen)

    http._get("http://x")

    assert seen_timeouts == [http._TIMEOUT_S]
    assert isinstance(http._TIMEOUT_S, (int, float)) and 0 < http._TIMEOUT_S <= 30


def test_get_gives_up_after_a_bounded_number_of_attempts(monkeypatch):
    calls = []

    def fake_urlopen(req, timeout=60):
        calls.append(1)
        raise urllib.error.URLError("connection timed out")

    slept = []
    monkeypatch.setattr(http.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(http.time, "sleep", lambda s: slept.append(s))

    try:
        http._get("http://x")
        assert False, "expected RuntimeError once retries are exhausted"
    except RuntimeError:
        pass

    # Bounded, not unbounded: a permanently-unreachable host must not be retried forever.
    assert len(calls) == 3
    assert len(slept) == len(calls)


def test_get_worst_case_wall_clock_per_url_is_small(monkeypatch):
    """Regression for the actual stall shape: with the old 60s-timeout/4-retry settings a
    single black-holed URL cost 202.6s (measured live). The fixed settings' worst case —
    every attempt's timeout plus every backoff sleep, all mocked here to their real
    durations — must stay a small multiple of one timeout, not minutes."""
    def fake_urlopen(req, timeout=60):
        raise urllib.error.URLError("connection timed out")

    slept_total = {"s": 0.0}
    monkeypatch.setattr(http.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr(http.time, "sleep", lambda s: slept_total.__setitem__("s", slept_total["s"] + s))

    try:
        http._get("http://x")
    except RuntimeError:
        pass

    # Read the retry count off the function itself rather than restating it: a hardcoded 3
    # here would keep passing if someone raised the DEFAULT back to 6, which is precisely the
    # regression this test exists to stop.
    retries = inspect.signature(http._get).parameters["retries"].default
    worst_case = retries * http._TIMEOUT_S + slept_total["s"]
    assert worst_case < 90, (
        f"worst case {worst_case:.1f}s from retries={retries}, timeout={http._TIMEOUT_S}s, "
        f"backoff={slept_total['s']:.1f}s — was ~202s before the fix")
