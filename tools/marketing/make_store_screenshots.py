#!/usr/bin/env python3
"""Composite raw simulator captures into App Store marketing panels.

Raw captures are unframed app screens — good verification artifacts, bad store listings.
This wraps each one in a branded panel: headline, subhead, wordmark, and a hard-shadowed
device frame that bleeds off the bottom edge, using the app's own type and palette
(BallIQ/DesignSystem/{Typography,Theme}.swift) so the product page reads as the product.

    python3 tools/marketing/make_store_screenshots.py --raw <dir> --out <dir>

Output is 1290x2796 (APP_IPHONE_67). Pass --size ipad for 2064x2752 (APP_IPAD_PRO_3GEN_129).
"""
from __future__ import annotations

import argparse
import os
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONTS = os.path.join(REPO, "BallIQ", "Resources", "Fonts")

# Theme.swift tokens.
INK = (0x15, 0x12, 0x0B)
CREAM = (0xF4, 0xF1, 0xE9)
VOLT = (0xC2, 0xF0, 0x3A)
BLUE = (0x1E, 0x50, 0xFF)
WHITE = (0xFF, 0xFF, 0xFF)
MUTED_ON_LIGHT = (0x57, 0x50, 0x3F)
MUTED_ON_DARK = (0xCF, 0xC8, 0xB8)

DEVICE_CORNER = 78  # visual match to the iPhone 17 Pro Max capture's own corner radius
MAX_HEADLINE_LINES = 2


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(os.path.join(FONTS, name), size)


SHADOW_STROKE, SHADOW_OFFSET = 8, 20
# rounded_shadowed() grows the image by the ink border on both sides plus the shadow offset.
SHADOW_PAD = SHADOW_STROKE * 2 + SHADOW_OFFSET


def rounded_shadowed(shot: Image.Image, width: int, corner: int) -> Image.Image:
    """Scale `shot` to `width`, round its corners, and lay it on a hard offset shadow."""
    scale = width / shot.width
    shot = shot.resize((width, round(shot.height * scale)), Image.LANCZOS).convert("RGBA")

    mask = Image.new("L", shot.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height - 1],
                                           radius=corner, fill=255)
    shot.putalpha(mask)

    # Hard (un-blurred) offset shadow + ink stroke — the app's own card treatment.
    stroke, offset = SHADOW_STROKE, SHADOW_OFFSET
    canvas = Image.new("RGBA", (shot.width + stroke * 2 + offset,
                                shot.height + stroke * 2 + offset), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    d.rounded_rectangle([offset, offset, offset + shot.width + stroke * 2 - 1,
                         offset + shot.height + stroke * 2 - 1],
                        radius=corner + stroke, fill=INK + (255,))
    d.rounded_rectangle([0, 0, shot.width + stroke * 2 - 1, shot.height + stroke * 2 - 1],
                        radius=corner + stroke, fill=INK + (255,))
    canvas.alpha_composite(shot, (stroke, stroke))
    return canvas


def draw_wordmark(d: ImageDraw.ImageDraw, cx: int, y: int, size: int,
                  base: tuple, accent: tuple) -> None:
    f = font("Saira-ExtraBold.ttf", size)
    w1 = d.textlength("play", font=f)
    w2 = d.textlength("book", font=f)
    x = cx - (w1 + w2) / 2
    d.text((x, y), "play", font=f, fill=base)
    d.text((x + w1, y), "book", font=f, fill=accent)


def panel(raw_path: str, headline: list[str], subhead: str, bg: tuple,
          fg: tuple, accent: tuple, muted: tuple, size: tuple[int, int]) -> Image.Image:
    W, H = size
    img = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(img)

    # Type scales off the canvas *height*, not its width. The vertical rhythm below is all
    # H-relative, so sizing type off W only stays in proportion at the iPhone aspect ratio —
    # on the squarer iPad canvas it inflated the copy block until the device overlapped the
    # subhead. TYPE is the width an iPhone panel of this height would have, which keeps the
    # 6.7" output identical while giving the iPad correct proportions.
    TYPE = H * (1290 / 2796)

    margin = round(W * 0.075)
    y = round(H * 0.037)

    draw_wordmark(d, W // 2, y, round(TYPE * 0.043), fg, accent)
    y += round(TYPE * 0.083)

    # Headline — condensed black caps, tight leading, optically centered.
    hsize = round(TYPE * 0.101)
    fh = font("SairaCondensed-Black.ttf", hsize)
    while max(d.textlength(line.upper(), font=fh) for line in headline) > W - margin * 2:
        hsize -= 4
        fh = font("SairaCondensed-Black.ttf", hsize)
    # The headline block always reserves MAX_LINES of height, so a one-line panel drops its
    # subhead and device at the same y as a two-line one and the carousel scrolls evenly.
    leading = round(hsize * 0.94)
    for line in headline:
        d.text((W // 2, y), line.upper(), font=fh, fill=fg, anchor="ma")
        y += leading
    y += leading * (MAX_HEADLINE_LINES - len(headline))

    y += round(H * 0.022)
    fs = font("Saira-Regular.ttf", round(TYPE * 0.0345))
    d.text((W // 2, y), subhead, font=fs, fill=muted, anchor="ma")
    y += round(TYPE * 0.0345) + round(H * 0.018)

    # The device sits fully inside the canvas — size it to whatever height is left over
    # after the copy block, capped so it never grows wider than the safe margins. Both the
    # cap and the shadow padding matter: rounded_shadowed() returns an image taller than the
    # screenshot itself, so sizing to the bare aspect ratio overflows `avail_h` and the
    # centring offset goes negative, dragging the device up over the subhead.
    raw = Image.open(raw_path)
    avail_h = H - y - round(H * 0.045)
    width = min(round(W * 0.70),
                round((avail_h - SHADOW_PAD) * raw.width / raw.height))
    device = rounded_shadowed(raw, width, DEVICE_CORNER)
    img.paste(device, ((W - device.width) // 2, y + max(0, avail_h - device.height) // 2),
              device)
    return img


# One background across the whole set, so the six panels read as a single run in the
# product-page carousel and the screenshots themselves supply the colour variety.
SUBTLE = (0xD5, 0xDE, 0xFF)
PANELS = [
    dict(raw="01_home.png",
         headline=["Four new puzzles.", "Every day."],
         subhead="NFL, NBA, MLB, soccer and tennis — built from real stat lines."),
    dict(raw="02_gridresult.png",
         headline=["The 3x3 that", "settles it."],
         subhead="Team by decade. Nine cells. Every roster since 1999."),
    dict(raw="03_keep4.png",
         headline=["Keep 4. Cut 4.", "No do-overs."],
         subhead="Ten real seasons, one hidden stat, sorted blind."),
    dict(raw="04_draftspin.png",
         headline=["Spin a roster.", "Sim the season."],
         subhead="Random team-and-year slots. Draft, then watch it play out."),
    dict(raw="05_whoami.png",
         headline=["Six clues.", "One player."],
         subhead="Guess early, score higher. Clues pull from thirty-odd angles."),
    dict(raw="06_overunder.png",
         headline=["Over or under?"],
         subhead="Three lives, real stat lines. How long can you last?"),
]

SIZES = {"iphone": (1290, 2796), "ipad": (2064, 2752)}


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--raw", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--size", default="iphone", choices=SIZES)
    args = p.parse_args()

    os.makedirs(args.out, exist_ok=True)
    for i, spec in enumerate(PANELS, start=1):
        img = panel(os.path.join(args.raw, spec["raw"]), spec["headline"], spec["subhead"],
                    BLUE, WHITE, VOLT, SUBTLE, SIZES[args.size])
        dest = os.path.join(args.out, f"{i:02d}_{spec['raw'].split('_', 1)[1]}")
        img.save(dest)
        print("wrote", dest, img.size)


if __name__ == "__main__":
    main()
