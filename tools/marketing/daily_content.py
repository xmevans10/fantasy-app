#!/usr/bin/env python3
"""Generate ready-to-post captions for today's (or any date's) puzzles.

Pulls straight from the live `puzzles` table — no manual copywriting per day. Three formats,
chosen because they need nothing beyond what a fresh board already has: no pick-percentage /
crowd-rarity data exists yet (checked 2026-09-01: no rarity table, and N=8 players makes any
rarity stat we *could* compute meaningless anyway — see the growth handoff's N=8 warning).
Rarity-based formats ("87% picked wrong") are a real format, just not a September one; add them
once `game_results` has enough volume per board to make a percentage mean something.

Usage:
    python3 -m tools.marketing.daily_content                    # today, all sports
    python3 -m tools.marketing.daily_content --sport nfl         # one sport
    python3 -m tools.marketing.daily_content --date 2026-09-02   # a specific day (e.g. to
                                                                   # draft tomorrow's post early)

Reads SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY from tools/ingest/.env (read-only queries here,
so the anon key would also work, but the service key is what's already provisioned).

Output is plain text to stdout — copy-paste today, pipe into Zernio's API once that's wired.
"""
import argparse
import datetime
import json
import os
import sys
import urllib.parse
import urllib.request

ENV_PATH = os.path.join(os.path.dirname(__file__), "..", "ingest", ".env")

SPORT_DISPLAY = {
    "nfl": "NFL", "nba": "NBA", "baseball": "MLB", "soccer": "Soccer", "tennis": "Tennis",
}
FORMAT_DISPLAY = {
    "grid": "Grid", "keep4": "Keep4/Cut4", "whoami": "Who Am I?", "journeyman": "Journeyman",
}

APP_LINK = "https://apps.apple.com/app/id6785275045"  # TODO: swap for the Dub short link once set up


def load_env(path: str) -> dict:
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def fetch_puzzles(base_url: str, key: str, date: str, sport: str | None):
    params = {"active_date": f"eq.{date}", "select": "id,sport,format,content"}
    if sport:
        params["sport"] = f"eq.{sport}"
    url = f"{base_url}/rest/v1/puzzles?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={
        "apikey": key, "Authorization": f"Bearer {key}",
    })
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


# ---------------------------------------------------------------------------
# Format 1 — Daily Board Post (X, Threads, Bluesky). Post every morning once
# the day's boards are live. One line, states the puzzle, ends on a dare.
# ---------------------------------------------------------------------------
def format_daily_board(puzzle: dict) -> str | None:
    sport = SPORT_DISPLAY.get(puzzle["sport"], puzzle["sport"])
    content = puzzle["content"]

    if puzzle["format"] == "grid":
        rows = [r.get("label") or r.get("abbr") for r in content.get("rows", [])]
        cols = [c.get("label") or c.get("abbr") for c in content.get("cols", [])]
        if not rows or not cols:
            return None
        return (
            f"Today's {sport} Grid: {', '.join(rows)} × {', '.join(cols)}.\n"
            f"Nine cells, one guess each — go find the one nobody gets.\n"
            f"\U0001f7e2 Play: {APP_LINK}"
        )

    if puzzle["format"] == "whoami":
        clue_count = len(content.get("clues", []))
        return (
            f"Today's {sport} Who Am I? — {clue_count} clues, hardest first.\n"
            f"How few do you need?\n"
            f"\U0001f7e2 Play: {APP_LINK}"
        )

    return None


# ---------------------------------------------------------------------------
# Format 2 — Play-Along script (TikTok, Reels, Shorts). Not a caption, a
# shot list: what to film, in order, one weekly hour covers every sport.
# ---------------------------------------------------------------------------
def format_play_along_script(puzzle: dict) -> str | None:
    if puzzle["format"] != "whoami":
        return None
    sport = SPORT_DISPLAY.get(puzzle["sport"], puzzle["sport"])
    content = puzzle["content"]
    clues = sorted(content.get("clues", []), key=lambda c: c.get("order", 0))
    answer = content.get("answer", {}).get("canonical", "???")
    if not clues:
        return None

    lines = [f"PLAY-ALONG SCRIPT — {sport} Who Am I? ({answer})", "(60-90s, screen-record the app, voiceover, cut at last clue)", ""]
    for i, c in enumerate(clues, 1):
        beat = "pause, guess out loud" if i < len(clues) else "reveal beat — cut here"
        lines.append(f"  {i}. [{c.get('label', 'Clue')}] \"{c.get('text', '')}\" — {beat}")
    lines.append("")
    lines.append(f'CTA (last frame, on-screen text): "Today\'s board is in the app — how few clues do you need?"')
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Format 3 — Streak Nudge (X, Threads). Not tied to a specific puzzle, so
# it's evergreen — one written once, reused verbatim whenever there's a gap
# in the posting calendar. Included here so the tool prints the full day's
# kit, not just the puzzle-derived pieces.
# ---------------------------------------------------------------------------
STREAK_NUDGE = (
    "Your streak's at 12 and today's board is still sitting there.\n"
    "Don't let a Tuesday be the reason it ends."
)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--date", default=None, help="YYYY-MM-DD, default today (device-local convention: US Eastern)")
    ap.add_argument("--sport", default=None, choices=list(SPORT_DISPLAY))
    args = ap.parse_args()

    env = load_env(ENV_PATH)
    base_url = env.get("SUPABASE_URL")
    key = env.get("SUPABASE_SERVICE_ROLE_KEY")
    if not base_url or not key:
        print("Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in tools/ingest/.env", file=sys.stderr)
        sys.exit(1)

    date = args.date or datetime.date.today().isoformat()
    puzzles = fetch_puzzles(base_url, key, date, args.sport)
    if not puzzles:
        print(f"No puzzles found for {date}" + (f" / {args.sport}" if args.sport else ""), file=sys.stderr)
        sys.exit(1)

    print(f"=== Daily content kit — {date} ===\n")

    print("--- Format 1: Daily Board Post (X / Threads / Bluesky, one per sport) ---\n")
    for p in puzzles:
        text = format_daily_board(p)
        if text:
            print(f"[{p['id']}]\n{text}\n")

    print("--- Format 2: Play-Along Script (TikTok / Reels / Shorts, pick one per week) ---\n")
    for p in puzzles:
        script = format_play_along_script(p)
        if script:
            print(script + "\n")

    print("--- Format 3: Streak Nudge (evergreen, use on a gap day) ---\n")
    print(STREAK_NUDGE + "\n")


if __name__ == "__main__":
    main()
