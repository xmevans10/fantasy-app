"""The voice: turn a reply brief into copy with a cheap LLM, across the archetype range.

Deterministic templates are never hip (docs/GROWTH-ENGINE.md §3.1), so briefs are handed to a
nano model. The job is short and high-volume, so the guardrails below — not model size — do the
quality work. Which *kind* of reply comes from `x_archetypes`; this module just writes it well.

Guardrails, enforced after generation (never trusted to the model):
* `x_algo.is_risky` blocks injuries/tragedy/politics before and after;
* links, @-mentions, hashtags and emoji stripped; one line; hard-truncated at X's limit;
* numbers are only allowed if they came from the post or an explicit verified `context`.

Config: `OPENAI_API_KEY` / `OPENAI_MODEL` from env, `tools/marketing/.env`, or the Supabase KV so
CI can use it. Default is the cheapest usable nano.
"""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request

from . import x_algo, x_archetypes

DEFAULT_MODEL = "gpt-5.4-nano"
MAX_CHARS = 280

BASE_RULES = """You write ONE reply to a viral sports post, as @_Playbook_ (a daily sports trivia
game). Match the register of sports Twitter — a sharp, funny fan, never a brand.

Rules, all mandatory:
- ONE sentence, normal capitalization, <= 140 characters, no semicolons
- no hashtags, no links, no @mentions, no emoji
- do NOT promote or mention the app
- NEVER state a statistic or fact that is not in the post or the verified context you are given.
  Do not invent numbers
- never joke about injuries, death, illness, arrests, or politics; never a person's body or family
- do not restate the post; do not begin with "congratulations", "this", or "imagine"

TASK: {task}

Output ONLY the reply text, nothing else."""


_DIGITS_RE = re.compile(r"\d[\d,.]*")
_WORD_NUMS = {"one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
              "hundred", "thousand", "million", "billion", "first", "second", "third", "half"}


def quantity_tokens(text: str) -> set[str]:
    """Every number-like token — digits and number words — so we can prove none were invented."""
    low = (text or "").lower()
    return set(_DIGITS_RE.findall(low)) | {w for w in re.findall(r"[a-z]+", low)
                                           if w in _WORD_NUMS}


def invented_numbers(out: str, sources: list[str]) -> set[str]:
    """Number tokens in `out` that are absent from the post/context. Non-empty => the draft
    fabricated a quantity and must not ship. This is the guard that keeps us from posting a false
    stat with the brand's name on it."""
    return quantity_tokens(out) - quantity_tokens(" ".join(s or "" for s in sources))


def _config() -> tuple[str | None, str]:
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
    text = (text or "").strip().strip('"').strip("'").replace("\n", " ")
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[@#]\w+", "", text).strip()
    text = re.sub(r"\s+", " ", text)
    return text[:MAX_CHARS].strip()


def _chat(api_key: str, model: str, messages: list[dict]) -> str:
    body = {"model": model, "messages": messages}
    if model.startswith(("gpt-5", "o4", "o3")):
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


def draft_reply(post_text: str, *, archetype: str | None = None, context: str | None = None,
                api_key: str | None = None, model: str | None = None) -> str | None:
    """One reply line. `archetype` None/'auto' picks a safe one by rotation; `context` is a
    verified fact (our catalog) the model may use for `needs_fact` archetypes."""
    if x_algo.is_risky(post_text):
        return None
    aid = archetype
    if aid in (None, "auto"):
        aid = x_archetypes.pick(post_text, x_archetypes.allowed())
    a = x_archetypes.get(aid) or x_archetypes.get("fact")
    key, cfg_model = _config()
    key = api_key or key
    if not key:
        return None
    messages = [{"role": "system", "content": BASE_RULES.format(task=a.prompt)}]
    for example_post, example_reply in a.examples:
        messages += [{"role": "user", "content": f"Post: {example_post}"},
                     {"role": "assistant", "content": example_reply}]
    user = f"Post: {post_text.strip()[:500]}"
    if context:
        user += f"\nVerified context you may use: {context.strip()[:400]}"
    messages.append({"role": "user", "content": user})
    try:
        out = _clean(_chat(key, model or cfg_model, messages))
    except Exception as e:  # noqa: BLE001 — a failed draft is skipped, never fatal
        print(f"[voice] draft failed: {e}")
        return None
    invented = invented_numbers(out, [post_text, context or ""])
    if invented:
        # One corrective retry, then drop. A fabricated number is a -234 report waiting to happen.
        messages += [{"role": "assistant", "content": out},
                     {"role": "user", "content":
                      f"You invented these numbers: {', '.join(sorted(invented))}. Rewrite with NO "
                      f"number that is not in the post or the verified context."}]
        try:
            out = _clean(_chat(key, model or cfg_model, messages))
        except Exception:  # noqa: BLE001
            return None
        if not out or invented_numbers(out, [post_text, context or ""]):
            return None
    if not out or x_algo.is_risky(out):
        return None
    return out


def draft_variants(post_text: str, ids: list[str] | None = None, **kw) -> dict[str, str]:
    """One draft per archetype, so a human (or calibration) can choose the shape that fits."""
    ids = ids if ids is not None else x_archetypes.allowed()
    out: dict[str, str] = {}
    for aid in ids:
        text = draft_reply(post_text, archetype=aid, **kw)
        if text:
            out[aid] = text
    return out


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser(description="Draft reply options in the @_Playbook_ voice.")
    ap.add_argument("post", help="the post to reply to (text)")
    ap.add_argument("--archetype", default="auto",
                    help="auto|<id>; ids: " + ", ".join(x_archetypes.ARCHETYPES))
    ap.add_argument("--variants", action="store_true", help="one draft per safe archetype")
    ap.add_argument("--context", default=None, help="a verified fact the model may use")
    ap.add_argument("--model", default=None)
    args = ap.parse_args()
    if args.variants:
        for aid, text in draft_variants(args.post, context=args.context, model=args.model).items():
            print(f"[{aid}] {text}")
        return 0
    draft = draft_reply(args.post, archetype=args.archetype, context=args.context, model=args.model)
    print(draft if draft else "(no draft)")
    return 0 if draft else 1


if __name__ == "__main__":
    raise SystemExit(main())
