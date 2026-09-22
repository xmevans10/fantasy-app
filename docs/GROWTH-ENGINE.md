# Playbook growth engine

An algo-aligned, agent-executable plan to grow @_Playbook_ on X. This is the living reference;
`docs/MARKETING.md` is the broader solo-founder plan and `prompts/HANDOFF-growth-agent.md` the
operating manual. Everything here is automatable from the CLI and GitHub Actions, and ships dark.

> **Status:** post engine live (build 55 era; media via OAuth1). Calibration + reply scorer
> landing now. Auto-posting gated behind repo variables `X_AUTOPOST` / `X_MEDIA`.

---

## 1. Objective & the one metric that matters

Get @_Playbook_ from ~0 to a self-sustaining loop: **impressions → installs → retained players**.
At N≈8 players nothing optimizes, so the goal is *reach* first.

Two KPIs, in order:
1. **Weighted engagement per post** — the algorithm's own objective (§2), measured on our posts.
2. **Owner notifications → installs** — the store link is tagged `ct=x_*`; count click-throughs.

---

## 2. The X algorithm, as published (these are facts, not folklore)

X open-sourced the For You feed: `github.com/xai-org/x-algorithm`. Production parameter defaults
live in `home-mixer/params/param.rs` (synced 2026-09-21). Score = **Σ (weight × predicted
probability of each action)**, then three adjustments.

**Positive weights** (multiply the *predicted* probability, not raw counts):

| action | weight | | action | weight |
|---|---|---|---|---|
| share via copy link | **20.0** | | retweet | 1.0 |
| reply | **5.0** | | like | 0.5 |
| reply, mutual-follow original | **+15.0** | | click | 0.4 |
| quote | 5.0 | | open link | 0.2 |
| share via DM | 5.0 | | video open | 0.07 |
| follow author | 4.0 | | photo expand / dwell | 0.05 |
| share | 2.0 | | profile click / vqv | 0.0 |

**Negative weights** (brutal, and why we never bait):
not-interested **−43.2**, block **−31.2**, mute **−58.8**, report **−234.0**, not-dwelled −0.02.

**Structural adjustments:**
- **Out-of-network discount 0.75** — content from accounts the viewer doesn't follow is multiplied
  down (and in-network replies/reposts too via rescore).
- **New-author boost** — authors under ~1,000 impressions are lifted toward slot ~15–16
  (`ColdStartImpressionThreshold=1000`, `ColdStartSlotMin/Max=15/16`, follower cap 1000).
- **Author diversity** — each post after your first in a feed slot is ×0.5, floor 0.25. → *space
  posts, don't dump.*
- **Age filter 48h** — nothing older is recommended.
- No link penalty appears in the weights. The "links kill reach" story is not in the code.

`docs/BIDIRECTIONAL_BOOST_CHANGE.md` in that repo is a worked example of how a param changed over
time; treat this table as a snapshot and re-sync periodically (`--sync-algo`, §6).

**On Articles / long-form:** the published ranking params contain **no article-specific weight**.
Claims that X "pushes Articles" are unverified against the open code; do not build strategy on it
until it appears in `param.rs` or an announcement.

---

## 3. Strategy derived from the weights

1. **Originals over replies.** Replies to non-mutuals are 0.75-discounted and buried under
   siblings; our **original** board posts qualify for the new-author lift. Replies are seasoning.
2. **Optimize for the two top actions:** *share via copy link* (20) and *reply* (5). Our formats
   are literally argue-with-me (K4C4) and share-me (emoji grid) — lean into both:
   - put the **emoji share grid** in reach (the artifact people copy);
   - end boards with a question ("Reply with your four.") to farm replies.
3. **Never farm negatives.** No engagement-bait, no wrong-team bait, no injuries/tragedy/politics.
   Mute (−58.8) and report (−234) end reach faster than any boost fixes it.
4. **Space posts.** Author-diversity decay means 3 posts in one window reach fewer people than 3
   spaced an hour apart.
5. **Reply early, not to viral-but-old.** Reach on a reply is a timing+competition problem: be in
   the first replies on a post that is *rising*, on a topic we can add something true to.
6. **Dwell is real.** Legible images + readable stat lines (our cards) earn dwell; walls of text
   don't.

---

## 3.1 What wins — reverse-engineered from real replies (2026-09-22)

Studied the top replies across `@PFTCommenter`, `@BallsackSports`, `@NBAMemes`, `@statmuse`,
`@BarstoolSports`, `@OldTakesExposed` (root posts excluded; 27 replies).

- **Specificity wins.** The single biggest non-root reply in the sample was a pure fact the post
  omitted: *"JSN 337 yards, 3 TD performance vs Utah in the Rose Bowl…"* — **138 likes, 16,244
  impressions**. Numbers appear in ~42% of replies with ≥25 likes.
- **Confident takes, not questions.** *"Too bad Klay is washed and is more like 2014 Ray Allen, not
  D Wade"* (115 likes); *"Those Rams jerseys are atrocious"* (80). Questions are a minority
  (~20–25%) and rarely the winner.
- **Voice, measured:** median ~90 characters; **normal capitalization** (0% all-caps); emoji ~15%.
- **The conversation is the product.** Many winners reply to *other repliers*, escalating an
  argument — that is the reply weight compounding.
- **Insider references** signal tribe (PFT/PMT in-jokes).
- **Reach is still concentrated:** most replies in a 100+ reply thread stay under ~2K impressions.
  Targeting (fresh + low-competition) and volume still govern; content only decides who breaks out.

**What this means for us — our unique edge.** A catalog of verified player/season stats *is* the
winning pattern. The highest-value Playbook reply: match a player or team named in the post, pull
one specific, surprising stat we can vouch for, and state it with a take. Deterministic and honest
(we never invent numbers); the LLM only shapes the phrasing. This should be Phase 1.5, before wiring
auto-replies.

**Cost note (2026-09-22):** the study and the workflows consumed the account's $5 of X API credits;
reads now return **402** until topped up. Budget the loop — reply-targeting reads are the expensive
part, so run them on a cadence, not continuously.

---

## 3.2 Curated accounts (follow + reply), and why following matters

`tools/marketing/x_replies.py` holds the list (`--list-accounts`). Categories have distinct jobs:

| category | accounts | job |
|---|---|---|
| `reply_news` | Schefter, Shams, Pelissero, RapSheet, NFL, NBA, MLB, ESPN, SportsCenter, BleacherReport | the news wire — reply early to breaking posts |
| `reply_banter` | PFTCommenter, BallsackSports, NBAMemes, BarstoolSports, OldTakesExposed, SportsMemes, TimelessSports | where wit actually lands; the studied winners live here |
| `reply_stats` | statmuse, OptaSTATS, ESPNStatsInfo, ClutchPoints, HoopCentral, TheNBACentral, DovKleiman | our register; fact-drop replies fit |
| `follow_candidates` | SharpFootball, PFF, FantasyLife, UnderdogNFL, SleeperHQ, FieldYates, minakimes, TheCheckdown, Nate_Tice | mid-tier, in-niche — **follow to seek mutuals** |
| `niche` | NHL, ESPNFC, F1, ATPTour, OptaJoe, TSN_Sports, Sportsnet | sports the app differentiates in (hockey/F1/soccer/tennis) |
| `competitors` | immaculategrid, Sporcle, SleeperHQ, UnderdogFantasy, PuzzGrid | study only — never reply-spam |

**Why follow at all:** the reply weight is 5, and **+15 when the author mutually follows you**
(§2). Big accounts never follow back, but mid-tier `follow_candidates` might — so following them is
the cheapest way to turn a 5-weight reply into a 20-weight one. `x_replies --follow` does it via the
API (`POST /2/users/:id/following`, OAuth1), **capped at 5/run and ledger-deduped**, because mass
following is exactly the inauthentic-behaviour signal X's `bdsm` model looks for. Default is a
dry-run preview. Handles resolve at runtime; a bad one is skipped.

---

## 4. Architecture

```
tools/marketing/
  x_algo.py      published weights, score(), reply_opportunity(), risk filter   (pure)
  x_assets.py    mints captions + board images from what just published         (exists)
  x_engine.py    posts originals (text + media) via OAuth1; ledger; dry-run     (exists)
  x_replies.py   ranks reply targets; drafts briefs; gated posting              (new)
  x_metrics.py   pulls our posts' metrics; scores by the real weights           (new)
  x_oauth1.py    v1.1/v2 signing (posting, media, signed GET)                   (exists)
  drive.py       Google Drive filing                                            (exists)

.github/workflows/
  x-post.yml     originals, 13:00 UTC, dark behind X_AUTOPOST/X_MEDIA           (exists)
  x-reply.yml    reply sweep every 15 min, dark behind X_REPLIES                (new)
  x-metrics.yml  daily calibration report → issue comment                       (new)
```

**CLI (all support `--dry-run` unless noted):**
```bash
python -m tools.marketing.x_algo --sync-algo          # refresh weights from the upstream repo
python -m tools.marketing.x_engine   --dry-run --media --cap 6
python -m tools.marketing.x_replies  --minutes 30 --cap 5          # reply targets
python -m tools.marketing.x_replies  --draft                       # + LLM drafts per archetype
python -m tools.marketing.x_voice    "<post text>" --variants      # one draft per archetype
python -m tools.marketing.x_replies  --list-accounts               # the curated lists
python -m tools.marketing.x_replies  --follow --dry-run --follow-limit 5
python -m tools.marketing.x_metrics  --days 7          # calibration report
```

---

## 5. The loop

1. **Mint** — `daily-puzzle.yml` publishes boards (existing).
2. **Render** — `x-assets.yml` draws captions/images (existing).
3. **Post** — `x-post.yml` posts originals (dark until enabled).
4. **Reply** — `x-reply.yml` sweeps for rising posts and replies (dark until enabled).
5. **Measure** — `x-metrics.yml` pulls `organic_metrics`/`non_public_metrics`, scores each post by
   the §2 weights, and reports what to double down on.
6. **Calibrate** — the report tunes format mix, cadence, and reply timing; re-sync weights.

---

## 6. Guardrails (hard rules, enforced in code)

- Never reply to, or post about, injuries, death, illness, arrests, or politics — `x_algo.is_risky`
  blocks these before a draft is even made.
- **No invented numbers.** Every numeric token in a draft (digits *and* number words) must appear in
  the target post or a piece of verified catalog context, or the draft is retried once and dropped
  (`x_voice.invented_numbers`). A fabricated stat under the brand's name is the one mistake we
  cannot make.
- No @-mention spam, no reply to the same account more than once per hour, cap replies/run.
- **Follows are capped (5/run) and ledger-deduped** — mass following is an inauthentic-behaviour
  signal.
- Never post something we can't answer: board kinds require their image (existing rule).
- The trust gate stays: only `validate()`-clean, ≥6-face, image-present assets post.
- Everything ships **dark**; enabling is a repo-variable flip by a human.
- `main` is production; all changes branch, test, verify.

---

## 7. Phases

- **P0 — Foundation (this change).** `x_algo` weights + scoring; signed GET; `x_metrics`
  calibration report; plan doc. *Exit:* `x_metrics` prints a real report on our posts; tests green.
- **P1 — Reply sweep.** `x_replies` scoring + briefs + `x-reply.yml` dark. *Exit:* a dry-run picks
  5 fresh, low-competition, non-risky posts and shows a grounded draft for each.
- **P1.5 — Stat-context replies (our edge).** Match entities in the target post against the catalog
  (`player_seasons`) and emit the one specific stat the post lacked (§3.1). Deterministic facts,
  LLM only for phrasing. *Exit:* on a sample of 20 target posts, ≥ half match an entity and produce
  a factually-correct, specific line.
- **P2 — LLM voice.** Wire an LLM key (`x_voice`, done 2026-09-22: nano model, key in Supabase; the
  prompt is tuned to the §3.1 findings — statements, specificity, normal case) to polish the copy.
  *Exit:* drafted replies pass a human "would I post this?" gate ≥ 8/10.
- **P3 — Enable + calibrate.** Flip `X_AUTOPOST`/`X_MEDIA`/`X_REPLIES`; weekly report drives the
  mix. *Exit:* weighted-engagement/post trends up two weeks running; `ct=x_*` clicks appear.
- **P4 — Durable growth.** Steady original cadence + early replies; watch installs.

---

## 8. Open questions / user-gated

- LLM key for P2 (no key exists in this repo).
- Whether to enable auto-replies at all (recommend dry-run → human-approved → auto).
- X API credits: the account is on a credits plan; measure spend vs. the report's value.
