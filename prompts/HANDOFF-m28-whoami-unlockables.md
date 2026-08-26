# Handoff — M28 Who Am I? visual pass, M29 unlockables

Two related pieces of work, scoped 2026-08-26 while 1.7.0 build 41 sat in review. They're in one
doc because they share a substrate: both are about **identity and payoff being visible**, and M29
reuses the colour vocabulary M28 establishes. They ship as separate builds.

Read `CLAUDE.md`, `AGENTS.md`, and `docs/BALLIQ_SPEC.md` §1 (product feedback themes) first. The
`dev-taste` skill resolves any judgement call this doc leaves open.

---

## Part A — M28: make Who Am I? look like the best format in the app

### Why now

Who Am I? is the format with the **most content depth** (6 clues drawn from ~30 dimensions,
§1) and the **least visual identity**. Measured on the 6.9" simulator while shooting the store
screenshots, 2026-08-26: at the natural opening state (1 clue revealed) the screen is
**~60% empty cream**. The App Store audit flagged the same thing independently
(`marketing/APP-STORE-SCREENSHOT-AUDIT.md` §6, "dead space"), and it's why the shipped
screenshot had to be staged at 5 revealed clues to look composed at all.

Compare like-for-like: the Journeyman board (`JourneymanGameView`) fills the same canvas edge to
edge with crests and club names, and K4C4 fills it with a team-coloured card. Who Am I? renders
five rounded rectangles of grey-labelled text.

### 🔴 The one thing that cannot be done, and what to do instead

**The clue list must not use the subject's team colours.** That was the opening idea and it
breaks the game: `teams` is one of the six `ClueKind`s and one of the ~30 clue dimensions, so
painting the clue chrome in Cardinals red answers a clue the player hasn't bought yet — and on a
board where "Last team" is clue 5, it answers it from clue 1. Same reason the Journeyman
drip-feed was cut mid-build (§1): don't put a lever between the player and the question.

Three places team colour *can* land, none of which leak:

1. **The answer card**, at solve time — `WhoAmIResultView`, flood-filled in the subject's club
   palette. All of the payoff, zero leak, and it reuses `TeamIdentityIndex` exactly as
   `Keep4CardView` already does.
2. **The board's own sport**, which is already displayed ("NFL" sits in the header today).
3. **Clue *kind*** — not the subject's team. See below.

### A1. Colour-code the clue chips by `ClueKind` (the load-bearing change)

`WhoAmIPuzzle.Clue` carries `kind: ClueKind` — exactly six cases (`era, position, teams,
statLine, fact, jersey`), and it is a **wire-compatibility contract present on every board
including legacy content**. `dimension: String?` is richer (~30 values) but is **nil on older
content**, so keying visuals off it would render half the archive uncoloured. Key off `kind`.

Six kinds → six tokens + six SF Symbols, on the numbered chip in `WhoAmIGameView.clueRow`
(line ~213) — the chip is already there, it's just flat blue today:

| kind | reads as | suggested symbol |
|---|---|---|
| `era` | when | `clock.arrow.circlepath` |
| `position` | where on the field | `figure.american.football` |
| `teams` | who he played for | `shield.lefthalf.filled` |
| `statLine` | the numbers | `chart.bar.fill` |
| `fact` | the deep cut | `sparkles` |
| `jersey` | the number | `number.circle.fill` |

Use existing `Theme.swift` role tokens (`accentFill`, `voltFill`, `goldFill`, …) rather than six
new hex constants — the palette is deliberately small and DESIGN.md says so. This alone turns a
stack of identical rectangles into a legible sequence.

### A2. Fill the dead space with the thing the format is actually about

The empty two-thirds should carry a **value meter**: the purse as a big Anton numeral that
visibly drains as clues are bought. Today "Worth 1,250 pts" is 13pt text in the header and the
cost only appears as "Next clue · −250 pts" at the very bottom — the two halves of the same
mechanic sit at opposite ends of the screen and neither is dramatic.

This is the highest-value item in Part A: it fixes the composition problem **and** makes
"guess early, score higher" (the subhead we ship on the App Store) something you can see. It has
an obvious precedent in `CountUpText` and the Blitz clock.

Honest caveat: it changes the screen's information hierarchy, so screenshot it against the
longest clue text and the 6-clue state (AGENTS.md §5) before calling it done.

### A3. Answer reveal in club colours

`WhoAmIResultView` already gets the subject. Flood the result in their club palette via
`TeamIdentityIndex`, matching the treatment `GridResultView` gives a perfect board. Cheap, and
it's the emotional beat the format currently lacks.

### Exit criteria

- Opening state (1 clue) has no region of dead cream taller than one clue row.
- Every clue chip is distinguishable by kind at a glance, on legacy content too (verify against a
  board where `dimension` is nil — they exist in the archive).
- No team-identifying colour anywhere before the answer is revealed. Verify by opening a board
  whose subject is a one-club player and confirming nothing on screen is that club's colour.
- 844+ Swift tests green; screenshots before/after at 1, 3 and 6 clues.

---

## Part B — M29: unlockables (badges, flair, themes)

### The shape of the decision

Three classes, and they are **not** equal in cost. Sequence matters more than scope here.

| class | what it is | where it shows | cost |
|---|---|---|---|
| **Badges** | proof you did a hard thing | Profile, share card, duel header | **low** |
| **Flair** | chosen identity (frame, title, avatar ring) | anywhere the avatar renders | **low–medium** |
| **Themes** | whole-app palette | everywhere | **high — see B4** |

### B1. Earned, not sold

**Recommendation: v1 unlockables are earned through play only. Nothing is purchasable.**

Three reasons, in the order that should decide it:

1. **BALLIQ_SPEC §1 Theme 5** — outcomes must reward playing well. A cosmetic economy where the
   best-looking profile belongs to whoever paid inverts the app's own premise ("prove you know
   ball"). The whole point of a badge is that it is *evidence*.
2. **§9.3 explicitly deprioritised monetization-funnel work** in favour of growth and engagement.
   Unlockables qualify as engagement; a cosmetics storefront is funnel work wearing a hat.
3. Pro already exists (`StoreProduct`: `proMonthly`, `proYearly`, `draftSpinPack`, `gridPack`).
   Selling cosmetics beside it dilutes what Pro means without adding a new reason to buy it.

**Where Pro does belong:** Pro grants *more equipped slots* (e.g. 3 badges shown vs 1) and
*early access* to a season's shelf. It never grants an exclusive badge — that would make a badge
a receipt instead of a trophy.

### B2. Awarded server-side, from counters that already exist

dev-taste §3: enforce it, don't just fix it. A client that can grant itself a badge will.

Everything a first shelf needs is already in Postgres — no new tracking:

- `game_results` — per-format play and scores
- `arcade_scores` — `(game, sport)` bests
- `ratings` / `rating_history` — tier climbs
- `profiles` — streak, favourite teams
- `ladder_attempts` — bot-ladder rungs cleared

Schema sketch (additive, matches the `schema.sql`-stays-in-sync rule in CLAUDE.md):

```sql
create table if not exists public.unlock_definitions (
  id          text primary key,          -- 'perfect_grid_nfl'
  class       text not null check (class in ('badge','flair','theme')),
  name        text not null,
  description text not null,
  rule        jsonb not null,            -- machine-checkable predicate, see B3
  season      text,                      -- null = evergreen
  sort        int  not null default 0
);

create table if not exists public.user_unlocks (
  user_id   uuid not null references auth.users(id) on delete cascade,
  unlock_id text not null references public.unlock_definitions(id),
  earned_at timestamptz not null default now(),
  primary key (user_id, unlock_id)
);
```

Equipped state goes on `profiles` (`equipped_badges text[]`, `equipped_flair text`,
`equipped_theme text`), with a trigger or RPC asserting the user actually owns what they equip —
otherwise "equipped" becomes a second, unenforced grant path.

RLS: `user_unlocks` is readable by anyone (badges are public proof — the share card needs them)
but writable **only** by `service_role` / a `security definer` award RPC.

### B3. Generated, not hand-maintained

dev-taste §2, and the question that gets asked the moment a list of badges is shown: *what mints
these?* Do not hand-author 40 badge rows.

`rule` is a small declarative predicate the award RPC evaluates against the tables in B2 — e.g.
`{"kind":"perfect_board","format":"grid","sport":"nfl"}` or
`{"kind":"streak_at_least","days":30}`. One evaluator, N rows. That makes a new badge a data
push through `tools/ingest`, not a code change, and it makes the catalogue testable offline the
way `catalog-replay-harness` already tests theme viability.

Award timing: evaluate on write (the existing `submit_*` RPCs already run server-side at exactly
the moment the evidence appears) plus a backfill pass so existing players don't start empty —
an empty trophy case on day one is the fastest way to make the feature feel dead.

### B4. 🔴 Themes are ~10× badges and flair — do them second, or not yet

Measured 2026-08-26, so this is a number and not a vibe:

- `BallIQ/DesignSystem/Theme.swift` declares **61 `static let` colour tokens**.
- Those tokens are referenced at **551 call sites across 63 files**.

`static let` is resolved at type level, so there is no seam to swap a palette at runtime. A real
theme system means converting the token surface to something environment-resolved
(`@Environment(\.palette)` or an `ObservableObject` the root injects) and touching all 63 files.
That is a mechanical refactor with a wide blast radius and no user-visible progress until it's
finished — the exact shape AGENTS.md §11 warns about.

**Recommendation: ship badges + flair first (v1), and treat themes as their own milestone.** If
themes are wanted sooner, the cheap 80% is a **dark/light-independent accent swap** — re-point
only the accent family (`accentFill` / `accentText` / `accentBg` / `accentBorder`, plus
`voltFill`/`goldFill`) through an injected palette and leave the 40-odd surface/text tokens
static. That's ~6 tokens instead of 61, gets "my app looks different from yours", and does not
require re-auditing contrast on every surface in both appearances.

### B5. What the first shelf should actually contain

Keep it small and legible. Badges should name things a player would brag about:

- **Perfect Grid** — 9/9 on a ranked board (already the ratings-prompt trigger, so the moment is
  identified in code today: `ReviewPrompter.shouldAsk(immaculateGrid:)`).
- **Blitz PB tiers** — 1/3/5-minute score thresholds. Note the open problem in
  `HANDOFF-m27-followups.md`: `arcade_scores` is keyed `(game, sport)` with a check constraint
  excluding blitz, and a blitz run spans sports. **A sportless `blitz_scores` table is a
  prerequisite for any Blitz badge** — fold it into this milestone rather than filing it twice.
- **Streak tiers** — 7 / 30 / 100 days.
- **Tier climbs** — first Gold, first Platinum.
- **Ladder rungs** — clearing rung 10 / 20 / 30.
- **One-club loyalty** — every daily in a sport for a week (ties badges to `favorite_teams`,
  which is otherwise nearly invisible today).

Flair v1: avatar ring colour + a short earned title under the username on the share card. Both
land on `ProfileShareCardView`, which is the surface that actually leaves the app — which makes
flair a growth feature as much as an engagement one, and puts M29 squarely inside §9.3's
priority rather than beside it.

### Exit criteria

- A badge cannot be granted by a client; the award path is `security definer` and tested.
- Backfill runs, and an existing account with real history logs in to a non-empty trophy case.
- The catalogue is data, not code: adding a badge is an ingest push with no app release.
- Share card renders equipped flair; screenshot it (AGENTS.md §5) with 0, 1 and max badges, and
  with the longest title string in the catalogue.

---

## Sequencing recommendation

1. **M28** (Who Am I? visual pass) — self-contained, no schema, immediately improves the format
   *and* the App Store screenshot that currently needs staging to look full.
2. **M29a** — `blitz_scores` table + badges + flair, earned-only.
3. **M29b** — themes, only if the accent-swap subset in B4 isn't enough.

Do not start B4's full refactor and A2 in the same build; they touch the same design-system
surface from opposite ends.
