"""X posts, minted with the puzzles: threads people answer, drawn from what just went live.

WHAT A POST IS FOR. The first version of this module advertised the app: "Today's K4C4", a
screenshot of Home, a PLAY button, a store link in the body. Nobody stops scrolling for an ad,
and X gives a post with a link in it a fraction of the reach. What does travel in sports and
fantasy X is a question the reader can answer in the replies (replies are the heaviest signal
the ranking has) in a format the niche already plays: the blind résumé, "name him from his
clubs", "keep four". Each of those IS one of our games, so the post is the pitch. So every
asset here is a THREAD:

  caption   the post itself: a question, no link
  replies   posted straight under it (the store link lives here, never in the body)
  reveal    posted later (next day for a daily), with an image when the answer has one

Formats, per sport, all 1600x900 with type sized to read at phone feed width:

  resume    blind résumé: two stat lines from one published board, names hidden, a star in
            the pair and the lines close. Reveal: the two real K4C4 cards.
  keep4     today's K4C4 as a readable table: eight names, their lines, "reply with your four"
  career    today's Journeyman path, crests left to right. Reveal: the name.
  whoami    today's Who Am I? as a text thread, one clue per reply (text-only posts hold
            their own on X, and a clue drip keeps the thread active). No image.

Week Packs get a keep4 post of the week's headline board.

Rendering: this module writes `spec.json` and `BallIQTests/XPostRenderTests` draws the images
with the app's fonts, colors, crests and card (needs Xcode, so CI runs it on macOS).

HONESTY. No crowd numbers ("71% got this wrong") until `game_results` has the volume to back
them: in the week this was written there were 11 ranked results in total.

Nothing here posts to X. Publishing to a public account stays a human decision.

    python -m tools.marketing.x_assets --daily 2026-09-17 --out build/x
    python -m tools.marketing.x_assets --packs 2026-09-16 --out build/x --no-render   # spec only
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import time
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
FAME_POOL = brand.ROOT / "tools" / "ingest" / "data" / "whoami_pool.json"
# A résumé pair needs a name people know. `fame` is the pool's career-and-peak percentile; the
# pool is each sport's ~150 most notable careers, so 0.85 is roughly the top 60 of those.
STAR_FAME = 0.85
# ...and lines close enough to argue about. Measured on 306 boards published Jun-Sep 2026.
CLOSE_GRADES = 0.15
RESUME_LOOKBACK_DAYS = 120
# A keep-four post only earns replies when people recognise the names: a board of eight
# journeymen is a fine game and a dead post. Three pool names is the floor.
KEEP4_MIN_KNOWN = 3


# ── text (pure) ─────────────────────────────────────────────────────────────────

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


def _noun(content: dict) -> str:
    grain = content.get("grain") or "season"
    return {"game": "game", "career": "career"}.get(grain, "season")


def _link_reply(campaign: str) -> str:
    return f"Eight real stat lines, sorted blind, every morning. Free: {brand.app_link(campaign)}"


def _who(p: dict) -> str:
    """"Priest Holmes (KC, 2002)" / "Jalen Coker (CAR, Week 1)"."""
    # `week` is an NFL week; other sports' game rows reuse the field for a game index.
    when = f"Week {p['week']}" if p.get("week") and p["id"].startswith("nfl-") else p.get("seasonYear") or ""
    bits = ", ".join(str(b) for b in (p.get("teamAbbr"), when) if b)
    return f"{p['name']} ({bits})" if bits else p["name"]


def thread_resume(sport: str, content: dict, a: dict, b: dict) -> dict:
    noun = _noun(content)
    theme = _board_title(content["theme"])
    better, worse = (a, b) if a["grade"] >= b["grade"] else (b, a)
    letter = "A" if better is a else "B"
    return dict(
        caption=_clamp(theme, "Blind résumé: {text}.\n\nPlayer A or Player B?"),
        replies=[_link_reply("x_resume")],
        reveal=dict(when="a few hours later", text=(
            f"A: {_who(a)}\nB: {_who(b)}\n\n{letter} was the better {noun}, "
            f"graded on the full line, not the name.")),
        alt=f"Two {SPORT_NAME.get(sport, sport)} stat lines side by side, labelled Player A and Player B, "
            f"names hidden. A: {_line(a)}. B: {_line(b)}.")


def thread_keep4(sport: str, content: dict, *, label: str | None = None) -> dict:
    theme = _board_title(content["theme"], label)
    ranked = sorted(content["players"], key=lambda p: -p.get("grade", 0))
    lead = f"{label}. " if label else ""
    return dict(
        caption=_clamp(theme, "{lead}Keep 4, cut 4: {text}.\n\nEight real lines. Reply with your four.", lead=lead),
        replies=[_link_reply("x_keep4")],
        reveal=dict(when="next day", text=_clamp(
            theme, "Keep 4 answers ({text}): " + ", ".join(p["name"] for p in ranked[:4])
            + f". Best line on the board: {ranked[0]['name']}.")),
        alt=f"{SPORT_NAME.get(sport, sport)} Keep 4 board, {theme}. "
            + "; ".join(f"{p['name']}: {_line(p)}" for p in content["players"]))


def thread_career(sport: str, content: dict) -> dict:
    stints = content.get("stints", [])
    name = content.get("answer", {}).get("canonical", "")
    return dict(
        caption=f"Name the player. {len(stints)} clubs, in order.\n\nReply with your guess.",
        replies=[_link_reply("x_career")],
        reveal=dict(when="next day", text=f"It was {name}." if name else ""),
        alt=f"{_article(SPORT_NAME.get(sport, sport))} {SPORT_NAME.get(sport, sport)} career path of {len(stints)} clubs, in order: "
            + ", ".join(f"{s.get('teamName', '')} {_years(s)}" for s in stints) + ". Name hidden.")


def thread_whoami(sport: str, content: dict) -> dict:
    clues = content.get("clues", [])
    name = content.get("answer", {}).get("canonical", "")
    return dict(
        caption=_clamp(clues[0]["text"] if clues else "",
                       f"Who am I? ({SPORT_NAME.get(sport, sport)})\n\nClue 1: {{text}}\n\nMore clues in the replies."),
        replies=[f"Clue {c['order']}: {c['text']}" for c in clues[1:]],
        reveal=dict(when="after the last clue", text=f"It was {name}.\n\n{_link_reply('x_whoami')}" if name else ""),
        alt="")


def _article(word: str) -> str:
    return "An" if word[:1].upper() in "AEFHILMNORSX" and word.isupper() or word[:1] in "AEIOU" else "A"


def _line(p: dict) -> str:
    return ", ".join(f"{s['value']} {s['label']}" for s in p.get("stats", []))


def _years(stint: dict) -> str:
    first, last = stint.get("firstYear"), stint.get("lastYear")
    return f"{first}" if first == last else f"{first}-{last}"


# ── résumé selection (pure) ─────────────────────────────────────────────────────

def fame_index() -> dict[tuple[str, str], float]:
    return {(e["sport"], e["canonical"].lower()): e["fame"]
            for e in json.loads(FAME_POOL.read_text()) if e.get("fame") is not None}


def _rank(seed: str) -> int:
    return int(hashlib.sha256(seed.encode()).hexdigest()[:12], 16)


def known_names(board: dict, fame: dict[tuple[str, str], float]) -> int:
    return sum((board["sport"], p["name"].lower()) in fame for p in board["content"]["players"])


def resume_pairs(board: dict, fame: dict[tuple[str, str], float]) -> list[tuple[float, dict, dict]]:
    """Every arguable pair on one board, strongest first: a star in it, the grades close, and a
    bonus when the star has the WORSE line (the reveal people argue with)."""
    sport, players = board["sport"], board["content"]["players"]
    out = []
    for i, x in enumerate(players):
        for y in players[i + 1:]:
            gx, gy = x.get("grade") or 0, y.get("grade") or 0
            if gx <= 0 or gy <= 0 or gx == gy or x["name"] == y["name"]:
                continue
            if abs(gx - gy) / max(gx, gy) > CLOSE_GRADES:
                continue
            fx, fy = (fame.get((sport, p["name"].lower()), 0.0) for p in (x, y))
            star = max(fx, fy)
            if star < STAR_FAME:
                continue
            star_lost = (fx > fy) == (gx < gy)
            closeness = 1 - abs(gx - gy) / max(gx, gy)
            out.append((star + (0.5 if star_lost else 0) + 0.25 * closeness, x, y))
    return sorted(out, key=lambda t: -t[0])


def pick_resume(boards: list[dict], fame: dict, salt: str) -> tuple[dict, dict, dict] | None:
    """One pair for `salt` (date + sport): drawn from the strongest few so the feed varies day to
    day without falling back to weak pairs, with A/B order shuffled so the star isn't always A."""
    pool = [(score, board, x, y) for board in boards for score, x, y in resume_pairs(board, fame)]
    if not pool:
        return None
    pool.sort(key=lambda t: (-t[0], t[1]["id"]))
    _, board, x, y = pool[_rank(salt) % min(8, len(pool))]
    return (board, x, y) if _rank(salt + "ab") % 2 else (board, y, x)


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


def archive_boards(date: str, days: int = RESUME_LOOKBACK_DAYS) -> list[dict]:
    """Keep4 dailies that have already been served: a résumé must never spoil today's board."""
    start = (dt.date.fromisoformat(date) - dt.timedelta(days=days)).isoformat()
    return _get(f"puzzles?select=id,sport,content,active_date&format=eq.keep4"
                f"&active_date=gte.{start}&active_date=lt.{date}&order=active_date.desc&limit=2000")


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


# ── build ───────────────────────────────────────────────────────────────────────

def collect(*, daily: str | None, packs: str | None,
            sport: str | list[str] | None) -> list[dict]:
    """Every thread for those dates, plus the published rows the renderer draws from."""
    posts: list[dict] = []
    sports = {sport} if isinstance(sport, str) else set(sport or ())

    def want(s: str) -> bool:
        return not sports or s in sports

    def order(s: str) -> int:
        return list(SPORT_NAME).index(s) if s in SPORT_NAME else 99

    if daily:
        keep4 = {b["sport"]: b for b in daily_boards(daily) if want(b["sport"])}
        journey = {s: r for s, r in dated(daily, "journeyman").items() if want(s)}
        whoami = {s: r for s, r in dated(daily, "whoami").items() if want(s)}
        archive: dict[str, list[dict]] = {}
        # Only sports shipped builds can play: a post whose link leads to an app without that
        # sport is a broken promise (validate.WIRE_SAFE_SPORTS is the release gate).
        from tools.ingest.validate import WIRE_SAFE_SPORTS
        for board in archive_boards(daily):
            if want(board["sport"]) and board["sport"] in WIRE_SAFE_SPORTS:
                archive.setdefault(board["sport"], []).append(board)
        fame = fame_index()
        for s in sorted(set(keep4) | set(journey) | set(whoami) | set(archive), key=order):
            picked = pick_resume(archive.get(s, []), fame, f"{daily}-{s}")
            if picked:
                board, a, b = picked
                posts.append(dict(file=f"resume-{s}-{daily}.png", reveal_file=f"resume-{s}-{daily}-reveal.png",
                                  kind="resume", sport=s, date=daily, puzzle_id=board["id"],
                                  content=board["content"], a=a["id"], b=b["id"],
                                  **thread_resume(s, board["content"], a, b)))
            if s in keep4 and known_names(keep4[s], fame) >= KEEP4_MIN_KNOWN:
                posts.append(dict(file=f"keep4-{s}-{daily}.png", kind="keep4", sport=s, date=daily,
                                  puzzle_id=keep4[s]["id"], content=keep4[s]["content"],
                                  **thread_keep4(s, keep4[s]["content"])))
            # A hard subject is a board nobody names from a timeline alone; post it and the
            # replies are empty. Easy and medium only.
            if s in journey and journey[s]["content"].get("difficulty") != "hard":
                posts.append(dict(file=f"career-{s}-{daily}.png", kind="career", sport=s, date=daily,
                                  puzzle_id=journey[s]["id"], content=journey[s]["content"],
                                  **thread_career(s, journey[s]["content"])))
            if s in whoami and whoami[s]["content"].get("clues"):
                posts.append(dict(file=None, kind="whoami", sport=s, date=daily,
                                  puzzle_id=whoami[s]["id"], **thread_whoami(s, whoami[s]["content"])))
    if packs:
        for pack in [p for p in packs_for(packs) if want(p["sport"])]:
            head = pack["items"][0]
            label = re.sub(r"^\d{4} ", "", pack["label"])
            posts.append(dict(file=f"keep4-{pack['id']}.png", kind="keep4", sport=pack["sport"],
                              date=packs, pack_id=pack["id"], puzzle_id=head["id"], label=label,
                              title=_board_title(head["content"]["theme"], pack["label"]),
                              content=head["content"],
                              **thread_keep4(pack["sport"], head["content"], label=pack["label"])))
    return posts


# Keys the renderer needs and the manifest doesn't: the rows themselves.
_SPEC_ONLY = ("content", "a", "b", "label", "title")


def write_spec(out: pathlib.Path, posts: list[dict]) -> pathlib.Path:
    drawn = [p for p in posts if p.get("file")]
    spec = {"out": str(out.resolve()),
            "posts": [{k: v for k, v in p.items() if k not in ("caption", "alt", "replies", "reveal")}
                      for p in drawn],
            "teams": teams_rows(p["sport"] for p in drawn)}
    path = out / "spec.json"
    path.write_text(json.dumps(spec))
    return path


def thread_markdown(a: dict) -> str:
    """One thread, ready to paste in order."""
    lines = [f"POST{' (attach ' + a['file'] + ')' if a.get('file') else ' (text only)'}:", a["caption"], ""]
    for i, r in enumerate(a.get("replies", []), 1):
        lines += [f"REPLY {i}:", r, ""]
    reveal = a.get("reveal") or {}
    if reveal.get("text"):
        att = f", attach {a['reveal_file']}" if a.get("reveal_file") else ""
        lines += [f"REVEAL ({reveal['when']}{att}):", reveal["text"], ""]
    if a.get("alt"):
        lines += [f"Alt text: {a['alt']}"]
    return "\n".join(lines).rstrip()


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


def build(out: pathlib.Path, *, daily: str | None, packs: str | None,
          sport: str | list[str] | None, draw: bool = True) -> list[dict]:
    out.mkdir(parents=True, exist_ok=True)
    posts = collect(daily=daily, packs=packs, sport=sport)
    spec = write_spec(out, posts)
    if draw and any(p.get("file") for p in posts):
        render(spec)
    assets = []
    for p in posts:
        files = [f for f in (p.get("file"), p.get("reveal_file")) if f]
        if draw and not all((out / f).exists() for f in files):
            print(f"[x] {p['kind']} {p['sport']} did not render; left out")
            continue
        assets.append({"width": W, "height": H, **{k: v for k, v in p.items() if k not in _SPEC_ONLY}})
    (out / "manifest.json").write_text(json.dumps(assets, indent=1))
    (out / "captions.md").write_text("\n\n".join(
        f"## {a['kind']} · {SPORT_NAME.get(a['sport'], a['sport'])}\n\n{thread_markdown(a)}" for a in assets) + "\n")
    return assets


# ── publish, summary, notify ────────────────────────────────────────────────────

def _storage(method: str, path: str, *, data: bytes | None = None, ctype: str = "application/json",
             extra: dict | None = None):
    base, key = _env()
    headers = {"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": ctype, **(extra or {})}
    req = urllib.request.Request(f"{base}/storage/v1/{path}", data=data, headers=headers, method=method)
    # Storage answers the odd 502/503 under a burst of uploads (the first run of the SwiftUI
    # renderer lost its whole notification to one), so gateway errors get three tries.
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                body = r.read()
                return json.loads(body) if body.strip() else None
        except urllib.error.HTTPError as e:
            if e.code not in (502, 503, 504) or attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))


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
        for field, url_field in (("file", "url"), ("reveal_file", "reveal_url")):
            if not a.get(field):
                continue
            key = f"x/{stamp}/{a[field]}"
            try:
                _storage("POST", f"object/{BUCKET}/{key}", data=(out / a[field]).read_bytes(),
                         ctype="image/png", extra={"x-upsert": "true", "Cache-Control": "max-age=300"})
            except Exception as e:  # noqa: BLE001 — one missing preview must not cost Drive and the notification
                print(f"[x] upload failed for {a[field]}: {e}; it stays in the artifact and Drive")
                continue
            a[url_field] = f"{base}/storage/v1/object/public/{BUCKET}/{key}"
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
        lines.append(f"### {a['kind'].title()} · {SPORT_NAME.get(a.get('sport', ''), '')}")
        if a.get("url"):
            lines.append(f"![{(a.get('alt') or a['kind'])[:120]}]({a['url']})")
        lines += ["", "```text", thread_markdown(a), "```"]
        if a.get("reveal_url"):
            lines.append(f"Reveal image: ![reveal]({a['reveal_url']})")
        lines.append("")
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
    ap.add_argument("--daily", metavar="DATE", help="that day's threads per sport")
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
    assets = build(out, daily=args.daily, packs=args.packs, sport=sport,
                   draw=not args.no_render)
    if not assets:
        print("[x] nothing published for those dates; no assets, no notification")
        return 0
    print(f"[x] {len(assets)} asset(s) in {out}/")
    for a in assets:
        print(f"\n===== {a['kind']} · {a.get('sport', '')}")
        print(thread_markdown(a))
    run_url = None
    if os.getenv("GITHUB_RUN_ID") and os.getenv("GITHUB_REPOSITORY"):
        run_url = (f"{os.getenv('GITHUB_SERVER_URL', 'https://github.com')}/"
                   f"{os.getenv('GITHUB_REPOSITORY')}/actions/runs/{os.getenv('GITHUB_RUN_ID')}")
    if args.no_render:
        return 0
    if args.publish:
        publish(out, assets, args.daily or args.packs or dt.date.today().isoformat())
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
