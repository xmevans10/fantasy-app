#!/usr/bin/env python3
"""Generates every raster asset in the Playbook social kit.

Everything here is derived from the app's own design system — the Prime Time palette in
`BallIQ/DesignSystem/Theme.swift` and the OFL fonts vendored at `BallIQ/Resources/Fonts/`
— so the kit cannot drift from the product. Re-run after any brand change:

    python3 marketing/social-kit/_source/generate.py

Idempotent: every file is rewritten from scratch, so re-running is always safe.
"""

import pathlib
import subprocess

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[3]
KIT = ROOT / "marketing" / "social-kit"
FONTS = ROOT / "BallIQ" / "Resources" / "Fonts"
APP_ICON = ROOT / "BallIQ" / "Assets.xcassets" / "AppIcon.appiconset" / "Icon-1024.png"

# ---------------------------------------------------------------- palette
# Verbatim from Theme.swift's light scheme. Hex, not names, because a social kit is handed
# to people who don't have the Swift file.
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

FORMATS = [
    ("K4C4", BLUE, WHITE),
    ("WHO AM I?", VOLT, ON_VOLT),
    ("JOURNEYMAN", GOLD, ON_VOLT),
    ("OVER / UNDER", RED, WHITE),
    ("PUZZLE BLITZ", GREEN, WHITE),
]

TAGLINE = "Prove you know ball."
SUBLINE = "Daily sports puzzles built from real stat lines."


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / name), size)


def cond_black(size):  return font("SairaCondensed-Black.ttf", size)
def cond_bold(size):   return font("SairaCondensed-Bold.ttf", size)
def saira(size):       return font("Saira-Regular.ttf", size)
def saira_semi(size):  return font("Saira-SemiBold.ttf", size)
def anton(size):       return font("Anton-Regular.ttf", size)


def out(rel: str) -> pathlib.Path:
    p = KIT / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def save(img: Image.Image, rel: str) -> None:
    p = out(rel)
    img.save(p, "PNG", optimize=True)
    print(f"  {rel}  ({img.width}x{img.height})")


def text_w(draw, s, f):
    return draw.textbbox((0, 0), s, font=f)[2]


# ---------------------------------------------------------------- wordmark
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


# ---------------------------------------------------------------- 01 logo
def build_logo():
    print("01-logo/")
    variants = [
        ("playbook-wordmark-on-paper", PAPER, INK, BLUE),
        ("playbook-wordmark-on-ink", INK, PAPER, VOLT),
        ("playbook-wordmark-on-blue", BLUE, WHITE, VOLT),
        ("playbook-wordmark-mono-black", None, INK, INK),
        ("playbook-wordmark-mono-white", None, WHITE, WHITE),
    ]
    size = 220
    for name, bg, play, book in variants:
        probe = ImageDraw.Draw(Image.new("RGBA", (10, 10)))
        w = wordmark_width(probe, size)
        pad = size // 2
        img = Image.new("RGBA", (w + pad * 2, int(size * 1.5)),
                        bg if bg else (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        draw_wordmark(d, pad, int(size * 1.05), size, play, book)
        save(img, f"01-logo/{name}.png")

    # Vertical lockup: wordmark over tagline, for square-ish placements.
    for name, bg, play, book, tag in [
        ("playbook-lockup-vertical-on-paper", PAPER, INK, BLUE, INK),
        ("playbook-lockup-vertical-on-ink", INK, PAPER, VOLT, PAPER),
    ]:
        img = Image.new("RGB", (1200, 630), bg)
        d = ImageDraw.Draw(img)
        s = 150
        w = wordmark_width(d, s)
        draw_wordmark(d, (1200 - w) // 2, 330, s, play, book)
        d.text((600, 390), TAGLINE, font=saira(40), fill=tag, anchor="ma")
        save(img, f"01-logo/{name}.png")


def build_svg_logos():
    """SVG wordmarks. Text is converted to paths at build time via rsvg is not available for
    that, so these reference the family by name with a real fallback stack — fine for web use
    where the fonts are loaded, and the PNGs above cover everything else."""
    print("01-logo/ (svg)")
    for name, play, book in [
        ("playbook-wordmark-mono-black", INK, INK),
        ("playbook-wordmark-mono-white", WHITE, WHITE),
        ("playbook-wordmark-colour", INK, BLUE),
    ]:
        svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 520 150" width="520" height="150">
  <title>Playbook wordmark</title>
  <text x="0" y="112" font-family="Saira Condensed, Arial Narrow, sans-serif"
        font-weight="700" font-size="128" fill="{play}">play</text>
  <text x="238" y="112" font-family="Saira Condensed, Arial Narrow, sans-serif"
        font-weight="900" font-size="128" fill="{book}">book</text>
</svg>'''
        out(f"01-logo/{name}.svg").write_text(svg)
        print(f"  01-logo/{name}.svg")


# ---------------------------------------------------------------- 02 avatars
AVATAR_SIZES = {
    1024: "master",
    800: "x-instagram-source",
    400: "x-profile",
    320: "tiktok",
    180: "facebook",
    170: "facebook-display",
    150: "linkedin-min",
    128: "discord",
    96: "reddit",
    64: "favicon-large",
    32: "favicon",
}


def build_avatars():
    print("02-avatars/")
    base = Image.open(APP_ICON).convert("RGB")
    for px, label in AVATAR_SIZES.items():
        img = base.resize((px, px), Image.LANCZOS)
        save(img, f"02-avatars/playbook-avatar-{px}x{px}-{label}.png")

    # Circle-cropped preview so you can check the mark survives the circular mask every
    # platform applies. Not for upload — platforms want the square.
    px = 400
    img = base.resize((px, px), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (px, px), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, px, px), fill=255)
    circ = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    circ.paste(img, (0, 0), mask)
    save(circ, "02-avatars/PREVIEW-ONLY-circle-crop-check-400x400.png")


# ---------------------------------------------------------------- banners
def banner(w, h, *, safe=None, mark_scale=0.20, tagline=True, chips=True,
           ground=PAPER, play=INK, book=BLUE, tag_fill=MUTED):
    """The shared banner composition: wordmark, tagline, and the format cartridge row —
    the app's own chip language, so the banner reads as the product and not as clip art.

    `safe` is a (w, h) centred region that must contain everything (YouTube's 1546x423).
    """
    img = Image.new("RGB", (w, h), ground)
    d = ImageDraw.Draw(img)

    sw, sh = safe if safe else (w, h)
    cx, cy = w // 2, h // 2

    s = max(28, int(sh * mark_scale * 2.0))
    mw = wordmark_width(d, s)
    # Shrink to fit the safe width with margin.
    while mw > sw * 0.62 and s > 24:
        s -= 4
        mw = wordmark_width(d, s)

    baseline = cy - int(sh * (0.02 if (tagline or chips) else -0.15))
    draw_wordmark(d, cx - mw // 2, baseline, s, play, book)

    y = baseline + int(s * 0.30)
    if tagline:
        ts = max(13, int(s * 0.20))
        d.text((cx, y), SUBLINE, font=saira(ts), fill=tag_fill, anchor="ma")
        y += int(ts * 2.0)

    if chips:
        cs = max(11, int(s * 0.115))
        f = cond_black(cs)
        padx, pady, gap = int(cs * 0.85), int(cs * 0.5), int(cs * 0.7)
        widths = [text_w(d, n, f) + padx * 2 for n, _, _ in FORMATS]
        total = sum(widths) + gap * (len(FORMATS) - 1)
        # Drop chips from the right until the row fits the safe area.
        shown = list(FORMATS)
        while total > sw * 0.94 and len(shown) > 1:
            shown = shown[:-1]
            widths = [text_w(d, n, f) + padx * 2 for n, _, _ in shown]
            total = sum(widths) + gap * (len(shown) - 1)
        x = cx - total // 2
        ch = cs + pady * 2
        for (name, fill, on), cw in zip(shown, widths):
            d.rounded_rectangle((x, y, x + cw, y + ch), radius=int(ch * 0.32),
                                fill=fill, outline=INK, width=2)
            d.text((x + cw // 2, y + ch // 2), name, font=f, fill=on, anchor="mm")
            x += cw + gap
    return img


BANNERS = [
    # (rel path, w, h, safe area or None)
    ("03-headers/x-twitter-header-1500x500.png", 1500, 500, None),
    ("03-headers/linkedin-company-banner-1128x191.png", 1128, 191, None),
    ("03-headers/linkedin-company-banner-1128x376.png", 1128, 376, None),
    ("03-headers/linkedin-personal-banner-1584x396.png", 1584, 396, None),
    ("03-headers/youtube-channel-art-2560x1440.png", 2560, 1440, (1546, 423)),
    ("03-headers/facebook-page-cover-1640x624.png", 1640, 624, (1090, 400)),
    ("03-headers/reddit-banner-1920x384.png", 1920, 384, None),
    ("03-headers/discord-server-banner-960x540.png", 960, 540, None),
    ("03-headers/twitch-profile-banner-1200x380.png", 1200, 380, None),
    ("03-headers/email-newsletter-header-1200x300.png", 1200, 300, None),
]


def build_banners():
    print("03-headers/")
    for rel, w, h, safe in BANNERS:
        img = banner(w, h, safe=safe)
        save(img, rel)
        if safe:
            g = img.copy()
            d = ImageDraw.Draw(g)
            sw, sh = safe
            x0, y0 = (w - sw) // 2, (h - sh) // 2
            d.rectangle((x0, y0, x0 + sw, y0 + sh), outline=RED, width=6)
            d.text((x0 + 14, y0 + 12), f"SAFE AREA {sw}x{sh} — DO NOT UPLOAD THIS FILE",
                   font=cond_black(26), fill=RED)
            save(g, rel.replace("03-headers/", "03-headers/_safe-area-guides/")
                       .replace(".png", "-GUIDE.png"))

    # Dark variants of the two most-used headers.
    for rel, w, h in [("03-headers/x-twitter-header-1500x500-dark.png", 1500, 500),
                      ("03-headers/youtube-channel-art-2560x1440-dark.png", 2560, 1440)]:
        safe = (1546, 423) if w == 2560 else None
        save(banner(w, h, safe=safe, ground=INK, play=PAPER, book=VOLT, tag_fill="#9A9484"), rel)


# ---------------------------------------------------------------- post templates
SCREENS = pathlib.Path(__file__).parent / "screens"


def phone(screenshot: str, target_h: int) -> Image.Image:
    """A screenshot in a rounded ink-outlined phone body — the same hard-edged frame the
    app's own `blockCard` uses, so the device reads as part of the brand rather than as a
    stock mockup."""
    shot = Image.open(SCREENS / screenshot).convert("RGB")
    bezel = max(8, target_h // 90)
    inner_h = target_h - bezel * 2
    inner_w = int(shot.width * inner_h / shot.height)
    shot = shot.resize((inner_w, inner_h), Image.LANCZOS)

    w, h = inner_w + bezel * 2, target_h
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = int(w * 0.085)
    d.rounded_rectangle((0, 0, w - 1, h - 1), r, fill=INK)

    mask = Image.new("L", (inner_w, inner_h), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, inner_w - 1, inner_h - 1), max(2, r - bezel), fill=255)
    img.paste(shot, (bezel, bezel), mask)
    return img


def post_template(w, h, headline, kicker, *, ground=BLUE, headline_fill=WHITE,
                  accent=VOLT, footer=True, screenshot=None):
    img = Image.new("RGB", (w, h), ground)
    d = ImageDraw.Draw(img)
    m = int(w * 0.085)

    ks = max(16, int(w * 0.028))
    d.text((m, m), kicker.upper(), font=cond_black(ks), fill=accent)

    hs = int(w * 0.115)
    f = anton(hs)
    words, lines, cur = headline.upper().split(), [], ""
    for wd in words:
        t = (cur + " " + wd).strip()
        if text_w(d, t, f) > w - m * 2 and cur:
            lines.append(cur); cur = wd
        else:
            cur = t
    lines.append(cur)
    y = m + ks * 2.4
    for ln in lines:
        d.text((m, y), ln, font=f, fill=headline_fill)
        y += hs * 1.02

    fs = max(15, int(w * 0.026))
    fy = h - m - fs * 1.6

    if screenshot:
        # Fill the space between the headline and the footer with the real app.
        avail = int(fy - y - m * 0.6)
        if avail > 120:
            ph = phone(screenshot, avail)
            if ph.width > w - m * 2:
                ph = ph.resize((w - m * 2, int(ph.height * (w - m * 2) / ph.width)),
                               Image.LANCZOS)
            img.paste(ph, ((w - ph.width) // 2, int(y + m * 0.3)), ph)

    if footer:
        draw_wordmark(d, m, int(fy + fs * 1.5), int(fs * 1.9), WHITE, accent)
        d.text((w - m, fy + fs * 0.5), "On the App Store", font=saira(fs),
               fill="#FFFFFFB0", anchor="ra")
    return img


POSTS = [
    ("04-post-templates/square-1080x1080-instagram-feed.png", 1080, 1080,
     "Four new puzzles. Every day.", "playbook · daily", "blitz-setup.png"),
    ("04-post-templates/portrait-1080x1350-instagram-feed.png", 1080, 1350,
     "Name him from his clubs.", "journeyman", "journeyman-soccer.png"),
    ("04-post-templates/story-1080x1920-reels-tiktok-shorts.png", 1080, 1920,
     "Five minutes. Every format. One score.", "puzzle blitz", "blitz-clock.png"),
    ("04-post-templates/link-preview-1200x630-og-x-card.png", 1200, 630,
     "Prove you know ball.", "playbook", None),
    ("04-post-templates/square-1080x1080-alt-volt.png", 1080, 1080,
     "No score until the clock stops.", "puzzle blitz", "blitz-result.png"),
]


def build_posts():
    print("04-post-templates/")
    for rel, w, h, head, kick, shot in POSTS:
        if "alt-volt" in rel:
            img = post_template(w, h, head, kick, ground=VOLT, headline_fill=INK,
                                accent=BLUE, screenshot=shot)
        else:
            img = post_template(w, h, head, kick, screenshot=shot)
        save(img, rel)

    # A blank of each size, so there's something to drop a screenshot into.
    for rel, w, h in [("04-post-templates/_blanks/blank-square-1080x1080.png", 1080, 1080),
                      ("04-post-templates/_blanks/blank-portrait-1080x1350.png", 1080, 1350),
                      ("04-post-templates/_blanks/blank-story-1080x1920.png", 1080, 1920),
                      ("04-post-templates/_blanks/blank-link-1200x630.png", 1200, 630)]:
        img = Image.new("RGB", (w, h), BLUE)
        d = ImageDraw.Draw(img)
        m = int(w * 0.085)
        fs = max(15, int(w * 0.026))
        draw_wordmark(d, m, h - m, int(fs * 1.9), WHITE, VOLT)
        save(img, rel)


def build_swatches():
    print("05-brand/")
    sw, rows = 300, len(FORMATS) + 3
    img = Image.new("RGB", (sw * 4, 150 * rows // 4 + 150), PAPER)
    palette = [("BLUE / accent", BLUE, WHITE), ("VOLT / accent-accent", VOLT, INK),
               ("INK / text", INK, PAPER), ("PAPER / ground", PAPER, INK),
               ("GOLD / journeyman", GOLD, INK), ("RED / over-under", RED, WHITE),
               ("GREEN / blitz", GREEN, WHITE), ("PURPLE / pro", PURPLE, WHITE)]
    img = Image.new("RGB", (1200, 640), PAPER)
    d = ImageDraw.Draw(img)
    d.text((40, 36), "PLAYBOOK — PALETTE", font=cond_black(38), fill=INK)
    x, y = 40, 110
    for name, hexv, on in palette:
        block(d, (x, y, x + 260, y + 150), hexv, radius=12, lift=6)
        d.text((x + 18, y + 96), hexv.upper(), font=cond_black(26), fill=on)
        d.text((x + 18, y + 124), name.upper(), font=saira(15), fill=on)
        x += 285
        if x > 1000:
            x, y = 40, y + 180
    save(img, "05-brand/palette-swatches.png")


def main():
    print(f"Writing Playbook social kit -> {KIT}\n")
    build_logo()
    build_svg_logos()
    build_avatars()
    build_banners()
    build_posts()
    build_swatches()
    n = sum(1 for _ in KIT.rglob("*") if _.is_file())
    print(f"\nDone. {n} files in {KIT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
