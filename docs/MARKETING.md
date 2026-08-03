# Playbook — platform marketing plans (drafted 2026-07-18, refreshed 2026-07-31)

Written right after the 1.3 monetization + Grid-parity release. Everything here leans on
mechanics the app already ships — no plan below requires new product work except where
flagged **[product]**. Solo-founder effort budgets are honest; each plan states what "week
one" actually looks like and the one number that tells you it's working.

**Where things actually stand, 2026-07-31:** 1.3 is now `READY_FOR_SALE` (build 21, confirmed
live via the ASC API — it sat in review for the two weeks this plan assumed as prep time). NFL
kickoff is **~5 weeks out**, which lines up almost exactly with this plan's own "week 3-4 /
training camp" checkpoint below — that's where to start, not week 1. Three `[product]`
candidates flagged below have shipped since the original draft and are crossed off: the
**ratings prompt** (`ReviewPrompter`, fires after an Immaculate Grid or a streak milestone —
Keep4/Grid result views), the **App Store link appended to share text** (`ShareMessage.swift`),
and **Draft & Spin/Daily Draft's own share surface** (an image card via `ShareLink`, not the
Grid's emoji-text format specifically — the underlying gap this item named, "no share path at
all," is closed; a literal 🟩⬛ emoji variant for Draft & Spin is still a distinct, smaller
`[product]` item if wanted). Still genuinely open: the @playbookdaily account itself (nobody's
created it yet), and "community puzzle of the week" surfacing (author attribution exists in
Community — "by @username" — but no featured/weekly-pick mechanism).

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
result is slot 2 — the flex screen is the conversion screen). **Rotated 2026-07-31** to a
training-camp line ("NFL training camp is here — every roster since 1999 is in the Grid...")
via the ASC API — no review required for promo-text changes.

**Ongoing cadence:**
- Rotate promotional text with the sports calendar (it needs no review): NFL kickoff week
  ("Every roster since 1999 is in here"), NBA opening night, March Madness, transfer windows.
- Seasonal screenshot slot: swap slot 1's Home for the in-season sport's daily card each
  season change (one sim capture + one API call — the flow is scripted in tools/release/).
- ~~Ratings prompt~~ **[product] — shipped**: `ReviewPrompter` requests review after an
  Immaculate Grid or a qualifying streak (Keep4/Grid result views) — the two moments of
  maximum pride.
- In-app events on the product page (ASC supports these via API): "NFL Kickoff Grid Week."
- **KPI:** App Store page conversion rate (Analytics → App Store) before/after each rotation.

## 5. The daily-share loop itself (cross-platform glue)

- The share sheet is the whole funnel: every result screen should be one tap from a post.
  Grid has text+emoji; Keep4/Draft & Spin have share cards (image-based `ShareLink`, already
  shipped). **[product] candidate, smaller than originally scoped:** a literal 🟩⬛
  emoji-text variant for Draft & Spin/Daily Draft, matching the Grid's format exactly.
- Push notifications (live since 1.2) are the streak engine — streaks are what people post.
- Community creators are marketers: a fan who builds "Saints legends" shares it to Saints
  spaces for you. Author attribution already surfaces ("by @username", tappable to profile) —
  still open **[product]:** a featured "community puzzle of the week" in the app + on
  @playbookdaily (nothing picks or highlights one today).

## 6. Trend-awareness follow list (for the automated reply/reactive-post engine)

Who to follow for "know about it within the hour" sports-news coverage — this is what feeds
the trend-detection pass that drafts reactive posts/replies. **Verify each handle at setup
time** — insider roles shift (e.g. beat-writer moves between outlets aren't rare), this list
is a starting point, not a guarantee.

**X — insiders/wire (per-league news as it breaks):**
- NFL: `@AdamSchefter` (ESPN), `@RapSheet` (Ian Rapoport, NFL Network)
- NBA: `@ShamsCharania` (ESPN)
- MLB: `@JeffPassan` (ESPN), `@Ken_Rosenthal`
- Soccer: `@FabrizioRomano` (transfers)
- League/wire accounts: `@NFL`, `@NBA`, `@MLB`, `@ESPN`, `@BleacherReport`
- Tour accounts (tennis has fewer single insiders): `@ATPTour`, `@WTA`

**X — tonal/genre-adjacent (stats culture, direct peers):**
- `@StatMuse`, `@OptaJoe` (soccer stats) — the "here's a wild stat" format is close to our
  own crowd-rarity bit.
- `@immaculategrid` — the actual Immaculate Grid account. Watch for format/timing patterns;
  bantering with them (in-voice, not derivative) is fair game, copying their exact bit isn't.

**Reddit — subreddits to monitor** (following isn't the right primitive here; these are the
communities to watch/search for trending threads): r/nfl, r/nba, r/baseball, r/soccer,
r/tennis, r/sports, r/fantasyfootball (seasonal, Aug-Sep), r/SideProject and r/apple (for our
own launch-story threads, not sports news), plus the specific team subreddit whenever that
team's the daily Grid/Keep4 subject.

---

## Sequencing for a solo founder

*(Updated 2026-07-31 — 1.3's review took the two weeks this table originally budgeted for
weeks 1-2, so start here at "training camp," not at week 1.)*

| When | Do | Skip for now |
|------|-----|-------------|
| Now (training camp, ~5wk out) | @playbookdaily live, daily board post scheduled; append store link to share text (already shipped in-app — just start posting); first two play-along TikToks; r/SideProject launch story | Paid ads (nothing to optimize yet), Discord (no community to fill it) |
| +1-2 weeks | Team-sub question threads on Grid days; promo-text rotation for NFL training camp (see docs/marketing-content-drafts.md for draft copy) | Influencer outreach (wait for kickoff) |
| Sep (NFL kickoff) | The big push: kickoff-week promo text + screenshots, creator collabs with 2-3 mid-size NFL trivia TikTokers, daily posting everywhere | |

The NFL season opener is the moment — every plan above is rehearsal until then, and the
weekly data pipeline (fresh rosters/stats each Tuesday) means the app is *provably current*
right when the audience shows up.

Ready-to-post copy for the "now" column lives in
[marketing-content-drafts.md](marketing-content-drafts.md).
