# Playbook — Social Media Starter Kit

Everything needed to stand up a Playbook presence on any major platform from a cold start.
Generated from the app's own design system, so it can't drift from the product.

**App:** Playbook (App Store listing name "BallIQ - Fantasy") · `com.balliqfantasy.app`
**Tagline:** Prove you know ball.
**Support/privacy:** https://xmevans10.github.io/fantasy-app/privacy.html

---

## What's in here

| Folder | What it is |
|---|---|
| `01-logo/` | Wordmark in every ground + mono, PNG and SVG. Vertical lockups with the tagline. |
| `02-avatars/` | Square profile pictures, pre-cut to each platform's exact size. |
| `03-headers/` | Cover/banner art per platform, correct pixel dimensions. |
| `04-post-templates/` | Ready-to-post creative + empty blanks in every aspect ratio. |
| `05-brand/` | Palette swatch sheet. Full rules in `BRAND.md`. |
| `_source/` | The generator and the screenshots it composites. Not for upload. |
| `BRAND.md` | Colors, type, logo rules, do/don't. |
| `COPY.md` | Bios, taglines, launch posts, hashtags — per platform, within character limits. |

Regenerate everything after any brand change:

```bash
python3 marketing/social-kit/_source/generate.py
```

---

## Platform cheat sheet

Sizes verified current as of 2026-08-25. Where a platform crops the avatar to a circle,
the square file is still what you upload — see `02-avatars/PREVIEW-ONLY-circle-crop-check-400x400.png`
to confirm the mark survives the mask.

| Platform | Avatar | Header / cover | Post sizes | File to use |
|---|---|---|---|---|
| **X / Twitter** | 400×400 | 1500×500 | 1200×675 (16:9), 1200×630 card | `playbook-avatar-400x400-x-profile.png`, `x-twitter-header-1500x500.png` |
| **Instagram** | 320×320 (upload 800×800) | — none — | 1080×1080, 1080×1350, 1080×1920 story | `playbook-avatar-800x800-x-instagram-source.png` |
| **TikTok** | 200×200 (upload 320×320) | — none — | 1080×1920 | `playbook-avatar-320x320-tiktok.png` |
| **YouTube** | 800×800 | 2560×1440, **safe area 1546×423** | 1280×720 thumb | `youtube-channel-art-2560x1440.png` |
| **Facebook Page** | 170×170 display (upload 180×180) | 1640×624 | 1200×630 | `facebook-page-cover-1640x624.png` |
| **LinkedIn Company** | 300×300 (min 150) | 1128×191, newer 1128×376 | 1200×627 | `linkedin-company-banner-1128x191.png` |
| **LinkedIn Personal** | 400×400 | 1584×396 | — | `linkedin-personal-banner-1584x396.png` |
| **Reddit** | 256×256 (96 works) | 1920×384 | — | `reddit-banner-1920x384.png` |
| **Discord** | 128×128 | 960×540 server banner | — | `discord-server-banner-960x540.png` |
| **Twitch** | 256×256 | 1200×380 profile banner | — | `twitch-profile-banner-1200x380.png` |
| **Threads** | inherits Instagram | — none — | 1080×1350 | Instagram files |
| **Bluesky** | 400×400 | 3000×1000 (use the X header, it upscales cleanly) | 1200×630 | X files |
| **Email / newsletter** | — | 1200×300 | — | `email-newsletter-header-1200x300.png` |

**Dark variants** exist for the two headers most likely to sit against a dark UI:
`x-twitter-header-1500x500-dark.png`, `youtube-channel-art-2560x1440-dark.png`.

**Safe-area guides** in `03-headers/_safe-area-guides/` show YouTube's and Facebook's crop
zones with a red box. Those are reference only — **do not upload a file with `-GUIDE` in
the name.**

---

## Known gaps — decide before launch

Stated plainly rather than quietly omitted:

1. **No video.** Reels/TikTok/Shorts are video-first and this kit is static only. The
   highest-leverage next asset is a 10–15s screen recording of a Puzzle Blitz run — the
   clock ticking down while boards change is the app's most watchable moment. Capture with
   `xcrun simctl io <udid> recordVideo`.
2. **No app-icon variants.** The avatar is the shipping app icon at every size. If you want a
   social-specific mark (e.g. wordmark-in-a-square rather than the "P"), that's a design
   decision, not a generation one.
3. **Handles aren't reserved.** `COPY.md` lists the handle set to claim; nothing here does it.
4. **The App Store screenshots are separate** and currently need work — see
   `../APP-STORE-SCREENSHOT-AUDIT.md`. Don't reuse them in social posts until they're refreshed;
   three of the six show an anonymous helmet where a player's face should be.
