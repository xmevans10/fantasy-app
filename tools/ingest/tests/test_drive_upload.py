"""Google Drive filing for X assets: the folder layout, and the Apps Script handshake.

The mock server reproduces the one behavior that trips up clients of an Apps Script web app:
the POST is answered with a 302 and the JSON result is only returned on the redirected GET.
"""
from __future__ import annotations

import http.server
import json
import threading

import pytest

from tools.marketing import drive


def test_daily_threads_are_filed_by_posting_day():
    folder, name = drive.place({"kind": "keep4", "sport": "nfl", "date": "2026-09-16", "file": "x"})
    assert folder == ["Daily posts", "2026-09 September", "2026-09-16 Wednesday"]
    assert name == "NFL - Keep 4.png"
    assert drive.place({"kind": "resume", "sport": "baseball", "date": "2026-09-16"})[1] == "MLB - Blind resume.png"


def test_pack_weeks_are_zero_padded_so_they_sort():
    folder, name = drive.place({"kind": "keep4", "sport": "nfl", "pack_id": "nfl-2026-wk03", "file": "x"})
    assert folder == ["Week Packs", "NFL", "2026 Week 03"]
    assert name == "Keep 4.png"
    folder, _ = drive.place({"kind": "keep4", "sport": "baseball", "pack_id": "baseball-2026-09-07-to-2026-09-13"})
    assert folder == ["Week Packs", "MLB", "2026-09-07 to 2026-09-13"]


@pytest.mark.parametrize("filename,expected", [
    ("how-to-play-the-grid-1600x900.png", (["Evergreen", "How to play"], "The Grid.png")),
    ("sport-baseball-1600x900.png", (["Evergreen", "Sports"], "MLB.png")),
    ("k4c4-card-isaiah-likely-week1-1600x900.png", (["Evergreen", "K4C4 cards"], "Isaiah Likely - Week 1.png")),
    ("k4c4-card-kenneth-walker-week1-revealed-1600x900.png",
     (["Evergreen", "K4C4 cards"], "Kenneth Walker - Week 1 (revealed).png")),
    ("reply-keep-or-cut-1080x1080.png", (["Evergreen", "Brand"], "Keep or cut reply (square).png")),
    ("some-future-card-1600x900.png", (["Evergreen", "Brand"], "Some future card.png")),
])
def test_evergreen_groups(filename, expected):
    assert drive.place_evergreen(filename) == expected


def test_captions_file_lists_each_thread_in_posting_order():
    text = drive.captions_text([{"name": "NFL - Keep 4", "thread": "POST:\nCap\n\nREPLY 1:\nlink"}])
    assert "NFL - Keep 4" in text and text.index("POST:") < text.index("REPLY 1:")


def test_unconfigured_upload_is_a_quiet_noop(tmp_path, monkeypatch, capsys):
    monkeypatch.delenv("DRIVE_UPLOAD_URL", raising=False)
    monkeypatch.delenv("DRIVE_UPLOAD_TOKEN", raising=False)
    assert drive.upload_assets(tmp_path, [{"file": "a.png"}]) == {}
    assert "not configured" in capsys.readouterr().out


class _AppsScript(http.server.BaseHTTPRequestHandler):
    received: list[dict] = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        _AppsScript.received.append(body)
        self.send_response(302)
        ok = body["token"] == "secret"
        self.send_header("Location", f"/echo?ok={int(ok)}&name={body['name']}")
        self.end_headers()

    def do_GET(self):
        ok = "ok=1" in self.path
        out = ({"ok": True, "fileUrl": "https://drive/file", "folderUrl": "https://drive/folder"}
               if ok else {"ok": False, "error": "unauthorized"})
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


@pytest.fixture
def apps_script(monkeypatch):
    server = http.server.HTTPServer(("127.0.0.1", 0), _AppsScript)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    _AppsScript.received = []
    monkeypatch.setenv("DRIVE_UPLOAD_URL", f"http://127.0.0.1:{server.server_port}/exec")
    yield server
    server.shutdown()


def test_upload_follows_the_apps_script_redirect(apps_script, tmp_path, monkeypatch):
    monkeypatch.setenv("DRIVE_UPLOAD_TOKEN", "secret")
    (tmp_path / "r.png").write_bytes(b"\x89PNG fake")
    (tmp_path / "r2.png").write_bytes(b"\x89PNG fake")
    asset = {"file": "r.png", "reveal_file": "r2.png", "kind": "resume", "sport": "nfl",
             "date": "2026-09-16", "caption": "Cap", "alt": "Alt", "replies": ["link"],
             "reveal": {"when": "later", "text": "It was X"}}
    folders = drive.upload_assets(tmp_path, [asset])
    assert folders == {"Daily posts/2026-09 September/2026-09-16 Wednesday": "https://drive/folder"}
    assert asset["drive_url"] == "https://drive/file"
    names = [r["name"] for r in _AppsScript.received]
    assert names == ["NFL - Blind resume.png", "NFL - Blind resume (reveal).png", "captions.txt"]
    assert "Cap" in _AppsScript.received[0]["description"]


def test_a_wrong_token_fails_fast_and_loudly(apps_script, monkeypatch):
    monkeypatch.setenv("DRIVE_UPLOAD_TOKEN", "wrong")
    with pytest.raises(RuntimeError, match="unauthorized"):
        drive.send(["Daily posts"], "x.png", b"x", "image/png")
    assert len(_AppsScript.received) == 1, "an auth failure is not retried"
