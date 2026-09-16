"""File the X assets into Google Drive, organized for the person doing the posting.

Talks to `drive_upload.gs`, an Apps Script web app that runs as the Drive owner and can only
write inside the one folder it is configured with (see its header for why that, and not a
service account or a stored OAuth token). Configured by two env vars; without them every call
is a logged no-op, so local runs and forks never fail on it:

    DRIVE_UPLOAD_URL    the web app's /exec URL
    DRIVE_UPLOAD_TOKEN  the shared secret set as UPLOAD_TOKEN in the script's properties

Layout, built for "what do I post today?" first and "find that card from Week 3" second:

    Daily posts/2026-09 September/2026-09-16 Wednesday/
        NFL - Today's board.png
        NFL - Yesterday's answers.png          (posted the day after its board)
        captions.txt                            every caption + alt text in this folder
    Week Packs/NFL/2026 Week 01/
        Pack drop card.png
        Game of the week (CAR vs CHI).png
        captions.txt
    Evergreen/How to play | Sports | K4C4 cards | Brand/

Each file's Drive description carries its caption and alt text too, so it is one click away in
Drive's details pane without opening captions.txt.

    python -m tools.marketing.drive --evergreen      # sync marketing/social-kit/06-x-series
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import pathlib
import re
import time
import urllib.request

from .brand import ROOT, SPORT_NAME

EVERGREEN_DIR = ROOT / "marketing" / "social-kit" / "06-x-series"


# ── layout (pure) ───────────────────────────────────────────────────────────────

def _day_folder(iso: str) -> list[str]:
    d = dt.date.fromisoformat(iso)
    return ["Daily posts", d.strftime("%Y-%m %B"), d.strftime("%Y-%m-%d %A")]


def _pack_folder(pack_id: str, sport: str) -> list[str]:
    """`nfl-2026-wk01` -> 2026 Week 01 (zero-padded so Week 10 sorts after Week 9);
    `baseball-2026-09-07-to-2026-09-13` -> 2026-09-07 to 2026-09-13."""
    rest = pack_id[len(sport) + 1:] if pack_id.startswith(sport + "-") else pack_id
    m = re.fullmatch(r"(\d{4})-wk(\d+)", rest)
    period = f"{m.group(1)} Week {int(m.group(2)):02d}" if m else rest.replace("-to-", " to ")
    return ["Week Packs", SPORT_NAME.get(sport, sport), period]


def place(asset: dict) -> tuple[list[str], str]:
    """(folder path, file name) for one manifest entry from `x_assets.build`."""
    sport = SPORT_NAME.get(asset.get("sport", ""), asset.get("sport", ""))
    kind = asset["kind"]
    if kind == "daily":
        return _day_folder(asset["date"]), f"{sport} - Today's board.png"
    if kind == "answers":
        post_day = (dt.date.fromisoformat(asset["date"]) + dt.timedelta(days=1)).isoformat()
        return _day_folder(post_day), f"{sport} - Yesterday's answers.png"
    if kind == "pack":
        return _pack_folder(asset["pack_id"], asset["sport"]), "Pack drop card.png"
    if kind == "game":
        matchup = asset.get("matchup") or "game"
        return _pack_folder(asset["pack_id"], asset["sport"]), f"Game of the week ({matchup}).png"
    return ["Other"], asset["file"]


_FORMAT_NAMES = {"k4c4": "K4C4", "who-am-i": "Who Am I", "journeyman": "Journeyman",
                 "the-grid": "The Grid", "puzzle-blitz": "Puzzle Blitz"}
_BRAND_NAMES = {"feature-week-packs": "Week Packs feature", "cta-app-store": "App Store CTA",
                "quote-prove-you-know-ball": "Prove you know ball",
                "streak-nudge": "Streak nudge", "reply-keep-or-cut": "Keep or cut reply (square)"}


def place_evergreen(filename: str) -> tuple[list[str], str]:
    """`how-to-play-the-grid-1600x900.png` -> (Evergreen/How to play, "The Grid.png").

    Named for a person scrolling Drive, not for a script. Unknown files still land somewhere
    sensible (Evergreen/Brand, name derived from the slug) so a new card never breaks the sync."""
    stem = re.sub(r"-\d+x\d+$", "", pathlib.Path(filename).stem)
    if stem.startswith("how-to-play-"):
        key = stem[len("how-to-play-"):]
        return ["Evergreen", "How to play"], f"{_FORMAT_NAMES.get(key, key.replace('-', ' ').title())}.png"
    if stem.startswith("sport-"):
        key = stem[len("sport-"):]
        return ["Evergreen", "Sports"], f"{SPORT_NAME.get(key, key.upper())}.png"
    m = re.fullmatch(r"k4c4-card-(.+)-week(\d+)(-revealed)?", stem)
    if m:
        who = m.group(1).replace("-", " ").title()
        tail = " (revealed)" if m.group(3) else ""
        return ["Evergreen", "K4C4 cards"], f"{who} - Week {int(m.group(2))}{tail}.png"
    name = _BRAND_NAMES.get(stem) or stem.replace("-", " ").capitalize()
    return ["Evergreen", "Brand"], f"{name}.png"


def captions_text(entries: list[dict]) -> str:
    """captions.txt for one folder: every file's caption and alt text, ready to paste."""
    blocks = []
    for e in entries:
        blocks.append(f"{e['name']}\n{'-' * len(e['name'])}\n{e['caption']}\n\nAlt text: {e['alt']}")
    return "\n\n\n".join(blocks) + "\n"


# ── client ──────────────────────────────────────────────────────────────────────

def configured() -> bool:
    return bool(os.getenv("DRIVE_UPLOAD_URL") and os.getenv("DRIVE_UPLOAD_TOKEN"))


def send(path: list[str], name: str, data: bytes, mime: str, description: str = "") -> dict:
    """One file into Drive. Apps Script answers a POST with a 302 to the result, which urllib
    follows as a GET, which is exactly the handshake the web app expects."""
    payload = json.dumps({"token": os.environ["DRIVE_UPLOAD_TOKEN"], "path": path, "name": name,
                          "mimeType": mime, "data": base64.b64encode(data).decode(),
                          "description": description}).encode()
    last = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(os.environ["DRIVE_UPLOAD_URL"], data=payload, method="POST",
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=120) as r:
                out = json.loads(r.read().decode() or "{}")
            if not out.get("ok"):
                raise RuntimeError(out.get("error") or "upload rejected")
            return out
        except Exception as e:  # noqa: BLE001 — retry transient failures, surface the last
            last = e
            if "unauthorized" in str(e):
                break
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"Drive upload of {'/'.join(path)}/{name} failed: {last}")


def upload_assets(out_dir: pathlib.Path, assets: list[dict]) -> dict[str, str]:
    """Upload a run's assets plus one captions.txt per folder. Returns {folder path: folder URL}
    and stamps `drive_url` on each asset. A no-op when Drive is not configured."""
    if not configured():
        print("[drive] not configured (DRIVE_UPLOAD_URL / DRIVE_UPLOAD_TOKEN unset); skipping")
        return {}
    folders: dict[str, list[dict]] = {}
    urls: dict[str, str] = {}
    for a in assets:
        path, name = place(a)
        res = send(path, name, (out_dir / a["file"]).read_bytes(), "image/png",
                   f"{a['caption']}\n\nAlt text: {a['alt']}")
        a["drive_url"] = res.get("fileUrl")
        key = "/".join(path)
        urls[key] = res.get("folderUrl", "")
        folders.setdefault(key, []).append({"name": name, "caption": a["caption"], "alt": a["alt"]})
        print(f"[drive] {key}/{name}")
    for key, entries in folders.items():
        # Merge with what the folder already holds from THIS run only: the daily run writes a
        # day folder once, so captions.txt describes exactly the files a run put there.
        send(key.split("/"), "captions.txt", captions_text(entries).encode(), "text/plain")
    return urls


def sync_evergreen() -> int:
    if not configured():
        print("[drive] not configured; nothing to sync")
        return 0
    files = sorted(EVERGREEN_DIR.glob("*.png"))
    for f in files:
        path, name = place_evergreen(f.name)
        send(path, name, f.read_bytes(), "image/png")
        print(f"[drive] {'/'.join(path)}/{name}")
    print(f"[drive] synced {len(files)} evergreen asset(s)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Upload X assets to Google Drive")
    ap.add_argument("--evergreen", action="store_true", help=f"sync {EVERGREEN_DIR.relative_to(ROOT)}")
    args = ap.parse_args()
    if args.evergreen:
        return sync_evergreen()
    ap.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
