"""Reply archetypes — the range of things that actually work, not one silver bullet.

Derived by labelling the replies in the 2026-09-22 study (docs/GROWTH-ENGINE.md §3.1). The
observed sample leans on *takes* and *facts*; questions and pure link-drops underperform. But
"which archetype" is topic-dependent, so the engine should carry the whole portfolio, weight it
by safety, and (once API credits allow measurement) learn per-topic which one lands.

Each archetype carries:
* `safety` — `safe` for a brand account, `medium` (can annoy a fanbase, e.g. mocking), `risky`
  (hating on a player — real engagement, real brand risk; off unless explicitly enabled);
* `needs_fact` — whether it must be grounded in a verified stat (our catalog) to be honest;
* `prompt` — the instruction handed to the writer model;
* `examples` — few-shot draws in the studied voice.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Archetype:
    id: str
    label: str
    safety: str          # safe | medium | risky
    needs_fact: bool
    prompt: str
    examples: tuple[tuple[str, str], ...] = ()


ARCHETYPES: dict[str, Archetype] = {
    a.id: a for a in [
        Archetype(
            "fact", "specific fact / context drop", "safe", True,
            "Add ONE specific, verifiable detail the post leaves out (a number, a season, a name). "
            "State it plainly, then land a short take. The fact must come from the context given; "
            "never invent one.",
            (("The Jets passed on JSN in the draft.",
              "and he turned in 337 yards and 3 TD in the Rose Bowl the year before. the tape was "
              "right there"),),
        ),
        Archetype(
            "support", "player support / defense", "safe", False,
            "Defend the player or team the post is dunking on, with one concrete reason. Back the "
            "underdog; be the account that had their back.",
            (("Everyone is calling the rookie QB a bust.",
              "he has started four games behind the worst line in the league. give it a year"),),
        ),
        Archetype(
            "ranking", "comparison / ranking", "safe", False,
            "Compare the subject to another player or era and plant a flag on which one you take. "
            "A confident ranking invites the argument that drives replies.",
            (("Klay is getting compared to D Wade.",
              "he's 2014 Ray Allen, not D Wade, and that's still a hall of fame career"),),
        ),
        Archetype(
            "prediction", "bold prediction", "safe", False,
            "Make one confident, falsifiable prediction about the subject. No hedging.",
            (("Tuten had a quiet week one.",
              "he's on this chart by week three. book it"),),
        ),
        Archetype(
            "meme", "absurdist meme", "safe", False,
            "One absurd, hyperbolic line that treats the situation like a bit. Lean into the "
            "ridiculousness; keep it affectionate, never about injuries or tragedy.",
            (("The QB looked awful on Sunday.",
              "maybe he was attacked by the boogie man last night. happens to the best of us"),),
        ),
        Archetype(
            "mock", "mock the thing (uniform, coach, fanbase)", "medium", False,
            "Mock the *thing* around the subject — a uniform, a play call, a coach's decision, the "
            "fanbase — never a person's body, family, or health. Punch at institutions, not people.",
            (("The Rams wore a new alternate uniform.",
              "those jerseys are atrocious and somebody signed off on them with a straight face"),),
        ),
        Archetype(
            "hate", "hate on the player", "risky", False,
            "A blunt, funny dismissal of the player's clear flaw (contract, motor, shot selection). "
            "Never appearance, family, or injury. This archetype is off unless explicitly enabled.",
            (("He signed a max contract,", "and is more like 2014 Ray Allen than D Wade. washed is "
              "a strong word but it's doing a lot of work here"),),
        ),
        Archetype(
            "question", "sharp question", "safe", False,
            "Ask ONE specific, arguable question that a real fan would answer. Use sparingly — the "
            "study shows questions win less often than takes.",
            (("The coach said he'd change the offense.",
              "then why did they run it up the middle on third and long four times"),),
        ),
    ]
}

# Preference order, safest first. `allowed()` filters by safety tier.
ORDER = ("fact", "support", "ranking", "prediction", "meme", "question", "mock", "hate")


def get(archetype_id: str) -> Archetype | None:
    return ARCHETYPES.get(archetype_id)


def allowed(include_medium: bool = False, include_risky: bool = False) -> list[str]:
    """Archetype ids a run may use, safest first."""
    out = []
    for aid in ORDER:
        a = ARCHETYPES[aid]
        if a.safety == "safe" or (a.safety == "medium" and include_medium) \
                or (a.safety == "risky" and include_risky):
            out.append(aid)
    return out


def pick(post_key: str, pool: list[str]) -> str:
    """Deterministic rotation so repeated runs vary and a topic doesn't always get one shape."""
    return pool[sum(post_key.encode()) % len(pool)]
