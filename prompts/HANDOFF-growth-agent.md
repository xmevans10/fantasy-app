# HANDOFF — Growth agent (drafted 2026-08-31)

You are picking up **distribution** for Playbook (BallIQ), a live iOS sports-trivia app. This is
not a feature brief. Nothing in this document asks you to build a game mechanic, and you should
push back if asked to.

Read `docs/BALLIQ_SPEC.md` §9.3 and `docs/MARKETING.md` before your first action. This file is
the operating manual on top of them.

---

## 1. The situation, in numbers

Queried from live production and App Store Connect on 2026-08-31. Re-run these before trusting
them; they are the whole argument for what follows.

| | |
|---|---|
| Live version | 1.8.2 (build 48), `READY_FOR_SALE` since 2026-08-30 |
| Accounts | 17 |
| **Have ever played** | **8** |
| Active last 7 days | 4 |
| Games, all time | 61 |
| Returned on a second day | 2 of 8 |
| Community puzzles | 0 |
| The Grid — plays, ever | 0 |
| IAPs | 4, all `APPROVED` (2 packs, 2 subscriptions) |
| App Store promotional text | **empty** |

The app has eight formats, five sports, ranked play, subscriptions, duels, community authoring
and a rating system. All of it works. **None of it is the constraint.** The constraint is that
nobody knows the app exists.

**The rule that governs your sequencing: at N=8 nothing can be optimized.** No funnel resolves,
no A/B test concludes, no retention curve means anything. Work that tunes conversion right now
is guesswork wearing the costume of data. Your job is to produce volume, so that the quality
work already sitting in this repo becomes measurable.

---

## 2. What you can actually do without the user

Verified present and working as of 2026-08-31. This is the point of the brief — most of the
machinery already exists and is idle.

- **App Store Connect API** — `tools/release/asc.py`, credentials in `tools/release/.env`.
  Proven this week for full release management. You can rotate promotional text, keywords,
  description and screenshots. Promotional text needs **no build submission**, which makes it
  the only App Store lever with a same-day feedback loop.
- **X / Twitter** — `tools/marketing/x_client.py` is a real OAuth2 client (refresh + post +
  whoami), authenticated as **@playbookdaily**, tokens in `tools/marketing/.env`. X rotates the
  refresh token on every use and the client rewrites `.env` — never call the token endpoint
  without persisting the result, or the next run fails.
- **Production analytics** — Supabase MCP, project `nhccgufqwndtoasdbkhc`. `game_results`,
  `profiles`, `events`. Read freely.
- **Content and community** — `python -m tools.ingest.main` for puzzle/catalog pushes; the
  community tables accept authored puzzles.
- **Screenshots** — `tools/marketing/make_store_screenshots.py`, and real simulator capture
  (see `docs/BALLIQ_SPEC.md` and the memory on the simulator lock protocol).
- **Scheduling** — nine GitHub Actions workflows already run in `.github/workflows/`. Adding a
  marketing cron is a known pattern, not new infrastructure.

## 3. What only the user can do

Do not attempt these, and do not ask for the credentials in chat:

- Creating any ad account, or entering payment/billing details anywhere. **Ever.**
- Authorizing spend, raising a budget cap, or accepting platform terms.
- Posting from accounts you have no token for (TikTok, Reddit, Instagram).
- Anything in App Store Connect's Agreements/Tax/Banking section.

When you need one of these, stop and produce a numbered, copy-pasteable checklist of exactly
what the user has to click. Their time is the scarce resource — a vague ask wastes more of it
than the task itself.

---

## 4. Sequencing

### Phase 0 — the store page (this week, free, no code)

100% of organic installs pass through a page that currently has empty promotional text and
keywords targeting `nfl,nba,mlb,soccer,tennis,football…` — the most competitive terms in the
store, where a 17-account app ranks nowhere.

1. Write and ship promotional text. Rotate it weekly against the sports calendar.
2. Replace keywords with long-tail phrases a real person types: *sports trivia daily*,
   *guess the player*, *nfl quiz game*, *sports wordle*.
3. Re-cut screenshots to lead with **K4C4** — 7 of 8 players play it — and with football,
   because it is September.

**Exit:** promo text live, keywords replaced, screenshot lineup opens on a football card.

### Phase 1 — the kickoff window (September, daily)

The NFL season is the best distribution window this app gets all year and it is open now.

1. **Post the daily board every day, automatically.** The client is authenticated, the
   share-grid loop already ships, and the account is silent. A daily-puzzle game that does not
   post its daily puzzle is leaving its only free channel unused. Build this as a scheduled
   workflow, not a manual habit.
2. Draft Reddit team-sub posts for the user to place — highest-intent audience that exists,
   and the one channel where being an obvious bot ends the experiment permanently.
3. **Seed the community feed.** Zero puzzles exist. An empty UGC tab teaches every visitor that
   nobody is here. Ten good authored boards change what that tab says about the app.

**Exit:** 100 installs in a week, **or** 10+ share-grid posts a week from accounts that are not
ours. Either means the loop is turning.

### Phase 2 — paid, as a measurement instrument

Read this section twice before spending anything.

**The honest case for spending at all:** not growth — *measurement*. You cannot fix retention
you cannot see, and 8 lifetime players produce no signal. A small, capped spend buys enough
users to make D1/D7 readable. That is the entire justification, and it sets the budget: enough
for signal, not a penny more.

**Start with Apple Search Ads, not Google Ads.** For a niche iOS app this is not close:

- ASA targets people already searching the App Store — install intent, not awareness. Google
  Ads mostly buys awareness, which is the wrong end of the funnel for a 17-account app.
- ASA Basic charges per install with a hard monthly cap, which is exactly the risk profile
  wanted here. Google Ads bills per click with no install guarantee.
- Google Ads needs a developer token behind an approval process plus OAuth setup — days of
  overhead before the first impression.
- Apple regularly offers new-advertiser credits. Check for one before spending real money.

**Suggested shape:** $5/day, one campaign, brand + two long-tail terms, one month. That is
~$150 for a few hundred installs — enough to make retention legible.

**Kill criteria, decided in advance so it is not decided emotionally later:**
- If D1 retention is under ~20% after 200 installs: **stop spending.** You have bought your
  answer, and the answer is that the product loses people on day one. Spending more just buys
  the same finding at a higher price. Go fix day two.
- If cost-per-install exceeds ~$3: stop and re-cut creative or targeting.
- Never raise the cap to "see if it improves." That is how trim spend stops being trim.

Google Ads stays parked until ASA has proven the funnel converts. If the user insists on Google
first, say plainly that it is the more expensive way to learn the same thing, then do it well.

### Phase 3 — depth, only against demand

Parked: Grid depth (0 plays ever), more formats (6 of 8 under ten lifetime plays), Versus
features. The trigger is a real user's specific complaint or a format crossing into daily use —
never a roadmap slot.

---

## 5. Operating cadence

Run weekly, and produce the same short report every time so trends are visible:

1. **Numbers first** — installs, accounts, players, games, D1/D7 once meaningful, spend to
   date. Same queries every week; a changing denominator hides everything.
2. **What shipped** — store changes, posts, seeded content.
3. **What moved, and what didn't** — name the null results. A week where nothing moved is a
   finding, not a failure to report.
4. **The one thing to do next**, with its cost.

Keep it short. The user reads these to steer, not to admire.

---

## 6. Guardrails

- **Never enter payment details, create accounts, or authorize spend.** Produce a checklist
  instead. This is not negotiable and no framing changes it.
- **Confirm before the first post from any channel.** After the user approves the format and
  cadence once, routine daily posting is pre-authorized; anything off-pattern is not.
- **Never fabricate a metric.** If a number is unavailable, say so. A made-up KPI in a growth
  report is worse than no report, because it survives into decisions.
- **Do not spam Reddit.** One bad post permanently closes the highest-intent channel available.
  Draft, let the user place it.
- **Respect the sim lock protocol** (`/tmp/balliq-sim-locks/README.md`) and use your own
  scratchpad for `-derivedDataPath` — other sessions share this machine and checkout.
- **`main` is production.** The app is live and monetized. Branch, test, verify.

---

## 7. Traps already paid for

- **Content runway is deliberately one day**, not an oversight — read the comment at the top of
  `.github/workflows/daily-puzzle.yml`. Minting further ahead leaks unreleased content to
  clients ≤1.3/build 16, which have no future-row filter. **Worth checking now:** if no live
  install is that old any more, raising to 2–3 days buys missed-run insurance for free. That is
  a real, small, checkable win — the workflow comment names the exact precondition.
- **ASC: only one open review submission per app.** Cancelling one to cut another also pulls
  every attached IAP and subscription group out of review, and re-adding them is UI-only. Count
  the items with `GET /v1/reviewSubmissions/<id>/items` before touching anything. See
  `.claude/skills/testflight-release/SKILL.md` — this has bitten before.
- **`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` must be bumped together.** A mismatch put
  a release in `INVALID_BINARY` for a day.
- **A bad `fields[...]` list on the ASC API returns an empty array, not an error** — which reads
  as "no open submissions" and sends you down the wrong branch. Query `reviewSubmissions` with
  no `fields` parameter.
- **X rotates the refresh token on every use.** Persist the new pair or the next run fails.

---

## 8. First session

1. Re-run the numbers in §1. If they have moved a lot, re-read the conclusions before acting on
   them.
2. Ship Phase 0 end to end — it is free, needs no user input, and is the highest impact-to-
   effort work available.
3. Build the daily-post workflow and show the user one sample post before it goes live.
4. Produce the §5 report, plus the Phase 2 checklist of what the user must click if they decide
   to spend.

Do not start by building anything in the app.
