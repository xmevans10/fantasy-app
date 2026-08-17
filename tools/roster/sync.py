"""Turns `roster.json` into a live roster: `bots` rows + portrait assets.

The point of the character infrastructure is that **adding a character is a creative act, not an
engineering one**. Everything mechanical about a bot is derived here:

    tools/roster/roster.json   ->  public.bots            (name, voice, style, palette, teams)
                               ->  BallIQ/Assets.xcassets (bot-<id>.imageset, light + dark)
                               ->  ladder rung assignment (tools/ingest/ladder.py, by `skill`)

So a new opponent is one JSON object and one `--upsert --portraits` run. No SQL to write, no
asset catalog to hand-edit, no Swift to touch — `BotPortrait` looks the asset up by id and falls
back to the emoji if it isn't there yet.

Usage:
    python -m tools.roster.sync --dry-run
    python -m tools.roster.sync --upsert --portraits

Portraits need node/npx and rsvg-convert (`brew install librsvg`); `--upsert` needs
SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY from tools/ingest/.env.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import tempfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
ROSTER = pathlib.Path(__file__).resolve().parent / "roster.json"
ASSETS = ROOT / "BallIQ" / "Assets.xcassets"

# The six BotPalette colourways, as the (backdrop, dark backdrop) pair each portrait sits on.
# These MIRROR BallIQ/DesignSystem/Theme.swift — `soft` is the *Bg role token for each palette,
# because the portrait wants the quiet tint (the saturated `fill` stays on the card around it).
PALETTE_SOFT = {
    "amber":    ("FFEBD2", "3A2200"),   # warningBg
    "teal":     ("DDF5E5", "0E2C19"),   # successBg
    "electric": ("E3E9FF", "16224F"),   # accentBg
    "green":    ("EEFAC4", "2A3500"),   # voltBg
    "plum":     ("EBE3FE", "251744"),   # proBg
    "gold":     ("ECE6D7", "232019"),   # surfaceMuted
}


def load() -> list[dict]:
    bots = json.loads(ROSTER.read_text())["bots"]
    seen: set[str] = set()
    for b in bots:
        if b["id"] in seen:
            raise SystemExit(f"duplicate bot id {b['id']!r} in roster.json")
        seen.add(b["id"])
        if b["palette"] not in PALETTE_SOFT:
            raise SystemExit(f"{b['id']}: unknown palette {b['palette']!r}")
    # `skill` IS the rung order — ladder.py sorts by base_skill and assigns 1:1, so a tie would
    # make two rungs' opponents depend on dict ordering.
    skills = [b["skill"] for b in bots]
    if len(set(skills)) != len(skills):
        raise SystemExit("two bots share a `skill`; rung assignment would be ambiguous")
    if skills != sorted(skills):
        raise SystemExit("roster.json must be ordered by ascending `skill` — it reads as the ladder")
    return bots


def rows(bots: list[dict]) -> list[dict]:
    """`bots` table rows. Every column is derived; nothing here is hand-maintained SQL."""
    return [{
        "id": b["id"],
        "name": b["name"],
        "avatar": b["avatar"],
        "tagline": b["tagline"],
        "base_skill": b["skill"],
        "persona": b["style_line"],
        "style": b["style"],
        "style_line": b["style_line"],
        "backstory": b["backstory"],
        "palette": b["palette"],
        "voice": b["voice"],
        "favorite_teams": b.get("teams", []),
    } for b in bots]


def upsert(bots: list[dict]) -> None:
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not url or not key:
        raise SystemExit("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY required (tools/ingest/.env)")
    req = urllib.request.Request(
        f"{url}/rest/v1/bots?on_conflict=id", data=json.dumps(rows(bots)).encode(), method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}",
                 "Content-Type": "application/json",
                 "Prefer": "resolution=merge-duplicates,return=minimal"})
    try:
        urllib.request.urlopen(req)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"bots upsert failed {e.code}: {e.read().decode()[:500]}")
    print(f"upserted {len(bots)} bots")


def portraits(bots: list[dict]) -> None:
    """One `bot-<id>.imageset` each, from the character's own traits.

    DiceBear `open-peeps` (Pablo Stanley), CC0 1.0 — public domain, so no attribution obligation
    for a paid app. Chosen over `notionists` for a measurable reason: notionists has head=1 and no
    skin colours, so every character rendered as the same body wearing different props. open-peeps
    has head=48 and skin=5, which is what lets thirty of these be thirty different people.
    """
    work = pathlib.Path(tempfile.mkdtemp())
    for b in bots:
        soft_light, soft_dark = PALETTE_SOFT[b["palette"]]
        args = ["npx", "-y", "dicebear@latest", "open-peeps", str(work),
                "--seed", b["id"], "--format", "svg", "--size", "512",
                "--headVariant", b["head"], "--headProbability", "100",
                "--expressionVariant", b["expression"], "--expressionProbability", "100",
                "--skinColor", b["skin"], "--headContrastColor", b["hair"],
                "--maskProbability", "0"]
        # Clothing carries the character's own palette hue, so the saturated colour is present in
        # the portrait even though the backdrop is the quiet tint.
        args += ["--clothingColor", {"amber": "FF8A1E", "teal": "18A957", "electric": "1E50FF",
                                     "green": "C2F03A", "plum": "6D3BF5",
                                     "gold": "15120B"}[b["palette"]]]
        for trait, flag in (("facialHair", "facialHair"), ("accessories", "accessories")):
            if b.get(trait):
                args += [f"--{flag}Variant", b[trait], f"--{flag}Probability", "100"]
            else:
                args += [f"--{flag}Probability", "0"]
        subprocess.run(args, check=True, capture_output=True)
        svg = work / "open-peeps-0.svg"

        imageset = ASSETS / f"bot-{b['id']}.imageset"
        imageset.mkdir(parents=True, exist_ok=True)
        # Light and dark are separate rasterisations, not one tinted template: iOS template
        # rendering is alpha-only and would flatten the skin tones and clothing this style exists
        # to provide. Only the backdrop differs.
        for suffix, bg in (("", soft_light), ("-dark", soft_dark)):
            subprocess.run(["rsvg-convert", "-w", "384", "-h", "384",
                            "--background-color", f"#{bg}", str(svg),
                            "-o", str(imageset / f"{b['id']}{suffix}.png")], check=True)
        svg.unlink()
        (imageset / "Contents.json").write_text(json.dumps({
            "images": [
                {"filename": f"{b['id']}.png", "idiom": "universal", "scale": "3x"},
                {"appearances": [{"appearance": "luminosity", "value": "dark"}],
                 "filename": f"{b['id']}-dark.png", "idiom": "universal", "scale": "3x"},
            ],
            "info": {"author": "xcode", "version": 1},
        }, indent=2))
    print(f"wrote {len(bots)} imagesets to {ASSETS}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upsert", action="store_true", help="write the roster to `bots`")
    ap.add_argument("--portraits", action="store_true", help="regenerate the portrait assets")
    ap.add_argument("--dry-run", action="store_true", help="validate and print, write nothing")
    args = ap.parse_args()

    bots = load()
    print(f"roster: {len(bots)} characters, skill {bots[0]['skill']} -> {bots[-1]['skill']}")
    by_style: dict[str, int] = {}
    by_palette: dict[str, int] = {}
    for b in bots:
        by_style[b["style"]] = by_style.get(b["style"], 0) + 1
        by_palette[b["palette"]] = by_palette.get(b["palette"], 0) + 1
    print("  styles:   " + ", ".join(f"{k} {v}" for k, v in sorted(by_style.items())))
    print("  palettes: " + ", ".join(f"{k} {v}" for k, v in sorted(by_palette.items())))
    heads = {b["head"] for b in bots}
    print(f"  portraits: {len(heads)} distinct head shapes across {len(bots)} characters")

    if args.dry_run:
        for i, b in enumerate(bots, 1):
            print(f"  rung {i:>2}  {b['name']:<10} {b['skill']:.2f}  {b['style']:<10} "
                  f"{b['palette']:<9} {b['tagline']}")
        return 0
    if args.upsert:
        upsert(bots)
    if args.portraits:
        portraits(bots)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
