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
| `06-x-series/` | Evergreen X posts (1600×900): how-to-play per format, Week Packs, one card per sport, App Store ask, streak nudge, a keep-or-cut reply square, and real K4C4 cards rendered by the app itself (`BallIQTests/XCardGalleryTests`). |
| `_source/` | The generator and the screenshots it composites. Not for upload. |
| `BRAND.md` | Colors, type, logo rules, do/don't. |
| `COPY.md` | Bios, taglines, launch posts, hashtags — per platform, within character limits. |

**Daily X posts are not in this folder: they are minted with the puzzles** (`x-assets.yml`
after every `daily-puzzle` and `fresh-drop` run). Each one is a **thread built to be answered
in the replies**, in a format sports and fantasy X already plays, not an ad for the app:

| Format | The post | The reveal |
|---|---|---|
| Blind résumé | Two stat lines from one published board, names hidden, a star in the pair and the lines close. "Player A or Player B?" | Same panels unmasked, better line marked |
| Keep 4 | Today's board as a readable table (only when 3+ names are ones people know). "Reply with your four." | The four keeps, next day |
| Name the player | Today's Journeyman path as big crests (easy/medium only). | The name, next day |
| Who Am I? | Text only: clue 1 in the post, one clue per reply. | The name after the last clue |

The store link always goes in the **first reply**, never the post (X throttles posts with
links). No crowd numbers until `game_results` has the volume to back them. Every thread is laid
out in posting order in `captions.md` (run artifact) and `captions.txt` (Drive). Images are drawn
by `BallIQTests/XPostRenderTests` from `tools/marketing/x_assets.py`'s spec. Nothing is posted to
X automatically.

### Google Drive

Every asset is also filed into the shared Drive folder, organized for posting:

```
Daily posts/2026-09 September/2026-09-16 Wednesday/   NFL - Blind resume.png, NFL - Blind resume (reveal).png, NFL - Keep 4.png,
                                                      NFL - Name the player.png, captions.txt (every thread, in posting order)
Week Packs/NFL/2026 Week 01/                           Keep 4.png, captions.txt
Evergreen/How to play | Sports | K4C4 cards | Brand/  synced from 06-x-series/ whenever it changes
```

Uploads go through a tiny Apps Script web app that runs as the folder's owner
(`tools/marketing/drive_upload.gs`), so no Google credential is stored in GitHub and a leaked
secret can only add files to that one folder. One-time setup:

1. [script.google.com](https://script.google.com) → **New project**, name it *Playbook X assets*.
   Replace `Code.gs` with the contents of `tools/marketing/drive_upload.gs`.
2. **Project Settings → Script properties**: add `ROOT_FOLDER_ID` (the Drive folder's id) and
   `UPLOAD_TOKEN` (the value of `DRIVE_UPLOAD_TOKEN` in `tools/marketing/.env`).
3. **Deploy → New deployment → Web app**. Execute as **Me**, Who has access **Anyone**. Authorize,
   then copy the **Web app URL** (ends in `/exec`).
4. Add the two GitHub secrets:
   `gh secret set DRIVE_UPLOAD_URL --repo xmevans10/fantasy-app` (the URL) and
   `gh secret set DRIVE_UPLOAD_TOKEN --repo xmevans10/fantasy-app` (the token).
5. Run the **x-evergreen-sync** workflow once to fill `Evergreen/`.

Until the secrets exist the Drive step logs "not configured" and the run carries on.

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
