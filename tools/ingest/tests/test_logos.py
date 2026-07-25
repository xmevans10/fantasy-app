"""Tests for the logo rehost pipeline (mocked HTTP — no network, no real Storage)."""
from tools.ingest import logos


class _Resp:
    def __init__(self, body: bytes = b"", status: int = 200, content_type: str = "image/png"):
        self._body = body
        self.status = status
        self.headers = {"Content-Type": content_type}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _env(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "svc")


def test_logo_key_is_league_qualified_and_slugged():
    # Same code, different leagues -> different keys, so one crest can't overwrite the other.
    assert logos.logo_key("soccer", "England", "BRO") == "soccer/england/bro.png"
    assert logos.logo_key("soccer", "Australia", "BROA") == "soccer/australia/broa.png"
    # US single-league sports collapse the empty league to a stable placeholder.
    assert logos.logo_key("nfl", "", "SF") == "nfl/_/sf.png"


def test_rehost_returns_none_for_missing_source():
    assert logos.rehost(None, "soccer/england/bro.png") is None
    assert logos.rehost("", "soccer/england/bro.png") is None


def test_rehost_skips_upload_when_object_already_exists(monkeypatch):
    _env(monkeypatch)
    calls = {"HEAD": 0, "POST": 0, "GET": 0}

    def fake_urlopen(req, timeout=30):
        calls[req.get_method()] = calls.get(req.get_method(), 0) + 1
        if req.get_method() == "HEAD":
            return _Resp(status=200)
        raise AssertionError("should not download/upload when the object already exists")

    monkeypatch.setattr(logos.urllib.request, "urlopen", fake_urlopen)
    url = logos.rehost("https://espn.example/crest.png", "soccer/england/bro.png")
    assert url == "https://x.supabase.co/storage/v1/object/public/team-logos/soccer/england/bro.png"
    assert calls["HEAD"] == 1 and calls["POST"] == 0


def test_rehost_downloads_then_uploads_when_absent(monkeypatch):
    _env(monkeypatch)
    seq = []

    def fake_urlopen(req, timeout=30):
        method = req.get_method()
        seq.append(method)
        if method == "HEAD":
            import urllib.error
            raise urllib.error.HTTPError(req.full_url, 404, "not found", {}, None)
        if method == "GET":
            return _Resp(body=b"PNGDATA", content_type="image/png")
        if method == "POST":
            assert req.data == b"PNGDATA"
            assert req.headers.get("X-upsert") == "true"
            return _Resp()
        raise AssertionError(method)

    monkeypatch.setattr(logos.urllib.request, "urlopen", fake_urlopen)
    url = logos.rehost("https://espn.example/crest.png", "soccer/england/bro.png")
    assert url and url.endswith("/team-logos/soccer/england/bro.png")
    assert seq == ["HEAD", "GET", "POST"]


def test_rehost_returns_none_when_source_download_fails(monkeypatch):
    _env(monkeypatch)

    def fake_urlopen(req, timeout=30):
        if req.get_method() == "HEAD":
            import urllib.error
            raise urllib.error.HTTPError(req.full_url, 404, "not found", {}, None)
        raise ConnectionError("source is down")

    monkeypatch.setattr(logos.urllib.request, "urlopen", fake_urlopen)
    # A dead source degrades to "no logo" (null column), never an exception.
    assert logos.rehost("https://espn.example/gone.png", "soccer/england/bro.png") is None
