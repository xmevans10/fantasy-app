"""The reusable X series: evergreen posts that are true on any day, rendered once.

Where `x_assets.py` makes the posts about today's boards, these are the ones you reach for
between drops: how each format plays, what Week Packs are, the App Store ask, a streak nudge,
a reply card, and one card per sport. Written into the social kit (`06-x-series/`) by the kit's
own generator, so "regenerate everything after a brand change" is still one command:

    python3 marketing/social-kit/_source/generate.py

Every rule stated on a card is lifted from docs/BALLIQ_SPEC.md, not paraphrased from memory:
a how-to card that misdescribes the game is worse than no card. Hockey and F1 get no sport
card yet: they are not visible in the app until `validate.WIRE_SAFE_SPORTS` opens for them.
"""
from __future__ import annotations

import pathlib

from . import brand
from .brand import BLUE, GOLD, GREEN, INK, MUTED, PAPER, PURPLE, RED, SPORT_FILL, SPORT_NAME, VOLT, WHITE

W, H = 1600, 900
M = 72

FORMATS = {
    "k4c4": ("K4C4", BLUE, WHITE, "Keep 4. Cut 4.", [
        "Eight real players, one card at a time.",
        "Keep the four with the best fantasy points. Cut the rest.",
        "Every call is final. Hard mode hides the stats.",
    ]),
    "who-am-i": ("WHO AM I?", VOLT, INK, "Name him in as few clues as you can.", [
        "Six clues about one mystery player.",
        "They start vague and get specific.",
        "Solve it early for the most points.",
    ]),
    "journeyman": ("JOURNEYMAN", GOLD, INK, "Name the player from his clubs.", [
        "Every club he played for, in order, from the start.",
        "Five guesses to name him.",
        "The sooner you get it, the more it pays.",
    ]),
    "the-grid": ("THE GRID", PURPLE, WHITE, "Nine cells. One player each.", [
        "A three by three board of teams and decades.",
        "Name a player who fits both for every cell.",
        "Rare answers are the ones worth bragging about.",
    ]),
    "puzzle-blitz": ("PUZZLE BLITZ", GREEN, WHITE, "One clock. Every format.", [
        "Pick one, three or five minutes.",
        "Real boards back to back, from the sports you choose.",
        "No score until the clock stops.",
    ]),
}


def _canvas(bg):
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (W, H), bg)
    return img, ImageDraw.Draw(img)


def _footer(d, *, dark=False, ground: str | None = None):
    book = brand.accent_on(ground) if ground else (VOLT if dark else BLUE)
    brand.draw_wordmark(d, M, H - 48, 60, WHITE if dark else INK, book)
    d.text((W - M, H - 60), "Free on the App Store", font=brand.saira_semi(32),
           fill=WHITE if dark else INK, anchor="rs")


def howto(key: str):
    name, fill, ink, hook, steps = FORMATS[key]
    img, d = _canvas(PAPER)
    brand.chip(d, M, 64, "HOW TO PLAY", fill=INK, ink=PAPER, size=30)
    f, lines = brand.fit(d, name, brand.anton, 640, 2, 150, 90)
    y = 140
    for ln in lines:
        d.text((M, y), ln, font=f, fill=INK, anchor="lt")
        y += int(f.size * 1.02)
    f_hook, hook_lines = brand.fit(d, hook, brand.saira_semi, 620, 3, 44, 30)
    for ln in hook_lines:
        d.text((M, y + 20), ln, font=f_hook, fill=MUTED, anchor="lt")
        y += int(f_hook.size * 1.3)
    # The steps are a real sequence, so they are numbered.
    x0, x1, top, gap = 780, W - M, 70, 28
    row = (H - 150 - top - 2 * gap) // 3
    for i, step in enumerate(steps):
        y0 = top + i * (row + gap)
        brand.block(d, (x0, y0, x1, y0 + row), WHITE, radius=18, lift=7)
        d.rounded_rectangle((x0 + 24, y0 + 24, x0 + 112, y0 + row - 24), radius=14, fill=fill,
                            outline=INK, width=3)
        d.text((x0 + 68, y0 + row // 2), str(i + 1), font=brand.anton(64), fill=ink, anchor="mm")
        f_step, step_lines = brand.fit(d, step, brand.cond_black, x1 - x0 - 170, 2, 46, 32)
        sy = y0 + row // 2 - (len(step_lines) * f_step.size * 1.1) / 2
        for ln in step_lines:
            d.text((x0 + 140, sy), ln, font=f_step, fill=INK, anchor="lt")
            sy += f_step.size * 1.1
    _footer(d)
    return img


def week_packs():
    img, d = _canvas(BLUE)
    brand.chip(d, M, 64, "NEW", fill=VOLT, ink=INK, size=32)
    d.text((M, 140), "WEEK", font=brand.anton(210), fill=WHITE, anchor="lt")
    d.text((M, 360), "PACKS", font=brand.anton(210), fill=VOLT, anchor="lt")
    d.text((M, 610), "When a league's week ends, a batch of", font=brand.saira_semi(40), fill=WHITE, anchor="lt")
    d.text((M, 662), "boards about it drops the next day.", font=brand.saira_semi(40), fill=WHITE, anchor="lt")
    rows = [("HEADLINE", "The week's top performances"), ("GAME OF THE WEEK", "Who had the better day?"),
            ("POSITION", "Top performances at one position"), ("DIVISION", "One division's best"),
            ("DEEP CUT", "Something only the week could make")]
    x0, x1, y, h, gap = 860, W - M, 70, 118, 20
    for role, text in rows:
        brand.block(d, (x0, y, x1, y + h), WHITE, radius=16, lift=6)
        brand.chip(d, x0 + 20, y + 16, role, fill=BLUE, ink=WHITE, size=22, pad_x=10, pad_y=3)
        d.text((x0 + 22, y + 82), text, font=brand.cond_black(38), fill=INK, anchor="lm")
        y += h + gap
    _footer(d, dark=True)
    return img


def sport_card(sport: str):
    fill, ink = SPORT_FILL[sport]
    name = SPORT_NAME[sport]
    img, d = _canvas(fill)
    d.text((M, 70), f"KNOW {name.upper()}?", font=brand.anton(170), fill=ink, anchor="lt")
    d.text((M, 270), "PROVE IT.", font=brand.anton(170), fill=brand.accent_on(fill), anchor="lt")
    d.text((M, 500), f"Daily {name} puzzles built from real stat lines.", font=brand.saira_semi(42),
           fill=ink, anchor="lt")
    x = M
    for label, chip_fill, chip_ink in (("K4C4", BLUE, WHITE), ("WHO AM I?", VOLT, INK),
                                       ("JOURNEYMAN", GOLD, INK), ("THE GRID", PURPLE, WHITE)):
        if sport == "tennis" and label == "JOURNEYMAN":
            continue               # a tour player has a nationality, not a club history
        x = brand.chip(d, x, 590, label, fill=chip_fill, ink=chip_ink, size=34) + 16
    _footer(d, dark=ink == WHITE, ground=fill)
    return img


def cta():
    img, d = _canvas(INK)
    d.text((W // 2, 250), "FREE ON THE", font=brand.anton(120), fill=WHITE, anchor="mm")
    d.text((W // 2, 400), "APP STORE", font=brand.anton(170), fill=VOLT, anchor="mm")
    d.text((W // 2, 540), brand.SUBLINE, font=brand.saira_semi(44), fill=PAPER, anchor="mm")
    w = brand.wordmark_width(d, 110)
    brand.draw_wordmark(d, (W - w) // 2, 760, 110, WHITE, VOLT)
    return img


def quote():
    img, d = _canvas(VOLT)
    d.text((M, 170), "PROVE YOU", font=brand.anton(230), fill=INK, anchor="lt")
    d.text((M, 420), "KNOW BALL.", font=brand.anton(230), fill=INK, anchor="lt")
    _footer(d)
    return img


def streak():
    img, d = _canvas(PAPER)
    brand.chip(d, M, 64, "STREAK CHECK", fill=RED, ink=WHITE, size=32)
    d.text((M, 150), "Don't let a Tuesday", font=brand.anton(140), fill=INK, anchor="lt")
    d.text((M, 310), "end your streak.", font=brand.anton(140), fill=RED, anchor="lt")
    d.text((M, 500), "Today's boards are waiting.", font=brand.saira_semi(48), fill=MUTED, anchor="lt")
    _footer(d)
    return img


def reply_square():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (1080, 1080), BLUE)
    d = ImageDraw.Draw(img)
    d.text((540, 380), "KEEP", font=brand.anton(250), fill=WHITE, anchor="mm")
    d.text((540, 560), "OR", font=brand.anton(120), fill=VOLT, anchor="mm")
    d.text((540, 740), "CUT?", font=brand.anton(250), fill=WHITE, anchor="mm")
    w = brand.wordmark_width(d, 70)
    brand.draw_wordmark(d, (1080 - w) // 2, 1010, 70, WHITE, VOLT)
    return img


SPORTS = ("nfl", "nba", "baseball", "soccer", "tennis")


def build(out_dir: pathlib.Path, save) -> None:
    """`save(img, rel_path)` is the kit generator's own writer, so these land and log exactly
    like everything else in the kit."""
    for key in FORMATS:
        save(howto(key), f"06-x-series/how-to-play-{key}-1600x900.png")
    save(week_packs(), "06-x-series/feature-week-packs-1600x900.png")
    for sport in SPORTS:
        save(sport_card(sport), f"06-x-series/sport-{sport}-1600x900.png")
    save(cta(), "06-x-series/cta-app-store-1600x900.png")
    save(quote(), "06-x-series/quote-prove-you-know-ball-1600x900.png")
    save(streak(), "06-x-series/streak-nudge-1600x900.png")
    save(reply_square(), "06-x-series/reply-keep-or-cut-1080x1080.png")
