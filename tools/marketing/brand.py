"""Playbook's visual language for generated marketing art: one copy, shared.

Used by the social kit generator (`marketing/social-kit/_source/generate.py`, static assets)
and by `x_assets.py` (per-mint X posts rendered in GitHub Actions). Both used to need these
primitives; keeping two copies is how a palette change lands in one and not the other.

Every value mirrors the app rather than approximating it: hexes are Theme.swift's light scheme
and the per-sport band colors are `Sport.cardFill` (pinned by `test_x_assets.py`, which parses
Theme.swift), and the fonts are the OFL files the app itself ships in BallIQ/Resources/Fonts.

Needs Pillow, which is NOT a dependency of the stdlib-only ingest runtime. Workflows that
render install it for that step only.
"""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
FONTS = ROOT / "BallIQ" / "Resources" / "Fonts"

# ── palette (Theme.swift, light scheme) ─────────────────────────────────────────
PAPER = "#F4F1E9"
INK = "#15120B"
BLUE = "#1E50FF"      # accentFill  — dominant
VOLT = "#C2F03A"      # voltFill    — accent-accent, spend once
GOLD = "#E0A92E"      # goldFill    — Journeyman
RED = "#E63A2E"       # dangerFill  — Over/Under
GREEN = "#18A957"     # successFill — Puzzle Blitz
PURPLE = "#6D3BF5"    # proFill     — The Grid
ON_VOLT = "#15120B"
WHITE = "#FFFFFF"
MUTED = "#7B7666"

# `Sport.cardFill` / `Sport.onCardFill`: the band color every daily card is drawn in.
SPORT_FILL: dict[str, tuple[str, str]] = {
    "nfl": ("#1B7A43", WHITE),
    "nba": ("#FF5A1E", WHITE),
    "baseball": ("#D62839", WHITE),
    "soccer": ("#0EA5A4", WHITE),
    "tennis": ("#E8B400", INK),
    "hockey": ("#1C4E80", WHITE),
    "f1": ("#B5179E", WHITE),
}
SPORT_NAME: dict[str, str] = {
    "nfl": "NFL", "nba": "NBA", "baseball": "MLB", "soccer": "Soccer",
    "tennis": "Tennis", "hockey": "NHL", "f1": "F1",
}

TAGLINE = "Prove you know ball."
SUBLINE = "Daily sports puzzles built from real stat lines."
APP_STORE_ID = "6785275045"


def app_link(campaign: str) -> str:
    """The App Store link with an App Analytics campaign token, matching `ShareMessage.storeURL`
    in the app so installs from X posts and from in-app shares land in the same report."""
    return f"https://apps.apple.com/app/id{APP_STORE_ID}?ct={campaign}"


# ── type ─────────────────────────────────────────────────────────────────────────
def font(name: str, size: int):
    # Imported here, not at module top, so the palette and link helpers stay importable where
    # Pillow is absent (the stdlib-only CI test job reads SPORT_FILL for its parity check).
    from PIL import ImageFont
    return ImageFont.truetype(str(FONTS / name), size)


def cond_black(size):  return font("SairaCondensed-Black.ttf", size)
def cond_bold(size):   return font("SairaCondensed-Bold.ttf", size)
def saira(size):       return font("Saira-Regular.ttf", size)
def saira_semi(size):  return font("Saira-SemiBold.ttf", size)
def saira_bold(size):  return font("Saira-ExtraBold.ttf", size)
def anton(size):       return font("Anton-Regular.ttf", size)


def text_w(draw, s, f):
    return draw.textbbox((0, 0), s, font=f)[2]


def wrap(draw, text: str, f, max_w: int) -> list[str]:
    """Greedy word wrap to `max_w` pixels."""
    words, lines, cur = text.split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if cur and text_w(draw, t, f) > max_w:
            lines.append(cur)
            cur = wd
        else:
            cur = t
    if cur:
        lines.append(cur)
    return lines


def fit(draw, text: str, make_font, max_w: int, max_lines: int, start: int, floor: int):
    """The largest size (from `start` down to `floor`) at which `text` wraps into at most
    `max_lines` lines of `max_w`. Returns (font, lines)."""
    size = start
    while True:
        f = make_font(size)
        lines = wrap(draw, text, f, max_w)
        # Width too, not just line count: a single word never wraps, so "JOURNEYMAN" at 150px
        # passed a lines-only check while running straight into the next column.
        fits = len(lines) <= max_lines and all(text_w(draw, ln, f) <= max_w for ln in lines)
        if fits or size <= floor:
            return f, lines[:max_lines]
        size -= 4


# ── marks ────────────────────────────────────────────────────────────────────────
def draw_wordmark(draw, x, y, size, play_color, book_color, anchor="ls"):
    """'play' in condensed bold + 'book' in condensed black — the app's `Wordmark` view,
    reproduced exactly (same two faces, same two colors, lowercase, zero tracking)."""
    fb, fk = cond_bold(size), cond_black(size)
    draw.text((x, y), "play", font=fb, fill=play_color, anchor=anchor)
    w = draw.textbbox((0, 0), "play", font=fb)[2]
    draw.text((x + w, y), "book", font=fk, fill=book_color, anchor=anchor)
    return w + draw.textbbox((0, 0), "book", font=fk)[2]


def wordmark_width(draw, size):
    return (draw.textbbox((0, 0), "play", font=cond_bold(size))[2]
            + draw.textbbox((0, 0), "book", font=cond_black(size))[2])


def block(draw, box, fill, radius=14, lift=7, outline=INK, width=3):
    """The app's `blockCard()` — hard ink outline on a solid offset shadow."""
    x0, y0, x1, y1 = box
    draw.rounded_rectangle((x0 + lift, y0 + lift, x1 + lift, y1 + lift), radius, fill=INK)
    draw.rounded_rectangle(box, radius, fill=fill, outline=outline, width=width)


def chip(draw, x, y, text, *, fill, ink, size=26, pad_x=14, pad_y=6, outline=INK):
    """A capsule label like the app's header-band badges. Returns its right edge."""
    f = cond_black(size)
    w = text_w(draw, text, f)
    h = int(size * 1.25)
    draw.rounded_rectangle((x, y, x + w + pad_x * 2, y + h + pad_y), radius=(h + pad_y) // 2,
                           fill=fill, outline=outline, width=2)
    draw.text((x + pad_x, y + (h + pad_y) // 2), text, font=f, fill=ink, anchor="lm")
    return x + w + pad_x * 2



def contrast(a: str, b: str) -> float:
    """WCAG contrast ratio between two hex colors."""
    def lum(h):
        h = h.lstrip("#")
        rgb = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
        lin = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
        return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    hi, lo = sorted((lum(a), lum(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def accent_on(ground: str, candidates=(VOLT, INK, BLUE)) -> str:
    """The accent that reads best on `ground`, by measured contrast rather than taste."""
    return max(candidates, key=lambda c: contrast(c, ground))
