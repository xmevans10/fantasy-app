# Playbook — platform marketing plans (drafted 2026-07-18)

Written right after the 1.3 monetization + Grid-parity release. Everything here leans on
mechanics the app already ships — no plan below requires new product work except where
flagged **[product]**. Solo-founder effort budgets are honest; each plan states what "week
one" actually looks like and the one number that tells you it's working.

**The assets we're marketing with:**
- A shared daily board (everyone plays the same Grid/Keep4/Draft) — the Wordle social contract.
- The 🟩⬛ emoji share-grid — a result you can post without spoiling the answers.
- Crowd rarity ("3% picked him") — the deep-cut flex that gives Immaculate Grid its culture.
- Community puzzle creation — fans of any team can make content for their own niche.
- Five sports incl. soccer/tennis (underserved in trivia), full Spanish localization.

---

## 1. X/Twitter — the share-grid's native habitat

**Why here first:** Wordle and Immaculate Grid both grew almost entirely off emoji-grid
posts in replies and quote-tweets. Sports Twitter already has the daily-argument habit; the
share text we ship (`Playbook Grid — NFL 2026-07-17 / 🟩🟩⬛…`) is built for it.

**Plan:**
- Create @playbookdaily. Every morning (~8am ET, after the 09:00 UTC mint… note the mint is
  05:00 ET, so the board is always live by post time) post the day's Grid teams/decades as
  text + one provocative cell ("name a JAX 1990s player — 74% of you can't").
- Post your own real share-grid daily. Streaks and failures both — failure posts outperform.
- Reply-guy strategy: when a player is trending (trade, retirement, big game), post the
  historical Grid cell he'd answer. 10 minutes/day, evergreen.
- Ask one question per week that the app can answer ("most-picked SEA 2020s answer was
  Darnold at 41%. Would've been your pick?") — crowd-rarity data is content nobody else has.
- **KPI:** share-grid posts by accounts that aren't yours, per week. >10/wk = it's alive.
- **[product] candidate:** append the App Store short-link to the share text once (Immaculate
  Grid does; Wordle famously didn't and won anyway — test it for a week and watch installs).

## 2. TikTok / Reels / Shorts — one vertical video, three platforms

**Why:** sports-trivia challenge formats ("name 5 players who…") are a proven genre with
huge organic reach, and nobody owns the "daily grid" format on video yet.

**Plan (2 formats, film both in one weekly hour):**
- *Play-along:* screen-record the daily Grid with voiceover, pause before each guess:
  "MIN 2010s, easy… LAC 1990s, oh no." Cut at the last cell, CTA "today's board is in the
  app — can you go 9-for-9?" 60-90s, post the same file to TikTok/Reels/Shorts.
- *Rarity flex:* "Only 2% of players got this cell. Here's the guy they picked." 20s,
  ends on the crowd-rarity screen — the % reveal is the retention hook.
- Duet/stitch bait: post a board and ask sports-TikTok to fill one cell in comments.
- Es-language versions of the same formats (the app is fully localized — LatAm fútbol
  TikTok is enormous and the soccer catalog has 38 leagues).
- **KPI:** completion rate on play-alongs; installs tagged to the link-in-bio day-over-day.

## 3. Reddit — credibility, not ads

**Why:** Reddit hates marketing but loves (a) genuinely useful daily games and (b) honest
build stories. Immaculate Grid spread through team subreddits organically.

**Plan:**
- Launch story posts (one each, spaced out): r/SideProject / r/iOSProgramming ("solo-built a
  sports trivia app — the data pipeline ingests every NFL roster since 1999"), r/apple's
  weekly app thread. These convert developers/early adopters and are allowed self-promo.
- Team-subreddit seeding, the honest way: when the daily Grid features a team, post the
  cell as a *question* in that team's sub ("name a Jags 1990s player without looking") and
  mention the app only when asked / in a comment. Game-thread culture answers trivia
  questions compulsively.
- r/fantasyfootball during draft season (Aug-Sep): Keep4's "rank these RB seasons" maps
  exactly onto draft-prep arguments. One themed post/week.
- **KPI:** one team-sub thread/week that gets >50 comments without being removed.

## 4. App Store (ASO) — compounding, already half-done

Done this release: subtitle ("Daily Grid, Trivia & Arcade"), keyword set with grid/streak/
arcade, promo text touting the Grid update, 6 fresh screenshots per device (Grid immaculate
result is slot 2 — the flex screen is the conversion screen).

**Ongoing cadence:**
- Rotate promotional text with the sports calendar (it needs no review): NFL kickoff week
  ("Every roster since 1999 is in here"), NBA opening night, March Madness, transfer windows.
- Seasonal screenshot slot: swap slot 1's Home for the in-season sport's daily card each
  season change (one sim capture + one API call — the flow is scripted in tools/release/).
- Ratings prompt **[product]**: request review after an Immaculate Grid or a 7-day streak —
  the two moments of maximum pride. Not shipped yet; highest-ROI product-marketing item.
- In-app events on the product page (ASC supports these via API): "NFL Kickoff Grid Week."
- **KPI:** App Store page conversion rate (Analytics → App Store) before/after each rotation.

## 5. The daily-share loop itself (cross-platform glue)

- The share sheet is the whole funnel: every result screen should be one tap from a post.
  Grid has text+emoji; Keep4/Draft & Spin have share cards. **[product] candidate:** add the
  emoji-grid share to Daily Draft results (same pattern, one afternoon).
- Push notifications (live since 1.2) are the streak engine — streaks are what people post.
- Community creators are marketers: a fan who builds "Saints legends" shares it to Saints
  spaces for you. Surface creator attribution more prominently **[product]** and feature a
  "community puzzle of the week" in the app + on @playbookdaily.

---

## Sequencing for a solo founder

| Week | Do | Skip for now |
|------|-----|-------------|
| 1 | @playbookdaily live, daily board post scheduled; append store link to share text | Paid ads (nothing to optimize yet) |
| 2 | First two play-along TikToks; r/SideProject launch story | Discord server (no community to fill it) |
| 3-4 | Team-sub question threads on Grid days; promo-text rotation for NFL training camp | Influencer outreach (wait for NFL kickoff) |
| Sep (NFL kickoff) | The big push: kickoff-week promo text + screenshots, creator collabs with 2-3 mid-size NFL trivia TikTokers, daily posting everywhere | |

The NFL season opener is the moment — every plan above is rehearsal until then, and the
weekly data pipeline (fresh rosters/stats each Tuesday) means the app is *provably current*
right when the audience shows up.
