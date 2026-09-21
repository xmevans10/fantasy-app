"""The automated growth engine's pure logic: selection, idempotency keys, and the two rules that
keep it from posting something unanswerable (never a board kind without its image) or twice (the
ledger). Nothing here touches X or Supabase — the network paths are monkeypatched.
"""
from __future__ import annotations

from tools.marketing import x_engine


def _asset(kind, sport, caption="hi", file=None, replies=(), reveal=None):
    return {"kind": kind, "sport": sport, "caption": caption, "file": file,
            "replies": list(replies), "reveal": {"text": reveal} if reveal else {},
            "date": "2026-09-21"}


def test_select_assets_filters_kinds_and_caps():
    assets = [_asset("whoami", "nfl"), _asset("keep4", "nfl"),
              _asset("whoami", "nba"), _asset("whoami", "baseball")]
    got = x_engine.select_assets(assets, cap=2, sports=None, kinds=("whoami",))
    assert [(a["kind"], a["sport"]) for a in got] == [("whoami", "nfl"), ("whoami", "nba")]


def test_select_assets_filters_sport_and_blank_captions():
    assets = [_asset("whoami", "nfl"), _asset("whoami", "nba", caption="   ")]
    assert x_engine.select_assets(assets, cap=5, sports={"nba"}, kinds=("whoami",)) == []


def test_post_id_is_stable():
    assert x_engine.post_id("2026-09-21", "whoami", "nfl", "main") == "2026-09-21:whoami:nfl:main"
    assert x_engine.post_id("2026-09-21", "whoami", "nfl", "reply:2") == "2026-09-21:whoami:nfl:reply:2"


def test_bucket_url_matches_what_publish_uploads(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://proj.supabase.co/")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "k")
    assert (x_engine.bucket_url("2026-09-21", "keep4-nfl-2026-09-21.png")
            == "https://proj.supabase.co/storage/v1/object/public/marketing/x/2026-09-21/keep4-nfl-2026-09-21.png")


def test_post_assets_threads_replies_and_is_idempotent(monkeypatch):
    recorded: dict[str, str] = {}
    sent: list[tuple[str, str | None]] = []
    monkeypatch.setattr(x_engine, "ledger_has", lambda pid: pid in recorded)
    monkeypatch.setattr(x_engine, "ledger_record",
                        lambda pid, tid, date, kind, sport: recorded.__setitem__(pid, tid))
    monkeypatch.setattr(x_engine, "_tweet",
                        lambda access, text, reply_to=None, media_ids=None: sent.append((text, reply_to)) or f"t{len(sent)}")

    a = _asset("whoami", "nfl", "Clue 1", replies=["Clue 2", "Clue 3"])
    kwargs = dict(date="2026-09-21", cap=2, sports=None, kinds=("whoami",),
                  use_media=False, dry_run=False, force=False)
    assert x_engine.post_assets([a], "tok", **kwargs) == 1
    assert [s[0] for s in sent] == ["Clue 1", "Clue 2", "Clue 3"]
    assert sent[1][1] == recorded["2026-09-21:whoami:nfl:main"]          # threaded
    assert recorded["2026-09-21:whoami:nfl:reply:2"] == "t3"

    sent.clear()
    assert x_engine.post_assets([a], "tok", **kwargs) == 0               # already posted
    assert sent == []


def test_dry_run_sends_nothing(monkeypatch):
    def boom(*a, **k):
        raise AssertionError("dry run must not hit the network or the ledger")
    monkeypatch.setattr(x_engine, "_tweet", boom)
    monkeypatch.setattr(x_engine, "ledger_record", boom)
    monkeypatch.setattr(x_engine, "ledger_has", lambda pid: False)
    a = _asset("whoami", "nfl", "Clue 1")
    assert x_engine.post_assets([a], None, date="2026-09-21", cap=2, sports=None,
                                kinds=("whoami",), use_media=False, dry_run=True, force=False) == 1


def test_board_kind_is_never_posted_without_media(monkeypatch):
    sent: list = []
    monkeypatch.setattr(x_engine, "_tweet", lambda *a, **k: sent.append(1))
    monkeypatch.setattr(x_engine, "ledger_has", lambda pid: False)
    monkeypatch.setattr(x_engine, "ledger_record", lambda *a, **k: None)
    a = _asset("keep4", "nfl", "Keep 4, cut 4", file="keep4-nfl-2026-09-21.png")
    assert x_engine.post_assets([a], None, date="2026-09-21", cap=2, sports=None,
                                kinds=("keep4",), use_media=False, dry_run=False, force=False) == 0
    assert sent == []


def test_board_kind_is_skipped_when_upload_is_refused(monkeypatch):
    """The current grant has no media.write, so upload_media returns None — the board must be
    dropped, not posted as a caption nobody can answer."""
    monkeypatch.setattr(x_engine, "upload_media", lambda *a, **k: None)
    monkeypatch.setattr(x_engine, "download", lambda url: b"")
    monkeypatch.setattr(x_engine, "_tweet", lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not post")))
    monkeypatch.setattr(x_engine, "ledger_has", lambda pid: False)
    monkeypatch.setattr(x_engine, "ledger_record", lambda *a, **k: None)
    a = _asset("keep4", "nfl", "Keep 4, cut 4", file="keep4-nfl-2026-09-21.png")
    assert x_engine.post_assets([a], "tok", date="2026-09-21", cap=2, sports=None,
                                kinds=("keep4",), use_media=True, dry_run=False, force=False) == 0


def test_reveal_replies_only_to_a_post_we_actually_made(monkeypatch):
    ledger = {"2026-09-21:whoami:nfl:main": "t1"}
    sent: list[tuple[str, str | None]] = []
    monkeypatch.setattr(x_engine, "ledger_has", lambda pid: pid in ledger)
    monkeypatch.setattr(x_engine, "ledger_get", lambda pid: ledger.get(pid))
    monkeypatch.setattr(x_engine, "ledger_record",
                        lambda pid, tid, date, kind, sport: ledger.__setitem__(pid, tid))
    monkeypatch.setattr(x_engine, "_tweet",
                        lambda access, text, reply_to=None, media_ids=None: sent.append((text, reply_to)) or "t2")
    a = _asset("whoami", "nfl", "Clue 1", reveal="It was X.")
    assert x_engine.post_reveals([a], "tok", date="2026-09-21", sports=None,
                                 kinds=("whoami",), dry_run=False, force=False) == 1
    assert sent == [("It was X.", "t1")]
    # a kind with no main in the ledger is a no-op
    b = _asset("keep4", "nba", "Keep 4", reveal="Answers")
    assert x_engine.post_reveals([b], "tok", date="2026-09-21", sports=None,
                                 kinds=("keep4",), dry_run=False, force=False) == 0
