"""Probe: does a System One model tier Who Am I? subjects better than production does?

**This is an experiment, not a pipeline stage.** Nothing imports it, `main.py` never calls
it, and it writes no content. It exists to answer one question with numbers before anyone
wires a third-party model into content generation.

## The question

`whoami_pool.fame` is the percentile of a subject's career production within their own
(sport, position) cohort, and `whoami_clues.tier_for_fame` cuts EASY / MEDIUM / HARD off
it. Production is a *proxy* for the thing the tier actually claims — how many fans could
name this player — and the pool builder knows it: the headshot gate is described in its own
docstring as "a decent proxy for 'this player was covered'", and the soccer league
allowlist exists because the 40th-best midfielder in the Ukrainian top flight is unknowable
to a US audience no matter how well he produced.

The proxy fails in both directions, and both failures are bad in a specific way:

- **Produced, unknown** (tiered EASY, plays HARD): compilers of counting stats on bad
  teams, pre-merger and dead-ball era leaders, kickers.
- **Known, underproduced** (tiered HARD, plays EASY): short peaks, famous busts, famous
  role players, anyone whose fame came from a moment rather than a career.

A System One model answers the real question directly: it returns a calibrated probability
that a casual fan could name the player. This probe scores a sample, maps the answers back
to tiers two ways, and diffs against what ships today.

## Two tier mappings, on purpose

`--mapping absolute` cuts the recognition score at fixed levels. It answers "what would the
model ship", and it moves the tier *mix* as well as the ordering.

`--mapping share` sorts by the model's probability and cuts at the exact tier shares the
current pool has. The mix is then identical by construction, so every disagreement is a
real reordering — one subject swapped tiers with another — rather than an artifact of where
thresholds were put. **Read `share` first.** It isolates the claim under test (production
ranks subjects wrong) from a claim nobody made (the cuts are in the wrong place).

## Running it

    # plumbing check, no API key, no network
    python -m tools.ingest.fame_probe --offline --per-tier 3

    # the real thing (needs TYPESAFE_API_KEY in tools/ingest/.env)
    python -m tools.ingest.fame_probe --per-tier 12 --sport nfl nba
    python -m tools.ingest.fame_probe --all --out /tmp/fame_probe.json

`--out` caches every answer, and a rerun with the same `--out` reuses it, so iterating on
the tier mapping costs nothing after the first pass.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import random
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .main import load_dotenv
from .whoami_clues import DIFFICULTIES, difficulty_of
from .whoami_pool import POOL_FILE
from .models import WhoAmIEntry

API_URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"

# Ordered vague -> specific, the way a Score's levels have to be. Index 0..3 maps onto the
# recognition ladder the tiers are really about; `_LEVEL_TIERS` is where each level lands.
RECOGNITION_LEVELS = [
    "Nobody outside their own fanbase's deep cuts would recognize this name",
    "Only fans who follow this sport closely would recognize this name",
    "Most fans of this sport would recognize this name",
    "A household name — even casual sports fans know it",
]
_LEVEL_TIERS = ["hard", "hard", "medium", "easy"]

# `--mapping absolute` cuts the 0-3 score here. Deliberately generous to `easy`: a tier that
# is wrong in the "player is harder than we said" direction costs a player their run, while
# the other direction just makes one puzzle a gift.
ABSOLUTE_CUTS = [(2.0, "easy"), (1.0, "medium")]

DATA_DIR = Path(__file__).resolve().parent / "data"


# ── State + questions ─────────────────────────────────────────────────────────

def subject_state(entry: WhoAmIEntry) -> dict:
    """The facts we hand the model about one subject.

    The player's NAME is included, which is the whole point — we are asking about
    real-world recognition of a person, not about the strength of a stat line. The career
    facts ride along because they disambiguate (there are several Chris Johnsons) and
    because era and franchise are part of why a name is or isn't famous.
    """
    best = entry.best_season or {}
    return {
        "name": entry.canonical,
        "sport": entry.sport,
        "position": entry.position,
        "career_span": f"{entry.first_year}-{entry.last_year}",
        "seasons_played": entry.seasons,
        "teams": list(entry.teams or []),
        "career_line": entry.stat_line,
        "best_season": (f"{best.get('year', '')} {best.get('team', '')}: {best.get('line', '')}".strip()
                        if best else ""),
    }


QUESTIONS = {
    # The primary signal. A Noul returns the probability of yes, which is exactly the
    # quantity `fame` is pretending to be — so it drops straight into the same percentile
    # machinery the pool already uses.
    "casual_can_name": {
        "type": "noul",
        "instructions": "A casual US sports fan who follows this sport a few times a year "
                        "would recognize this player's name.",
    },
    # The same judgment as an ordered ladder. Kept because a Score's per-level
    # probabilities show WHERE the model is torn, which a single probability hides, and
    # because `--mapping absolute` needs a level to cut.
    "recognition": {
        "type": "score",
        "instructions": "How widely recognized is this player's name among sports fans?",
        "criteria": RECOGNITION_LEVELS,
    },
    # Not used for tiering. It is the control: if this tracks `fame` closely while
    # `casual_can_name` does not, then the model and the pipeline agree about production
    # and disagree about fame, which is the result this probe is looking for. If it
    # disagrees about production too, the model is wrong about the sport and the fame
    # numbers should not be trusted either.
    "was_productive": {
        "type": "noul",
        "instructions": "This player was statistically productive relative to others who "
                        "played the same position in the same era.",
    },
}


# ── Transport ─────────────────────────────────────────────────────────────────

class ProbeError(RuntimeError):
    pass


def ask(state: dict, key: str, *, timeout: int = 30, attempts: int = 5) -> dict:
    """One `/v1/systemone` call. Retries 429/529 with backoff, per the API's own guidance —
    the docs are explicit that the published rate limits move without notice while they are
    scaling, so a probe that assumes a fixed ceiling will fail on someone else's busy day.
    """
    body = json.dumps({"state": state, "model": MODEL, "questions": QUESTIONS}).encode()
    req = urllib.request.Request(
        API_URL, data=body, method="POST",
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())["answers"]
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 529) or attempt == attempts - 1:
                raise ProbeError(f"{exc.code} {exc.reason}: {exc.read()[:200]!r}") from exc
            retry_after = exc.headers.get("retry-after")
            time.sleep(float(retry_after) if retry_after else 2 ** attempt)
        except urllib.error.URLError as exc:
            if attempt == attempts - 1:
                raise ProbeError(str(exc)) from exc
            time.sleep(2 ** attempt)
    raise ProbeError("unreachable")


def offline_answers(state: dict) -> dict:
    """A deterministic stand-in so the sampling, mapping and reporting can be exercised —
    and unit-tested — without a key or a network. It is NOT a model: it hashes the name.
    Its only contract is answer SHAPE, so a mapping bug shows up here instead of after
    someone has paid for a thousand calls.
    """
    rng = random.Random(f"fame-probe-{state['name']}")
    p = rng.random()
    level = min(3, int(p * 4))
    return {
        "casual_can_name": {"type": "noul", "noul": round(p, 4)},
        "recognition": {
            "type": "score", "score": float(level), "confidence": 0.5,
            "legend": {str(i): v for i, v in enumerate(RECOGNITION_LEVELS)},
            "probabilities": {str(i): 1.0 if i == level else 0.0 for i in range(4)},
        },
        "was_productive": {"type": "noul", "noul": round(rng.random(), 4)},
    }


# ── Tier mappings ─────────────────────────────────────────────────────────────

def tier_from_score(score: float) -> str:
    for cut, tier in ABSOLUTE_CUTS:
        if score >= cut:
            return tier
    return "hard"


def share_matched_tiers(scored: list[dict]) -> dict[str, str]:
    """Assign tiers by sorting on the model's probability and cutting at the CURRENT tier
    shares, per sport.

    Per sport, not globally: the pool is built to per-sport tier quotas
    (`whoami_pool.BUNDLE_PER_SPORT_PER_TIER`), so a global cut would read F1's thin easy
    tier as a disagreement about individual players when it is really a difference in how
    the sports were sampled.
    """
    out: dict[str, str] = {}
    by_sport: dict[str, list[dict]] = collections.defaultdict(list)
    for row in scored:
        by_sport[row["sport"]].append(row)
    for sport, rows in by_sport.items():
        counts = collections.Counter(r["current_tier"] for r in rows)
        ranked = sorted(rows, key=lambda r: -r["p_casual"])
        i = 0
        for tier in ("easy", "medium", "hard"):
            for row in ranked[i:i + counts[tier]]:
                out[row["key"]] = tier
            i += counts[tier]
    return out


# ── Sampling + scoring ────────────────────────────────────────────────────────

def load_pool(path: Path) -> list[WhoAmIEntry]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    return [WhoAmIEntry(**row) for row in rows]


def sample(pool: list[WhoAmIEntry], *, per_tier: int | None, sports: list[str] | None,
           seed: int) -> list[WhoAmIEntry]:
    """`per_tier` entries from every (sport, tier) bucket, so the diff can't be dominated by
    whichever bucket happens to be biggest. `per_tier=None` takes everything."""
    entries = [e for e in pool if not sports or e.sport in sports]
    if per_tier is None:
        return entries
    rng = random.Random(seed)
    buckets: dict[tuple[str, str], list[WhoAmIEntry]] = collections.defaultdict(list)
    for entry in entries:
        buckets[(entry.sport, difficulty_of(entry))].append(entry)
    picked: list[WhoAmIEntry] = []
    for bucket in sorted(buckets):
        rows = sorted(buckets[bucket], key=lambda e: e.canonical)
        rng.shuffle(rows)
        picked.extend(rows[:per_tier])
    return picked


def score_all(entries: list[WhoAmIEntry], *, key: str | None, workers: int,
              cache: dict[str, dict]) -> list[dict]:
    def one(entry: WhoAmIEntry) -> dict:
        cache_key = f"{entry.sport}:{entry.canonical}"
        answers = cache.get(cache_key)
        if answers is None:
            state = subject_state(entry)
            answers = offline_answers(state) if key is None else ask(state, key)
            cache[cache_key] = answers
        return {
            "key": cache_key,
            "name": entry.canonical,
            "sport": entry.sport,
            "fame": entry.fame,
            "current_tier": difficulty_of(entry),
            "p_casual": float(answers["casual_can_name"]["noul"]),
            "recognition": float(answers["recognition"]["score"]),
            "recognition_confidence": float(answers["recognition"].get("confidence", 0.0)),
            "p_productive": float(answers["was_productive"]["noul"]),
        }

    if key is None or workers <= 1:
        return [one(e) for e in entries]
    with ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(one, entries))


# ── Reporting ─────────────────────────────────────────────────────────────────

def spearman(xs: list[float], ys: list[float]) -> float:
    """Rank correlation, stdlib-only (ties averaged). Pearson on the raw numbers would be
    the wrong test: `fame` is already a percentile and `p_casual` is a probability, so only
    the ORDER of the two is comparable."""
    if len(xs) < 2:
        return 0.0

    def ranks(values: list[float]) -> list[float]:
        order = sorted(range(len(values)), key=lambda i: values[i])
        out = [0.0] * len(values)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
                j += 1
            avg = (i + j) / 2 + 1
            for k in range(i, j + 1):
                out[order[k]] = avg
            i = j + 1
        return out

    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = (sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry)) ** 0.5
    return num / den if den else 0.0


def report(scored: list[dict], *, mapping: str, examples: int) -> None:
    proposed = (share_matched_tiers(scored) if mapping == "share"
                else {r["key"]: tier_from_score(r["recognition"]) for r in scored})
    for row in scored:
        row["proposed_tier"] = proposed[row["key"]]

    agree = sum(1 for r in scored if r["proposed_tier"] == r["current_tier"])
    print(f"\nscored {len(scored)} subjects · mapping={mapping} · "
          f"agreement {agree}/{len(scored)} ({agree / len(scored):.0%})")

    print("\nconfusion (rows = shipping tier, cols = model tier)")
    print(f"{'':>8}" + "".join(f"{t:>9}" for t in DIFFICULTIES))
    for current in DIFFICULTIES:
        rows = [r for r in scored if r["current_tier"] == current]
        line = "".join(f"{sum(1 for r in rows if r['proposed_tier'] == t):>9}" for t in DIFFICULTIES)
        print(f"{current:>8}{line}")

    fame = [r["fame"] or 0.0 for r in scored]
    print(f"\nspearman(fame, p_casual)    {spearman(fame, [r['p_casual'] for r in scored]):+.3f}"
          "   <- how much production and recognition actually agree")
    print(f"spearman(fame, p_productive) {spearman(fame, [r['p_productive'] for r in scored]):+.3f}"
          "   <- control: should be high, or the model doesn't know the sport")

    order = {t: i for i, t in enumerate(DIFFICULTIES)}
    moved = [r for r in scored if r["proposed_tier"] != r["current_tier"]]
    harder = sorted((r for r in moved if order[r["proposed_tier"]] > order[r["current_tier"]]),
                    key=lambda r: r["p_casual"])
    easier = sorted((r for r in moved if order[r["proposed_tier"]] < order[r["current_tier"]]),
                    key=lambda r: -r["p_casual"])
    for label, rows in (("PRODUCED BUT UNKNOWN (model says harder)", harder),
                        ("KNOWN BUT UNDERPRODUCED (model says easier)", easier)):
        print(f"\n{label} — {len(rows)} total")
        for row in rows[:examples]:
            print(f"  {row['name']:<28} {row['sport']:<9} "
                  f"{row['current_tier']:>6} -> {row['proposed_tier']:<6} "
                  f"fame={row['fame']:.3f} p_casual={row['p_casual']:.3f}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--pool", type=Path, default=DATA_DIR / POOL_FILE)
    ap.add_argument("--sport", nargs="*", dest="sports")
    ap.add_argument("--per-tier", type=int, default=8,
                    help="subjects per (sport, tier) bucket; default 8")
    ap.add_argument("--all", action="store_true", help="score the whole pool")
    ap.add_argument("--mapping", choices=("share", "absolute"), default="share")
    ap.add_argument("--examples", type=int, default=12)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--seed", type=int, default=20260921)
    ap.add_argument("--offline", action="store_true",
                    help="stub answers — exercises everything but the model")
    ap.add_argument("--out", type=Path, help="cache answers here; rerun reuses them")
    args = ap.parse_args()

    load_dotenv()
    key = None if args.offline else os.environ.get("TYPESAFE_API_KEY")
    if key is None and not args.offline:
        raise SystemExit("TYPESAFE_API_KEY required (tools/ingest/.env), or pass --offline")

    pool = load_pool(args.pool)
    entries = sample(pool, per_tier=None if args.all else args.per_tier,
                     sports=args.sports, seed=args.seed)
    print(f"pool {len(pool)} · sampled {len(entries)} · "
          f"{'OFFLINE STUB — no model was called' if key is None else MODEL}")

    cache: dict[str, dict] = {}
    if args.out and args.out.exists():
        cache = json.loads(args.out.read_text(encoding="utf-8"))
        print(f"reusing {len(cache)} cached answers from {args.out}")
    try:
        scored = score_all(entries, key=key, workers=args.workers, cache=cache)
    finally:
        if args.out:
            args.out.write_text(json.dumps(cache, indent=1) + "\n", encoding="utf-8")

    report(scored, mapping=args.mapping, examples=args.examples)


if __name__ == "__main__":
    main()
