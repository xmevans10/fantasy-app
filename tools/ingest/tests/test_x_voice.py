"""The LLM voice: post-generation guardrails, and that a risky target never reaches the model."""
from __future__ import annotations

from tools.marketing import x_archetypes, x_voice


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


def test_explicit_archetype_selects_its_prompt(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test")
    monkeypatch.setenv("OPENAI_MODEL", "gpt-4.1-nano")
    seen = {}

    def fake_chat(_key, _model, messages):
        seen["system"] = messages[0]["content"]
        return "a line"
    monkeypatch.setattr(x_voice, "_chat", fake_chat)
    x_voice.draft_reply("some post", archetype="meme")
    assert "absurd, hyperbolic" in seen["system"]          # the meme archetype's task


def test_variants_cover_the_allowed_archetypes(monkeypatch):
    monkeypatch.setattr(x_voice, "draft_reply",
                        lambda post, archetype=None, **k: f"reply-{archetype}")
    out = x_voice.draft_variants("some post")
    assert set(out) == set(x_archetypes.allowed())
    assert out["fact"] == "reply-fact"


def test_invented_numbers_flags_tokens_absent_from_the_source():
    assert x_voice.invented_numbers("signed for five years", ["$100 million each"]) == {"five"}
    assert x_voice.invented_numbers("337 yards and 3 TD", ["zero numbers here"]) == {"337", "3"}
    assert x_voice.invented_numbers("$100 million each", ["$100 million each"]) == set()


def test_draft_is_dropped_when_it_keeps_inventing(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test")
    monkeypatch.setenv("OPENAI_MODEL", "gpt-4.1-nano")
    monkeypatch.setattr(x_voice, "_chat", lambda *a, **k: "signed for five years")
    # post/context never mention 'five', so both the draft and the retry are rejected
    assert x_voice.draft_reply("Thompson twins each got a $100 million deal") is None


def test_no_key_means_no_draft(monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(x_voice, "_config", lambda: (None, "gpt-4.1-nano"))
    assert x_voice.draft_reply("normal post") is None
