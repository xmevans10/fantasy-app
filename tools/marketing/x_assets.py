"""X posts, minted with the puzzles: images, captions and alt text for what just went live.

Runs inside the minting workflows (daily-puzzle.yml, fresh-drop.yml) right after the boards
are written, reads only what is actually published, and leaves every asset in three places so
it can be found from the run itself:

  - the run LOG: one block per asset with its file name, caption and alt text;
  - the run ARTIFACT (`x-assets-*`): the PNGs plus manifest.json and captions.md;
  - the JOB SUMMARY: inline previews and copy-ready captions, when `--publish` has put the
    images somewhere GitHub can display them.

`--notify` then comments on the repo's tracking issue (label `x-assets`), @-mentioning the
owner, so GitHub pushes "your posts are ready" to their phone with the previews inline.

Asset kinds, all 1600x900 (X's 16:9, at a resolution that stays sharp on retina):

  daily    today's K4C4 board per sport. Spoiler-free: faces and names, never grades or order.
  answers  yesterday's board revealed, keep and cut, with points. The next morning's post.
  pack     a Week Pack drop card: the week, the boards in it, the lead board's faces.
  game     a pack's game-of-the-week board, the two clubs' crests and colors.

Nothing here posts to X. Publishing to a public account stays a human decision.

    python -m tools.marketing.x_assets --daily 2026-09-16 --answers 2026-09-15 --out build/x
    python -m tools.marketing.x_assets --packs 2026-09-16 --sport nfl --out build/x --publish
"""
from __future__ import annotations

import argparse
import datetime as dt
import io
import json
import os
import pathlib
import re
import urllib.error
import urllib.parse
import urllib.request

from . import brand
from .brand import BLUE, GREEN, INK, MUTED, PAPER, RED, SPORT_FILL, SPORT_NAME, VOLT, WHITE

W, H = 1600, 900
M = 64
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
    return _clamp(headline, "The {sport} {week} Pack just dropped: {boards} boards on the week that just ended, led by {text}.\n\n{link}",
                  sport=SPORT_NAME.get(sport, sport), week=week, boards=boards,
                  link=brand.app_link("x_pack"))


def caption_game(team_a: str, team_b: str) -> str:
    return _clamp(f"{team_a} vs {team_b}", "{text}: who had the better day?\n\n8 players from one game. Keep the best 4.\n\n{link}",
                  link=brand.app_link("x_game"))


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


_TEAMS: dict[str, dict] = {}


def team(sport: str, abbr: str) -> dict:
    """Club identity from the shared `teams` table (logo + primary color), as the app uses."""
    if sport not in _TEAMS:
        _TEAMS[sport] = {}
        try:
            for t in _get(f"teams?select=team_abbr,full_name,logo_url,primary_color&sport=eq.{sport}"):
                _TEAMS[sport].setdefault(t["team_abbr"], t)
        except Exception:  # noqa: BLE001 — identity is decoration, never a reason to fail
            pass
    return _TEAMS[sport].get(abbr, {})


# ── drawing ─────────────────────────────────────────────────────────────────────

_IMAGES: dict[str, object] = {}


def _image(url: str | None):
    from PIL import Image
    if not url:
        return None
    if url not in _IMAGES:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": _UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                im = Image.open(io.BytesIO(r.read()))
                im.load()
                _IMAGES[url] = im.convert("RGBA")
        except Exception:  # noqa: BLE001 — a missing face degrades to initials, not a crash
            _IMAGES[url] = None
    return _IMAGES[url]


def _hex(color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    c = color.lstrip("#")
    return int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16), alpha


def _mix(color: str, toward: str, amount: float) -> str:
    a, b = _hex(color), _hex(toward)
    return "#" + "".join(f"{round(a[i] + (b[i] - a[i]) * amount):02X}" for i in range(3))


def _canvas(bg: str):
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H), bg)
    return img, ImageDraw.Draw(img)


def _initials(name: str) -> str:
    parts = [p for p in re.split(r"\s+", name) if p]
    return (parts[0][:1] + (parts[-1][:1] if len(parts) > 1 else "")).upper()


def _paste_fit(img, im, box, *, bottom=True):
    """Contain `im` inside `box`, centered horizontally, bottom-aligned (cut-out headshots stand
    on the card's floor like the app's card art)."""
    from PIL import Image
    x0, y0, x1, y1 = box
    im = im.copy()
    im.thumbnail((x1 - x0, y1 - y0), Image.LANCZOS)
    x = x0 + (x1 - x0 - im.width) // 2
    y = (y1 - im.height) if bottom else y0 + (y1 - y0 - im.height) // 2
    img.paste(im, (x, y), im)


def _truncate(draw, text: str, f, max_w: int) -> str:
    if brand.text_w(draw, text, f) <= max_w:
        return text
    while text and brand.text_w(draw, text + "…", f) > max_w:
        text = text[:-1]
    return text.rstrip() + "…"


def _tile(img, draw, box, sport: str, player: dict, *, stripe: str | None = None,
          stripe_label: str | None = None, points: bool = False):
    x0, y0, x1, y1 = box
    brand.block(draw, box, WHITE, radius=18, lift=6)
    ident = team(sport, player.get("teamAbbr", ""))
    color = ident.get("primary_color") or SPORT_FILL.get(sport, (BLUE, WHITE))[0]
    name_h = 100 if points else 88
    photo = (x0 + 10, y0 + 10, x1 - 10, y1 - name_h)
    draw.rounded_rectangle(photo, radius=12, fill=_mix(color, WHITE, 0.72))
    face = _image(player.get("headshot"))
    if face is not None:
        _paste_fit(img, face, (photo[0] + 8, photo[1] + 8, photo[2] - 8, photo[3]))
    else:
        cx, cy = (photo[0] + photo[2]) // 2, (photo[1] + photo[3]) // 2
        r = min(photo[2] - photo[0], photo[3] - photo[1]) // 3
        draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color, outline=INK, width=3)
        draw.text((cx, cy), _initials(player.get("name", "")), font=brand.anton(int(r * 0.9)),
                  fill=WHITE, anchor="mm")
    crest = _image(ident.get("logo_url"))
    if crest is not None:
        _paste_fit(img, crest, (photo[2] - 58, photo[1] + 8, photo[2] - 8, photo[1] + 58), bottom=False)
    if stripe:
        brand.chip(draw, photo[0] + 8, photo[1] + 8, stripe_label or "", fill=stripe,
                   ink=WHITE, size=22, pad_x=10, pad_y=4)
    f_name = brand.cond_black(32)
    name = _truncate(draw, player.get("name", ""), f_name, x1 - x0 - 28)
    draw.text((x0 + 14, y1 - name_h + 12), name, font=f_name, fill=INK, anchor="lt")
    sub = player.get("teamAbbr", "")
    if points and player.get("grade") is not None:
        sub = f"{sub}  ·  {player['grade']:.1f} pts"
    # Anchored to the tile's bottom edge with clearance for the ink outline, so the label can
    # never sit on the border whatever the tile height works out to.
    draw.text((x0 + 14, y1 - 16), sub, font=brand.saira_semi(24), fill=MUTED, anchor="ld")


def _footer(draw, *, on_dark: bool = False, ground: str | None = None):
    play, book = (WHITE, VOLT) if on_dark else (INK, BLUE)
    if ground:
        book = brand.accent_on(ground)
    brand.draw_wordmark(draw, M, H - 40, 56, play, book)
    draw.text((W - M, H - 52), "Free on the App Store", font=brand.saira_semi(30),
              fill=WHITE if on_dark else INK, anchor="rs")


def _header(draw, sport: str, label: str):
    fill, ink = SPORT_FILL.get(sport, (BLUE, WHITE))
    right = brand.chip(draw, M, 44, SPORT_NAME.get(sport, sport).upper(), fill=fill, ink=ink, size=30)
    brand.chip(draw, right + 12, 44, label, fill=BLUE, ink=WHITE, size=30)


def _grid(img, draw, top: int, sport: str, players: list[dict], **tile_kw):
    gap = 22
    bottom = H - 104
    tw = (W - 2 * M - 3 * gap) // 4
    th = (bottom - top - gap) // 2
    for i, p in enumerate(players[:8]):
        r, c = divmod(i, 4)
        x0 = M + c * (tw + gap)
        y0 = top + r * (th + gap)
        _tile(img, draw, (x0, y0, x0 + tw, y0 + th), sport, p, **tile_kw)


def _title(draw, text: str, top: int, *, fill=INK, max_lines=1, start=88, floor=54) -> int:
    f, lines = brand.fit(draw, text, brand.anton, W - 2 * M, max_lines, start, floor)
    size = f.size
    for ln in lines:
        draw.text((M, top), ln, font=f, fill=fill, anchor="lt")
        top += int(size * 1.08)
    return top


def render_daily(board: dict):
    img, draw = _canvas(PAPER)
    content = board["content"]
    _header(draw, board["sport"], "TODAY'S K4C4")
    y = _title(draw, _board_title(content["theme"]), 118)
    draw.text((M, y + 2), "Keep the best 4. Cut the rest.", font=brand.saira_semi(34),
              fill=MUTED, anchor="lt")
    players = sorted(content["players"], key=lambda p: p.get("name", ""))   # never grade order
    _grid(img, draw, y + 64, board["sport"], players)
    _footer(draw)
    return img


def render_answers(board: dict):
    img, draw = _canvas(PAPER)
    content = board["content"]
    _header(draw, board["sport"], "YESTERDAY'S ANSWERS")
    y = _title(draw, _board_title(content["theme"]), 118)
    ranked = sorted(content["players"], key=lambda p: -p.get("grade", 0))
    gap, bottom, top = 22, H - 104, y + 26
    tw = (W - 2 * M - 3 * gap) // 4
    th = (bottom - top - gap) // 2
    for i, p in enumerate(ranked[:8]):
        r, c = divmod(i, 4)
        x0, y0 = M + c * (tw + gap), top + r * (th + gap)
        keep = r == 0
        _tile(img, draw, (x0, y0, x0 + tw, y0 + th), board["sport"], p,
              stripe=GREEN if keep else RED, stripe_label="KEEP" if keep else "CUT", points=True)
    _footer(draw)
    return img


def render_pack(pack: dict):
    sport = pack["sport"]
    fill, ink = SPORT_FILL.get(sport, (BLUE, WHITE))
    img, draw = _canvas(fill)
    week = re.sub(r"^\d{4} ", "", pack["label"]).upper()
    draw.text((M, 58), f"{SPORT_NAME.get(sport, sport).upper()}  ·  WEEK PACK", font=brand.cond_black(34),
              fill=ink, anchor="lt")
    f_big, lines = brand.fit(draw, week, brand.anton, 640, 2, 170, 96)
    y = 112
    for ln in lines:
        draw.text((M, y), ln, font=f_big, fill=ink, anchor="lt")
        y += int(f_big.size * 1.02)
    draw.text((M, y), "PACK", font=f_big, fill=brand.accent_on(fill), anchor="lt")
    y += int(f_big.size * 1.08)
    brand.chip(draw, M, y, "JUST DROPPED", fill=VOLT, ink=INK, size=30)
    draw.text((M, y + 70), f"{len(pack['items'])} boards on the week that just ended",
              font=brand.saira_semi(32), fill=ink, anchor="lt")

    # The boards, as the pack screen lists them.
    x0, x1 = 760, W - M
    row_h, gap = 112, 16
    ty = 58
    roles = {"headline": "HEADLINE", "game": "GAME OF THE WEEK", "position": "POSITION",
             "division": "DIVISION", "niche": "DEEP CUT"}
    for item in pack["items"][:5]:
        brand.block(draw, (x0, ty, x1, ty + row_h), WHITE, radius=16, lift=6)
        brand.chip(draw, x0 + 18, ty + 14, roles.get(item["role"], "BONUS"), fill=BLUE, ink=WHITE,
                   size=20, pad_x=10, pad_y=3)
        f = brand.cond_black(38)
        title = _truncate(draw, _board_title(item["content"]["theme"], pack["label"]), f, x1 - x0 - 40)
        draw.text((x0 + 20, ty + 70), title, font=f, fill=INK, anchor="lm")
        ty += row_h + gap

    # The lead board's faces, the most recognizable thing about the week.
    faces = sorted(pack["items"][0]["content"]["players"], key=lambda p: -p.get("grade", 0))[:6]
    r = 44
    fx, fy = M + r, H - 170
    for p in faces:
        draw.ellipse((fx - r, fy - r, fx + r, fy + r), fill=_mix(fill, WHITE, 0.75), outline=INK, width=3)
        face = _image(p.get("headshot"))
        if face is not None:
            from PIL import Image, ImageDraw
            layer = Image.new("RGBA", (2 * r, 2 * r), (0, 0, 0, 0))
            _paste_fit(layer, face, (0, 6, 2 * r, 2 * r))
            mask = Image.new("L", (2 * r, 2 * r), 0)
            ImageDraw.Draw(mask).ellipse((3, 3, 2 * r - 3, 2 * r - 3), fill=255)
            img.paste(layer, (fx - r, fy - r), Image.composite(layer, Image.new("RGBA", layer.size), mask))
        fx += 2 * r + 14
    _footer(draw, on_dark=ink == WHITE, ground=fill)
    return img


def render_game(pack: dict, item: dict):
    sport = pack["sport"]
    img, draw = _canvas(PAPER)
    content = item["content"]
    players = content["players"]
    teams = []
    for p in players:
        if p.get("teamAbbr") and p["teamAbbr"] not in teams:
            teams.append(p["teamAbbr"])
    a, b = (teams + ["", ""])[:2]
    _header(draw, sport, "GAME OF THE WEEK")
    x = M
    for abbr in (a, b):
        crest = _image(team(sport, abbr).get("logo_url"))
        if crest is not None:
            _paste_fit(img, crest, (x, 112, x + 96, 208), bottom=False)
            x += 110
        f = brand.anton(92)
        draw.text((x, 112), abbr, font=f, fill=INK, anchor="lt")
        x += brand.text_w(draw, abbr, f) + 24
        if abbr == a:
            draw.text((x, 150), "vs", font=brand.cond_black(52), fill=MUTED, anchor="lt")
            x += 80
    draw.text((M, 226), "Who had the better day?", font=brand.saira_semi(38), fill=MUTED, anchor="lt")
    ordered = sorted(players, key=lambda p: (p.get("teamAbbr") != a, p.get("name", "")))
    _grid(img, draw, 290, sport, ordered)
    _footer(draw)
    return img, a, b


# ── build ───────────────────────────────────────────────────────────────────────

def _alt_daily(sport: str, theme: str, players: list[dict]) -> str:
    names = ", ".join(p.get("name", "") for p in players)
    return f"Playbook {SPORT_NAME.get(sport, sport)} K4C4 board: {theme}. Eight players: {names}."


def build(out: pathlib.Path, *, daily: str | None, answers: str | None, packs: str | None,
          sport: str | None) -> list[dict]:
    out.mkdir(parents=True, exist_ok=True)
    assets: list[dict] = []

    def save(img, name: str, **meta):
        path = out / name
        img.save(path, "PNG", optimize=True)
        assets.append({"file": name, "width": img.width, "height": img.height, **meta})

    if daily:
        for board in daily_boards(daily):
            if sport and board["sport"] != sport:
                continue
            theme = _board_title(board["content"]["theme"])
            save(render_daily(board), f"daily-{board['sport']}-{daily}.png", kind="daily",
                 sport=board["sport"], date=daily, puzzle_id=board["id"],
                 caption=caption_daily(board["sport"], theme),
                 alt=_alt_daily(board["sport"], theme, board["content"]["players"]))
    if answers:
        for board in daily_boards(answers):
            if sport and board["sport"] != sport:
                continue
            theme = _board_title(board["content"]["theme"])
            ranked = sorted(board["content"]["players"], key=lambda p: -p.get("grade", 0))
            keeps = [p["name"] for p in ranked[:4]]
            save(render_answers(board), f"answers-{board['sport']}-{answers}.png", kind="answers",
                 sport=board["sport"], date=answers, puzzle_id=board["id"],
                 caption=caption_answers(board["sport"], theme, keeps),
                 alt=f"Answers to the {SPORT_NAME.get(board['sport'])} K4C4 board {theme}. "
                     f"Keep: {', '.join(keeps)}. Cut: {', '.join(p['name'] for p in ranked[4:8])}.")
    if packs:
        for pack in packs_for(packs, sport):
            head = _board_title(pack["items"][0]["content"]["theme"], pack["label"])
            save(render_pack(pack), f"pack-{pack['id']}.png", kind="pack", sport=pack["sport"],
                 date=packs, pack_id=pack["id"],
                 caption=caption_pack(pack["sport"], pack["label"], len(pack["items"]), head),
                 alt=f"The {SPORT_NAME.get(pack['sport'])} {pack['label']} Pack: "
                     + "; ".join(_board_title(i["content"]["theme"], pack["label"]) for i in pack["items"]))
            game = next((i for i in pack["items"] if i["role"] == "game"), None)
            if game:
                img, a, b = render_game(pack, game)
                save(img, f"game-{pack['id']}.png", kind="game", sport=pack["sport"], date=packs,
                     pack_id=pack["id"], caption=caption_game(a, b),
                     alt=f"{a} vs {b}: eight players from one game. "
                         + ", ".join(p.get("name", "") for p in game["content"]["players"]))
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


def summary_markdown(assets: list[dict], title: str, run_url: str | None) -> str:
    lines = [f"## {title}", ""]
    if run_url:
        lines += [f"Download every file from the run's **x-assets** artifact: {run_url}", ""]
    for a in assets:
        lines.append(f"### {a['kind'].title()} · {SPORT_NAME.get(a.get('sport', ''), '')} · `{a['file']}`")
        if a.get("url"):
            lines.append(f"![{a['alt'][:120]}]({a['url']})")
        lines += ["", "```text", a["caption"], "```", f"<sub>Alt text: {a['alt']}</sub>", ""]
    return "\n".join(lines)


def notify(assets: list[dict], title: str, run_url: str | None) -> None:
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
        + summary_markdown(assets, title, run_url)
    gh("POST", f"issues/{number}/comments", {"body": body[:64000]})
    print(f"[x] notified on issue #{number}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Render X post assets for what just went live")
    ap.add_argument("--daily", metavar="DATE", help="today's K4C4 board per sport")
    ap.add_argument("--answers", metavar="DATE", help="that day's boards, revealed")
    ap.add_argument("--packs", metavar="DATE", help="Week Packs opening on DATE")
    ap.add_argument("--sport", default=None)
    ap.add_argument("--out", default="build/x-assets")
    ap.add_argument("--publish", action="store_true", help="upload to the public marketing bucket")
    ap.add_argument("--summary", metavar="FILE", help="append a markdown summary (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--notify", action="store_true", help="comment on the x-assets tracking issue")
    ap.add_argument("--title", default="X post assets")
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    assets = build(out, daily=args.daily, answers=args.answers, packs=args.packs, sport=args.sport)
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
    if args.publish:
        publish(out, assets, args.daily or args.packs or args.answers or dt.date.today().isoformat())
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as f:
            f.write(summary_markdown(assets, args.title, run_url) + "\n")
    if args.notify:
        notify(assets, args.title, run_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
