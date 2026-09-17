"""X posts, minted with the puzzles: images, captions and alt text for what just went live.

Runs after the minting workflows (via x-assets.yml), reads only what is actually published, and
leaves every asset in three places so it can be found from the run itself:

  - the run LOG: one block per asset with its file name, caption and alt text;
  - the run ARTIFACT (`x-assets-*`): the PNGs plus manifest.json and captions.md;
  - the JOB SUMMARY: inline previews and copy-ready captions, when `--publish` has put the
    images somewhere GitHub can display them.

`--notify` then comments on the repo's tracking issue (label `x-assets`), @-mentioning the
owner, so GitHub pushes "your posts are ready" to their phone with the previews inline.

THE IMAGES ARE THE APP. This module writes `spec.json` (the published rows, verbatim) and
`BallIQTests/XPostRenderTests` draws each post from the shipping SwiftUI components: the K4C4
card, Home's daily card, the Journeyman career path, the Who Am I? clue ladder, the Week Pack
card. That needs Xcode, so rendering runs on a macOS runner. The previous Pillow renderer drew
its own imitation tiles, and every post came out as the same grid whatever the format.

Post kinds, all 1600x900 (X's 16:9):

  daily              today's K4C4 per sport, in one of three layouts rotated by day and sport
  lineup             one sport's three dailies, as Home stacks them
  journeyman         today's career path, answer hidden
  whoami             today's clue ladder, clue one showing (it is free in the game too)
  answers            yesterday's K4C4 revealed: top keep in foil, the closest cut
  journeyman-answer  yesterday's career path with the player named
  pack               a Week Pack drop: the pack card and its boards
  game               a pack's game of the week, one card per club

Nothing here posts to X. Publishing to a public account stays a human decision.

    python -m tools.marketing.x_assets --daily 2026-09-17 --answers 2026-09-16 --out build/x
    python -m tools.marketing.x_assets --packs 2026-09-16 --out build/x --no-render   # spec only
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from . import brand
from .brand import SPORT_NAME

W, H = 1600, 900
X_URL_WEIGHT = 23          # X counts every link as 23 characters, whatever its length
X_LIMIT = 280
BUCKET = "marketing"
KEEP_DAYS = 30
_UA = "PlaybookMarketing/1.0 (+https://xmevans10.github.io/fantasy-app/)"


# ── captions (pure) ─────────────────────────────────────────────────────────────

def x_length(text: str) -> int:
    """Characters as X counts them: each URL is 23, whatever its real length."""
    urls = re.findall(r"https?://\S+", text)
    return len(re.sub(r"https?://\S+", "", text)) + X_URL_WEIGHT * len(urls)


def _clamp(text: str, template: str, **kw) -> str:
    """Fill `template`, shortening the one free-text field `text` until X accepts it."""
    out = template.format(text=text, **kw)
    while x_length(out) > X_LIMIT and len(text) > 12:
        text = text[: len(text) - 4].rstrip(" ,:;") + "…"
        out = template.format(text=text, **kw)
    return out


def _board_title(theme: str, label: str | None = None) -> str:
    """"2026 Week 1: top TE performances" reads "Top TE performances" once the week is said."""
    if label and theme.startswith(f"{label}: "):
        theme = theme[len(label) + 2:]
    return theme[:1].upper() + theme[1:]


def caption_daily(sport: str, theme: str) -> str:
    return _clamp(theme, "Today's {sport} K4C4: {text}\n\n8 players. Keep the best 4, cut the rest.\n\n{link}",
                  sport=SPORT_NAME.get(sport, sport), link=brand.app_link("x_daily"))


def caption_answers(sport: str, theme: str, keeps: list[str]) -> str:
    return _clamp(theme, "Yesterday's {sport} K4C4: {text}\n\nThe keeps: {keeps}.\n\nHow many did you get? {link}",
                  sport=SPORT_NAME.get(sport, sport), keeps=", ".join(keeps),
                  link=brand.app_link("x_answers"))


def caption_pack(sport: str, label: str, boards: int, headline: str) -> str:
    week = re.sub(r"^\d{4} ", "", label)
    # Mid-sentence here ("led by top performances"), so the board title loses its capital,
    # unless it opens with an abbreviation like "CAR vs CHI".
    if headline[:2] != headline[:2].upper():
        headline = headline[:1].lower() + headline[1:]
    return _clamp(headline, "The {sport} {week} Pack just dropped: {boards} boards on the week that just ended, led by {text}.\n\n{link}",
                  sport=SPORT_NAME.get(sport, sport), week=week, boards=boards,
                  link=brand.app_link("x_pack"))


def caption_game(team_a: str, team_b: str) -> str:
    return _clamp(f"{team_a} vs {team_b}", "{text}: who had the better day?\n\n8 players from one game. Keep the best 4.\n\n{link}",
                  link=brand.app_link("x_game"))


def caption_lineup(sport: str, theme: str, *, whoami: bool, journeyman: bool) -> str:
    extras = [x for x, on in (("a mystery player", whoami), ("a career to name", journeyman)) if on]
    plus = f" Plus {' and '.join(extras)}." if extras else ""
    return _clamp(theme, "Today's {sport} boards are up. K4C4: {text}.{plus}\n\n{link}",
                  sport=SPORT_NAME.get(sport, sport), plus=plus, link=brand.app_link("x_lineup"))


def caption_journeyman(sport: str, clubs: int) -> str:
    return (f"Today's {SPORT_NAME.get(sport, sport)} Journeyman: {clubs} clubs, one career. "
            f"Name the player in five guesses or fewer.\n\n{brand.app_link('x_journeyman')}")


def caption_journeyman_answer(sport: str, name: str, clubs: int) -> str:
    return _clamp(name, "Yesterday's {sport} Journeyman was {text}, {clubs} clubs deep. Did you get it?\n\n{link}",
                  sport=SPORT_NAME.get(sport, sport), clubs=clubs,
                  link=brand.app_link("x_journeyman_answer"))


def caption_whoami(sport: str, clues: int) -> str:
    return (f"Today's {SPORT_NAME.get(sport, sport)} Who Am I? One clue is showing. "
            f"{clues} in total, and the fewer you need, the more you score.\n\n{brand.app_link('x_whoami')}")


# ── data (PostgREST, read-only) ─────────────────────────────────────────────────

def _env() -> tuple[str, str]:
    url, key = os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SERVICE_ROLE_KEY")
    if not (url and key):
        path = brand.ROOT / "tools" / "ingest" / ".env"
        if path.exists():
            for line in path.read_text().splitlines():
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip())
        url, key = os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SERVICE_ROLE_KEY")
    if not (url and key):
        raise SystemExit("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required")
    return url.rstrip("/"), key


def _get(path: str) -> list[dict]:
    base, key = _env()
    req = urllib.request.Request(f"{base}/rest/v1/{path}",
                                 headers={"apikey": key, "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def _in(values) -> str:
    return "in.(" + ",".join('"' + v.replace('"', '""') + '"' for v in values) + ")"


def daily_boards(date: str) -> list[dict]:
    """The canonical keep4 daily per sport for `date`, via puzzle_history (which, unlike
    `puzzles.active_date`, names exactly the row the app serves)."""
    hist = _get(f"puzzle_history?select=sport,puzzle_id&format=eq.keep4&served_date=eq.{date}")
    if not hist:
        return []
    ids = [h["puzzle_id"] for h in hist]
    rows = _get(f"puzzles?select=id,sport,content&id={urllib.parse.quote(_in(ids))}")
    return sorted(rows, key=lambda r: list(SPORT_NAME).index(r["sport"]) if r["sport"] in SPORT_NAME else 99)


def packs_for(date: str, sport: str | None = None) -> list[dict]:
    q = f"packs?select=id,sport,label,release_date&status=eq.published&release_date=eq.{date}"
    if sport:
        q += f"&sport=eq.{sport}"
    packs = _get(q)
    for p in packs:
        p["items"] = _get(f"pack_items?select=id,ordinal,role,format,content"
                          f"&pack_id=eq.{urllib.parse.quote(p['id'])}&order=ordinal")
    return [p for p in packs if p["items"]]


def dated(date: str, fmt: str) -> dict[str, dict]:
    """sport -> the `fmt` daily dated `date`, by `puzzles.active_date`: the row
    `RemotePuzzleRepository` serves for Journeyman and Who Am I?."""
    rows = _get(f"puzzles?select=id,sport,content&format=eq.{fmt}&active_date=eq.{date}&order=id")
    out: dict[str, dict] = {}
    for r in rows:
        out.setdefault(r["sport"], r)
    return out


def teams_rows(sports) -> list[dict]:
    """Raw `teams` rows for the renderer, so crests, colors and club names resolve exactly as
    the app resolves them (TeamIdentityIndex)."""
    sports = sorted(set(sports))
    if not sports:
        return []
    try:
        return _get(f"teams?select=*&sport={urllib.parse.quote(_in(sports))}")
    except Exception as e:  # noqa: BLE001 — identity is decoration; the app falls back too
        print(f"[x] teams lookup skipped: {e}")
        return []


def cron_sports(cron: str) -> list[str]:
    """The sports whose fresh-drop job runs on `cron`, read from fresh-drop.yml's own matrix so
    the schedule has one home. Several sports share a slot (NBA, MLB and NHL on Wednesday)."""
    text = (brand.ROOT / ".github" / "workflows" / "fresh-drop.yml").read_text()
    pairs = re.findall(r'-\s*sport:\s*(\w+)\s*\n\s*cron:\s*"([^"]+)"', text)
    return [sport for sport, c in pairs if c == cron]


LAYOUTS = ("fan", "hero", "duo")


def daily_layout(date: str, sport: str) -> str:
    """Rotates by day, offset by sport, so one morning's five boards don't share a layout and
    one sport's feed doesn't repeat itself two days running."""
    offset = list(SPORT_NAME).index(sport) if sport in SPORT_NAME else 0
    return LAYOUTS[(dt.date.fromisoformat(date).toordinal() + offset) % len(LAYOUTS)]


# ── build ───────────────────────────────────────────────────────────────────────

def _alt_daily(sport: str, theme: str, players: list[dict]) -> str:
    names = ", ".join(p.get("name", "") for p in players)
    return f"Playbook {SPORT_NAME.get(sport, sport)} K4C4 board: {theme}. Eight players: {names}."


def collect(*, daily: str | None, answers: str | None, packs: str | None,
            sport: str | list[str] | None) -> list[dict]:
    """Every post for those dates: the manifest entry (caption, alt, metadata) plus the published
    rows the renderer draws from. Pure reads."""
    posts: list[dict] = []

    sports = {sport} if isinstance(sport, str) else set(sport or ())

    def want(s: str) -> bool:
        return not sports or s in sports

    if daily:
        keep4 = {b["sport"]: b for b in daily_boards(daily) if want(b["sport"])}
        whoami = {s: r for s, r in dated(daily, "whoami").items() if want(s)}
        journey = {s: r for s, r in dated(daily, "journeyman").items() if want(s)}
        for s, board in keep4.items():
            theme = _board_title(board["content"]["theme"])
            posts.append(dict(file=f"daily-{s}-{daily}.png", kind="daily", sport=s, date=daily,
                              puzzle_id=board["id"], layout=daily_layout(daily, s),
                              content=board["content"], caption=caption_daily(s, theme),
                              alt=_alt_daily(s, theme, board["content"]["players"])))
        for s in [s for s in SPORT_NAME if s in keep4 and (s in whoami or s in journey)]:
            theme = _board_title(keep4[s]["content"]["theme"])
            posts.append(dict(file=f"lineup-{s}-{daily}.png", kind="lineup", sport=s, date=daily,
                              keep4=keep4[s]["content"],
                              whoami=whoami.get(s, {}).get("content"),
                              journeyman=journey.get(s, {}).get("content"),
                              caption=caption_lineup(s, theme, whoami=s in whoami,
                                                     journeyman=s in journey),
                              alt=f"Today's {SPORT_NAME[s]} dailies on Playbook: K4C4 ({theme})"
                                  + (", Who Am I?" if s in whoami else "")
                                  + (", Journeyman" if s in journey else "") + "."))
        for s, row in journey.items():
            clubs = [st.get("teamName", "") for st in row["content"].get("stints", [])]
            posts.append(dict(file=f"journeyman-{s}-{daily}.png", kind="journeyman", sport=s,
                              date=daily, puzzle_id=row["id"], content=row["content"],
                              caption=caption_journeyman(s, len(clubs)),
                              alt=f"Playbook {SPORT_NAME.get(s, s)} Journeyman: a career path of "
                                  f"{len(clubs)} clubs, in order: {', '.join(clubs)}. Name the player."))
        for s, row in whoami.items():
            clues = row["content"].get("clues", [])
            first = clues[0]["text"] if clues else ""
            posts.append(dict(file=f"whoami-{s}-{daily}.png", kind="whoami", sport=s, date=daily,
                              puzzle_id=row["id"], content=row["content"],
                              caption=caption_whoami(s, len(clues)),
                              alt=f"Playbook {SPORT_NAME.get(s, s)} Who Am I?: clue one of "
                                  f"{len(clues)} reads \"{first}\". The rest are locked."))
    if answers:
        for board in daily_boards(answers):
            s = board["sport"]
            if not want(s):
                continue
            theme = _board_title(board["content"]["theme"])
            ranked = sorted(board["content"]["players"], key=lambda p: -p.get("grade", 0))
            keeps = [p["name"] for p in ranked[:4]]
            posts.append(dict(file=f"answers-{s}-{answers}.png", kind="answers", sport=s,
                              date=answers, puzzle_id=board["id"], content=board["content"],
                              caption=caption_answers(s, theme, keeps),
                              alt=f"Answers to the {SPORT_NAME.get(s)} K4C4 board {theme}. "
                                  f"Keep: {', '.join(keeps)}. Cut: {', '.join(p['name'] for p in ranked[4:8])}."))
        for s, row in dated(answers, "journeyman").items():
            if not want(s):
                continue
            name = row["content"].get("answer", {}).get("canonical", "")
            clubs = [st.get("teamName", "") for st in row["content"].get("stints", [])]
            posts.append(dict(file=f"journeyman-answer-{s}-{answers}.png", kind="journeyman-answer",
                              sport=s, date=answers, puzzle_id=row["id"], content=row["content"],
                              caption=caption_journeyman_answer(s, name, len(clubs)),
                              alt=f"Yesterday's {SPORT_NAME.get(s, s)} Journeyman answer: {name}. "
                                  f"Clubs: {', '.join(clubs)}."))
    if packs:
        for pack in [p for p in packs_for(packs) if want(p["sport"])]:
            head = _board_title(pack["items"][0]["content"]["theme"], pack["label"])
            wire = {k: pack[k] for k in ("id", "sport", "label", "release_date")}
            items = [{**i, "pack_id": pack["id"]} for i in pack["items"]]
            posts.append(dict(file=f"pack-{pack['id']}.png", kind="pack", sport=pack["sport"],
                              date=packs, pack_id=pack["id"], pack=wire, items=items,
                              caption=caption_pack(pack["sport"], pack["label"], len(pack["items"]), head),
                              alt=f"The {SPORT_NAME.get(pack['sport'])} {pack['label']} Pack: "
                                  + "; ".join(_board_title(i["content"]["theme"], pack["label"])
                                              for i in pack["items"])))
            game = next((i for i in pack["items"] if i["role"] == "game"), None)
            if game:
                clubs: list[str] = []
                for p in game["content"]["players"]:
                    if p.get("teamAbbr") and p["teamAbbr"] not in clubs:
                        clubs.append(p["teamAbbr"])
                a, b = (clubs + ["", ""])[:2]
                posts.append(dict(file=f"game-{pack['id']}.png", kind="game", sport=pack["sport"],
                                  date=packs, pack_id=pack["id"], matchup=f"{a} vs {b}",
                                  pack=wire, items=items, item=game["id"],
                                  caption=caption_game(a, b),
                                  alt=f"{a} vs {b}: eight players from one game. "
                                      + ", ".join(p.get("name", "") for p in game["content"]["players"])))
    return posts


# Keys the renderer needs and the manifest doesn't: the rows themselves.
_SPEC_ONLY = ("content", "keep4", "whoami", "journeyman", "pack", "items", "item", "layout")


def write_spec(out: pathlib.Path, posts: list[dict]) -> pathlib.Path:
    spec = {"out": str(out.resolve()),
            "posts": [{k: v for k, v in p.items() if k not in ("caption", "alt")} for p in posts],
            "teams": teams_rows(p["sport"] for p in posts)}
    path = out / "spec.json"
    path.write_text(json.dumps(spec))
    return path


def render(spec: pathlib.Path) -> None:
    """Draw every post with `XPostRenderTests`. Destination and derived-data path are
    overridable because the runner's simulator names and a local checkout's shared build dir
    both vary (see the audit-session note on build.db contention)."""
    cmd = ["xcodebuild", "test", "-scheme", "BallIQ", "-project", str(brand.ROOT / "BallIQ.xcodeproj"),
           "-destination", os.getenv("X_POST_DESTINATION", "platform=iOS Simulator,name=iPhone 17"),
           "-only-testing:BallIQTests/XPostRenderTests", "CODE_SIGNING_ALLOWED=NO"]
    if os.getenv("X_POST_DERIVED_DATA"):
        cmd += ["-derivedDataPath", os.environ["X_POST_DERIVED_DATA"]]
    env = {**os.environ, "TEST_RUNNER_X_POST_SPEC": str(spec.resolve())}
    print("[x] rendering:", " ".join(cmd))
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        if "X_POST:" in line or "error:" in line or "failed" in line.lower():
            print("   ", line.strip())
    if proc.returncode != 0:
        print(proc.stdout[-4000:], proc.stderr[-2000:])
        print(f"[x] xcodebuild exited {proc.returncode}; keeping whatever rendered")


def build(out: pathlib.Path, *, daily: str | None, answers: str | None, packs: str | None,
          sport: str | list[str] | None, draw: bool = True) -> list[dict]:
    out.mkdir(parents=True, exist_ok=True)
    posts = collect(daily=daily, answers=answers, packs=packs, sport=sport)
    spec = write_spec(out, posts)
    if draw and posts:
        render(spec)
    assets = []
    for p in posts:
        path = out / p["file"]
        if draw and not path.exists():
            print(f"[x] {p['file']} did not render; left out")
            continue
        assets.append({"file": p["file"], "width": W, "height": H,
                       **{k: v for k, v in p.items() if k not in _SPEC_ONLY and k != "file"}})
    (out / "manifest.json").write_text(json.dumps(assets, indent=1))
    (out / "captions.md").write_text("\n\n".join(
        f"## {a['file']}\n\n{a['caption']}\n\nAlt text: {a['alt']}" for a in assets) + "\n")
    return assets


# ── publish, summary, notify ────────────────────────────────────────────────────

def _storage(method: str, path: str, *, data: bytes | None = None, ctype: str = "application/json",
             extra: dict | None = None):
    base, key = _env()
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": ctype, **(extra or {})}
    req = urllib.request.Request(f"{base}/storage/v1/{path}", data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=120) as r:
        body = r.read()
        return json.loads(body) if body.strip() else None


def publish(out: pathlib.Path, assets: list[dict], stamp: str) -> None:
    """Put the PNGs in the public `marketing` bucket so the job summary and the notification can
    show them inline, then drop anything older than KEEP_DAYS. Small: a handful of images a day,
    capped at a month, against a bucket we just cut by 1.9 GB."""
    base, _ = _env()
    try:
        _storage("POST", "bucket", data=json.dumps({"id": BUCKET, "name": BUCKET, "public": True}).encode())
    except urllib.error.HTTPError as e:
        if e.code not in (400, 409):
            raise
    for a in assets:
        key = f"x/{stamp}/{a['file']}"
        _storage("POST", f"object/{BUCKET}/{key}", data=(out / a["file"]).read_bytes(), ctype="image/png",
                 extra={"x-upsert": "true", "Cache-Control": "max-age=300"})
        a["url"] = f"{base}/storage/v1/object/public/{BUCKET}/{key}"
    (out / "manifest.json").write_text(json.dumps(assets, indent=1))
    cutoff = (dt.date.today() - dt.timedelta(days=KEEP_DAYS)).isoformat()
    try:
        folders = _storage("POST", f"object/list/{BUCKET}", data=json.dumps({"prefix": "x/", "limit": 1000}).encode()) or []
        old = [f["name"] for f in folders if f.get("name", "") < cutoff]
        for folder in old:
            files = _storage("POST", f"object/list/{BUCKET}",
                             data=json.dumps({"prefix": f"x/{folder}/", "limit": 1000}).encode()) or []
            names = [f"x/{folder}/{f['name']}" for f in files if f.get("name")]
            if names:
                _storage("DELETE", f"object/{BUCKET}", data=json.dumps({"prefixes": names}).encode())
        if old:
            print(f"[x] pruned {len(old)} day folder(s) older than {KEEP_DAYS} days")
    except Exception as e:  # noqa: BLE001 — pruning is housekeeping, never a reason to fail
        print(f"[x] prune skipped: {e}")


def summary_markdown(assets: list[dict], title: str, run_url: str | None,
                     drive_folders: dict[str, str] | None = None) -> str:
    lines = [f"## {title}", ""]
    for folder, url in (drive_folders or {}).items():
        lines.append(f"📁 Google Drive: [{folder}]({url})")
    if drive_folders:
        lines.append("")
    if run_url:
        lines += [f"Download every file from the run's **x-assets** artifact: {run_url}", ""]
    for a in assets:
        lines.append(f"### {a['kind'].title()} · {SPORT_NAME.get(a.get('sport', ''), '')} · `{a['file']}`")
        if a.get("url"):
            lines.append(f"![{a['alt'][:120]}]({a['url']})")
        lines += ["", "```text", a["caption"], "```", f"<sub>Alt text: {a['alt']}</sub>", ""]
    return "\n".join(lines)


def notify(assets: list[dict], title: str, run_url: str | None,
           drive_folders: dict[str, str] | None = None) -> None:
    """Comment on the tracking issue so GitHub pushes the owner a notification with previews."""
    token, repo = os.getenv("GITHUB_TOKEN"), os.getenv("GITHUB_REPOSITORY")
    owner = os.getenv("GITHUB_REPOSITORY_OWNER", "")
    if not (token and repo):
        print("[x] notify skipped: GITHUB_TOKEN / GITHUB_REPOSITORY not set (only runs in Actions)")
        return

    def gh(method: str, path: str, body: dict | None = None):
        req = urllib.request.Request(f"https://api.github.com/repos/{repo}/{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {token}",
                                              "Accept": "application/vnd.github+json",
                                              "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read() or b"null")

    try:
        gh("POST", "labels", {"name": "x-assets", "color": "1E50FF",
                              "description": "Auto-generated X post assets"})
    except urllib.error.HTTPError:
        pass                                            # already exists
    issues = gh("GET", "issues?labels=x-assets&state=open&per_page=1") or []
    if issues:
        number = issues[0]["number"]
    else:
        number = gh("POST", "issues", {
            "title": "X post assets",
            "labels": ["x-assets"],
            "body": "Every puzzle mint comments here when its X assets are ready. Each comment has "
                    "the images, copy-ready captions and alt text. Nothing is posted automatically."})["number"]
    body = (f"@{owner} " if owner else "") + f"**{len(assets)} X asset(s) ready.**\n\n" \
        + summary_markdown(assets, title, run_url, drive_folders)
    gh("POST", f"issues/{number}/comments", {"body": body[:64000]})
    print(f"[x] notified on issue #{number}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Render X post assets for what just went live")
    ap.add_argument("--daily", metavar="DATE", help="today's K4C4 board per sport")
    ap.add_argument("--answers", metavar="DATE", help="that day's boards, revealed")
    ap.add_argument("--packs", metavar="DATE", help="Week Packs opening on DATE")
    ap.add_argument("--sport", default=None)
    ap.add_argument("--pack-cron", default=None, metavar="CRON",
                    help="packs only: keep the sports whose fresh-drop cron this is")
    ap.add_argument("--out", default="build/x-assets")
    ap.add_argument("--publish", action="store_true", help="upload to the public marketing bucket")
    ap.add_argument("--summary", metavar="FILE", help="append a markdown summary (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--notify", action="store_true", help="comment on the x-assets tracking issue")
    ap.add_argument("--drive", action="store_true",
                    help="file the assets into Google Drive (tools/marketing/drive.py)")
    ap.add_argument("--title", default="X post assets")
    ap.add_argument("--no-render", action="store_true",
                    help="write spec.json and captions only (no Xcode); PNGs are not checked")
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    sport = args.sport
    if args.pack_cron and not sport:
        sport = cron_sports(args.pack_cron)
        print(f"[x] cron {args.pack_cron!r} -> {sport or 'no sports'}")
        if not sport:
            return 0
    assets = build(out, daily=args.daily, answers=args.answers, packs=args.packs, sport=sport,
                   draw=not args.no_render)
    if not assets:
        print("[x] nothing published for those dates; no assets, no notification")
        return 0
    print(f"[x] {len(assets)} asset(s) in {out}/")
    for a in assets:
        print(f"\n===== {a['file']} ({a['width']}x{a['height']}) · {a['kind']} · {a.get('sport', '')}")
        print(a["caption"])
        print(f"-- alt: {a['alt']}")
    run_url = None
    if os.getenv("GITHUB_RUN_ID") and os.getenv("GITHUB_REPOSITORY"):
        run_url = (f"{os.getenv('GITHUB_SERVER_URL', 'https://github.com')}/"
                   f"{os.getenv('GITHUB_REPOSITORY')}/actions/runs/{os.getenv('GITHUB_RUN_ID')}")
    if args.no_render:
        return 0
    if args.publish:
        publish(out, assets, args.daily or args.packs or args.answers or dt.date.today().isoformat())
    drive_folders: dict[str, str] = {}
    if args.drive:
        from . import drive
        try:
            drive_folders = drive.upload_assets(out, assets)
        except Exception as e:  # noqa: BLE001 — Drive is a convenience; the run keeps its artifact
            print(f"[drive] upload failed: {e}")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write(summary_markdown(assets, args.title, run_url, drive_folders) + "\n")
    if args.notify:
        notify(assets, args.title, run_url, drive_folders)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
