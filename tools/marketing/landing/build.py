"""Builds the Playbook landing page: inlines the app's typefaces + card art as data URIs.

The page is published as a self-contained artifact and hosted alongside privacy.html, and
both destinations block external asset hosts — so nothing may be linked, everything is
embedded. Run: python -m tools.marketing.landing.build
"""
from __future__ import annotations

import base64
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
FONTS = ROOT / "BallIQ" / "Resources" / "Fonts"
OUT = ROOT / "index.html"

# ── Where the site lives ──────────────────────────────────────────────────────
# The one place the public origin is written down. It reaches the canonical link,
# og:url, og:image, twitter:image and the JSON-LD block in the template, plus the
# generated robots.txt and sitemap.xml -- eight places that were previously eight
# separate hardcoded strings, which is how a domain move turns into a hunt.
#
# Moving to a custom domain is this line plus a CNAME file plus DNS; nothing in the
# template needs touching. Keep the trailing slash: the template concatenates onto it.
SITE = "https://xmevans10.github.io/fantasy-app/"

# Card art, downscaled to 240px squares. Kept in-repo so a rebuild doesn't re-hit the
# original hosts (and so the page never depends on them staying up).
SHOTS = HERE / "shots"

# Raw simulator captures of the real app, not re-creations. Regenerate with:
#   xcodebuild -scheme BallIQ -destination 'platform=iOS Simulator,id=<udid>' \
#              -derivedDataPath build-shots build
#   xcrun simctl install <udid> build-shots/Build/Products/Debug-iphonesimulator/BallIQ.app
#   xcrun simctl launch <udid> com.balliqfantasy.app -screenshotGame   # see DebugLaunch.swift
#   xcrun simctl io <udid> screenshot raw/game.png
#   cwebp -q 76 raw/game.png -resize 680 0 -o shots/game.webp
#   (`-resize 680 0` sets the WIDTH and derives height. sips' `-Z` scales the LONGEST
#    side instead, which left a portrait capture 303px wide -- soft at 1x on the ~320px
#    display box. WebP over JPEG is 196KB vs 692KB across the eight screens, and any
#    browser that can render an iOS-17 landing page has supported it for years.)
#
# Two capture gotchas, both hit on 2026-08-18:
#   * Leagues and the Versus ladder AUTO-PRESENT their "How it works" sheet on first visit
#     (`shouldAutoPresent`), which covers the screen. Launch the flag twice -- the second
#     capture has the real surface.
#   * Leagues has no signed-out content at all, so it has no usable marketing capture.
SHOTS_USED = ["game", "result", "home", "whoami", "overunder", "draftspin", "grid", "ladder"]

def data_uri(path: pathlib.Path, mime: str) -> str:
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"


def main() -> int:
    html = (HERE / "template.html").read_text()
    for token, name in [("__ANTON__", "Anton-Regular"),
                        ("__SAIRA_COND_BLACK__", "SairaCondensed-Black"),
                        ("__SAIRA_REGULAR__", "Saira-Regular"),
                        ("__SAIRA_SEMIBOLD__", "Saira-SemiBold")]:
        html = html.replace(token, data_uri(FONTS / f"{name}.ttf", "font/ttf"))

    for name in SHOTS_USED:
        html = html.replace(f"__SHOT_{name.upper()}__",
                            data_uri(SHOTS / f"{name}.webp", "image/webp"))

    html = html.replace("__SITE__", SITE)

    for leftover in ["__ANTON__", "__SAIRA", "__SHOT_", "__SITE__"]:
        assert leftover not in html, f"unsubstituted token {leftover}"

    html = _asciify(html)
    assert html.isascii(), "output still carries non-ASCII"
    OUT.write_text(html, encoding="ascii")
    print(f"wrote {OUT} ({len(html.encode()) / 1024:.0f} KB)")

    # Crawler files, generated rather than hand-maintained, so they cannot drift from
    # SITE the way three hand-edited copies of a URL always eventually do.
    (ROOT / "robots.txt").write_text(
        "User-agent: *\nAllow: /\n\nSitemap: " + SITE + "sitemap.xml\n", encoding="ascii")
    (ROOT / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        f'  <url><loc>{SITE}</loc><changefreq>weekly</changefreq><priority>1.0</priority></url>\n'
        f'  <url><loc>{SITE}privacy.html</loc><changefreq>yearly</changefreq><priority>0.3</priority></url>\n'
        '</urlset>\n', encoding="ascii")
    print(f"wrote robots.txt + sitemap.xml for {SITE}")
    return 0


def _asciify(html: str) -> str:
    r"""Render every non-ASCII character as an escape, so the page can't mojibake.

    The page has no `<meta charset>` of its own -- as an Artifact it is wrapped in someone
    else's `<head>`, and self-hosted it may be served by anything. A plain `python -m
    http.server` sends `text/html` with no charset at all, which turned every em dash into
    mojibake on the first render. Escaping sidesteps the question entirely: ASCII decodes
    identically under every encoding a server might declare or omit.

    Markup and script need different escapes -- an HTML entity inside a `<script>` block is
    NOT decoded, it would print literally -- so the script is escaped as JS `\uXXXX` and
    everything around it as `&#NNN;`. Only non-ASCII characters are touched; backslashes,
    newlines and quotes in the script are left exactly as written.
    """
    head, sep, tail = html.partition("<script>")
    head = head.encode("ascii", "xmlcharrefreplace").decode("ascii")
    if sep:
        tail = "".join(c if ord(c) < 128 else f"\\u{ord(c):04x}" for c in tail)
    return head + sep + tail


if __name__ == "__main__":
    raise SystemExit(main())
