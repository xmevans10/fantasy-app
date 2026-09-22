"""The LLM voice: post-generation guardrails, and that a risky target never reaches the model."""
from __future__ import annotations

from tools.marketing import x_voice


def test_clean_strips_links_mentions_hashtags_and_newlines():
    cleaned = x_voice._clean('@statmuse see https://t.co/x #NBA\nbig take here')
    assert "https" not in cleaned and "@" not in cleaned and "#" not in cleaned
    assert "\n" not in cleaned and cleaned == "see big take here"


def test_clean_truncates_to_x_limit():
    assert len(x_voice._clean("a" * 500)) == x_voice.MAX_CHARS


def test_risky_target_is_refused_before_any_call(monkeypatch):
    called = {"n": 0}
    monkeypatch.setattr(x_voice, "_chat", lambda *a, **k: called.__setitem__("n", called["n"] + 1))
    assert x_voice.draft_reply("Star QB tears his ACL, out for the season") is None
    assert called["n"] == 0


def test_draft_is_cleaned_and_returned(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test")
    monkeypatch.setenv("OPENAI_MODEL", "gpt-4.1-nano")
    monkeypatch.setattr(x_voice, "_chat", lambda *a, **k: '"@nfl check https://t.co/x\nwho you got"')
    out = x_voice.draft_reply("some normal post")
    assert out == "check who you got"


def test_no_key_means_no_draft(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(x_voice, "_config", lambda: (None, "gpt-4.1-nano"))
    assert x_voice.draft_reply("normal post") is None
