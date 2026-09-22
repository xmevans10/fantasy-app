"""The voice: turn a reply brief into actual copy with a cheap LLM.

Deterministic templates produce competent-but-never-hip lines (see docs/GROWTH-ENGINE.md). This
module gives the briefs a writer. It deliberately runs a **nano** model — the job is short, the
volume is high, and the guardrails below do more for quality than a bigger model would.

Guardrails, enforced after generation, not trusted to the model:
* `x_algo.is_risky` blocks injuries/tragedy/politics;
* links, @-mentions, hashtags and emoji are stripped;
* whitespace collapsed to one line, hard-truncated at X's limit.

Config: `OPENAI_API_KEY` / `OPENAI_MODEL` from the process env, `tools/marketing/.env`, or the
Supabase KV (`openai_api_key`, `openai_model`) so CI can use it. Default model is the cheapest
usable nano.
"""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request

from . import x_algo

DEFAULT_MODEL = "gpt-5.4-nano"
MAX_CHARS = 280

SYSTEM = """You are the voice of @_Playbook_, a daily sports trivia game (Keep 4/Cut 4, blind
resumes). You write ONE reply to someone else's viral sports post on X.

Reverse-engineered from what actually wins (see docs/GROWTH-ENGINE.md "What wins"): the top
replies are confident one-line TAKES, often carrying one specific detail, not questions and not
lowercase. Rules, all mandatory:
- ONE sentence, normal capitalization, <= 140 characters, no semicolons
- no hashtags, no links, no @mentions, no emoji
- sound like a sharp, funny fan with a take, never a brand
- lead with a BOLD OPINION or a comparison; do not end with a polite question unless nothing
  else fits
- NEVER state a statistic or fact that is not already in the post. Do not invent numbers
- never mention or promote the app
- never joke about injuries, death, illness, arrests, or politics
- do not restate the post; never start with "congratulations", "this", or "imagine"
Output ONLY the reply text, nothing else."""

# Few-shot: the studied voice — confident, specific, normal case. No invented numbers.
_EXAMPLES = [
    ("Twins Ausar and Amen Thompson are now the first pair of brothers in NBA history to each "
     "receive a $100 million deal.",
     "two brothers, 363 million combined, and neither one can shoot a jumper. the league has "
     "never been weirder"),
    ("Players with more multi-TD receiving games than Davante Adams: Jerry Rice, Randy Moss, "
     "Terrell Owens. That's it.",
     "adams is in a group chat with three first-ballot hall of famers and still gets called "
     "overrated. tough crowd"),
    ("Aaron Donald is back like he never left.",
     "the nfc west just saw aaron donald back on the schedule and got real quiet"),
]


def _config() -> tuple[str | None, str]:
    """(api_key, model) from env -> .env -> Supabase KV. Key is optional; model always defaults."""
    model = os.getenv("OPENAI_MODEL")
    key = os.getenv("OPENAI_API_KEY")
    try:
        from . import x_client
        env = x_client.load_env()
        key = key or env.get("OPENAI_API_KEY")
        model = model or env.get("OPENAI_MODEL")
    except FileNotFoundError:
        pass
    if key is None or model is None:
        try:
            from . import x_engine
            key = key or x_engine.kv_get("openai_api_key")
            model = model or x_engine.kv_get("openai_model")
        except Exception:  # noqa: BLE001 — KV is optional at import time
            pass
    return key, (model or DEFAULT_MODEL)


def _clean(text: str) -> str:
    """Strip what the rules forbid and normalise to one line."""
    text = (text or "").strip().strip('"').strip("'").replace("\n", " ")
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[@#]\w+", "", text).strip()
    text = re.sub(r"\s+", " ", text)
    return text[:MAX_CHARS].strip()


def _chat(api_key: str, model: str, messages: list[dict]) -> str:
    body = {"model": model, "messages": messages}
    if model.startswith(("gpt-5", "o4", "o3")):      # reasoning-era params
        body["max_completion_tokens"] = 300
    else:
        body["max_tokens"] = 80
        body["temperature"] = 0.9
    req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
                                 data=json.dumps(body).encode(), method="POST",
                                 headers={"Authorization": f"Bearer {api_key}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read())["choices"][0]["message"]["content"] or ""
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"openai {e.code}: {e.read().decode()[:200]}") from e


def draft_reply(post_text: str, *, api_key: str | None = None, model: str | None = None) -> str | None:
    """One reply line for `post_text`, or None when the target is off-limits / generation fails."""
    if x_algo.is_risky(post_text):
        return None
    key, cfg_model = _config()
    key = api_key or key
    if not key:
        return None
    messages = [{"role": "system", "content": SYSTEM}]
    for example_post, example_reply in _EXAMPLES:
        messages += [{"role": "user", "content": f"Post: {example_post}"},
                     {"role": "assistant", "content": example_reply}]
    messages.append({"role": "user", "content": f"Post: {post_text.strip()[:500]}"})
    try:
        out = _clean(_chat(key, model or cfg_model, messages))
    except Exception as e:  # noqa: BLE001 — a failed draft is skipped, never fatal
        print(f"[voice] draft failed: {e}")
        return None
    if not out or x_algo.is_risky(out):
        return None
    return out


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Draft one reply in the @_Playbook_ voice.")
    ap.add_argument("post", help="the post to reply to (text)")
    ap.add_argument("--model", default=None)
    args = ap.parse_args()
    draft = draft_reply(args.post, model=args.model)
    print(draft if draft else "(no draft)")
    return 0 if draft else 1


if __name__ == "__main__":
    raise SystemExit(main())
