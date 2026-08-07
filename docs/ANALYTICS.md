# BallIQ analytics (M15)

First-party, privacy-conscious telemetry: a single `events` table written by
[`AnalyticsClient`](../BallIQ/Backend/AnalyticsClient.swift), no third-party SDK. Writes are
fire-and-forget and insert-only via RLS (see the M15 section of
[supabase/schema.sql](../supabase/schema.sql)); nothing can read the table through the API —
run the queries below in the Supabase SQL editor (or any service-role connection).

**Privacy posture:** the only identifier is the Supabase auth `user_id` the app already holds
(nullable — signed-out play logs with `user_id = null`). No device fingerprinting, no location,
no third-party sharing. Event properties are flat strings, deliberately small.

## Event vocabulary

Raw values of `AnalyticsEvent` (treat as a stable schema — the queries below group by them):

| `event_name` | Fired from | Properties |
|---|---|---|
| `onboarding_completed` | OnboardingView.finish() | `signed_in` |
| `sign_in_completed` | Onboarding + Profile, on success | `provider` (apple/google), `surface` |
| `game_started` | Keep4GameView / WhoAmIGameView first appear | `format`, `ranked`, `community` |
| `game_completed` | RepositoryContainer.complete() | `format` (GameFormatKind), `sport`, `ranked`, `perfect` |
| `puzzle_published` | RepositoryContainer.publish() | `format`, `sport` |
| `community_puzzle_played` | Community feed open + deep link | `source` (community/link), `puzzle_id` |
| `share_tapped` | Every share site (7 of them) | `surface`, `format`, `artifact`, plus `sport`/`hits`/`puzzle_id` where they apply — always built by `AnalyticsEvent.shareProperties` |
| `share_link_opened` | ContentView.handle(), on any inbound `balliq://` | `kind` (`challenge`/`play`), `format`, `sport`, `puzzle_id` |
| `challenge_started` | GridGameView.load() / ContentView.accept() | `format`, `sport`, `board` (`exact`/`fallback`, Keep 4 only) |
| `challenge_completed` | Grid/Keep4 result `.onAppear` | `format`, `sport`, `outcome` (`win`/`loss`/`tie`) |
| `report_filed` | RepositoryContainer.reportCommunity() | `puzzle_id` |
| `paywall_viewed` | PaywallView `.task` (once per presentation) | `trigger` |
| `purchase_attempted` | PaywallView.buy(), before StoreKit is called | `product_id`, `trigger` |
| `purchase_failed` | PaywallView.buy(), on cancel or throw | `product_id`, `trigger`, `reason` (`cancelled`/`error`) |
| `purchase_completed` | RepositoryContainer.purchase(), on a verified transaction | `product_id` |
| `app_opened` | `RootView.openApp()`, once per cold launch | `first_open`, `day_index`, `signed_in`, `push` |
| `onboarding_step_viewed` | OnboardingView, once per step reached | `step` (`OnboardingStep`), `index` |
| `first_game_started` | Onboarding's guided game + Home's daily cards, **once per install** | `format`, `sport`, `surface` |
| `first_game_completed` | Same two surfaces, **once per install** | `format`, `sport`, `surface`, `signed_in` |
| `moment_shown` | `MomentPresenter.present()` — at most once per session, ≥48h apart | `moment` (`Moment.analyticsID`), `trigger` (`foreground`/`post_game`), `games_played`, `day_index`, `sport` (favorite-team only) |
| `moment_accepted` | `MomentSheet.accept()` — the CTA tap | `moment` |
| `moment_completed` | The goal actually reached (username saved, team picked, friend added) | `moment` |

### The purchase funnel's `trigger` dimension

`paywall_viewed` → `purchase_attempted` → `purchase_completed` is the whole money funnel, and
`trigger` (raw values of `PaywallTrigger`) is what makes it actionable — it says *which gate*
sent the user to the paywall:

| `trigger` | Gate |
|---|---|
| `sport_picker` | A Pro-locked sport on a game setup screen (chip tap or the Start guard) |
| `grid` | The Grid, from Home's format launcher |
| `hard_mode` | Keep4 hard mode |
| `archive` | Full archive — Home's Browse row and Browse's own row taps |
| `over_under_lives` | The unlimited-lives upsell on the Over/Under result screen |
| `other` | The `-screenshotPaywall` debug hook. In production this means a presentation site shipped unattributed |

`purchase_failed.reason` splits `cancelled` (StoreKit returned no transaction — the user backed
out of Apple's sheet) from `error` (the purchase threw). Cancellation is a pricing/intent
signal; an error is a bug. Both raw-value sets are locked by
[`AnalyticsClientTests`](../BallIQTests/AnalyticsClientTests.swift) — renaming one breaks a
test rather than silently splitting a funnel in the warehouse.

**`purchase_completed` carries no `trigger`.** It's logged one layer down, in
`RepositoryContainer.purchase()`, which serves the paywall and (future) any other buy site, so
it doesn't know the presentation context. The funnel query below recovers the attribution by
joining a completion to that user's most recent preceding `purchase_attempted`.

### The activation funnel, and why it has no identifier in it

`app_opened` → `onboarding_step_viewed` → `first_game_started` → `first_game_completed` →
`app_opened` again with `day_index = '1'`. That last step is the whole of "next-day return" —
there is deliberately **no `next_day_return` event**, because a launch already knows how many
local days old its install is and storing the same fact twice is how two numbers start
disagreeing.

Every stage is countable **without joining anything**, which matters more here than anywhere
else in this document: a brand-new player is a guest, guests write `user_id = null`, and every
per-user query in this file collapses all of them into one row. So the activation events carry
their own funnel position as flat properties instead:

- `first_open` / `day_index` on `app_opened` (`ActivationState.recordOpen`, local days — matching
  `progress.last_played_day` and the local-8pm streak push, not UTC).
- `first_game_started` / `first_game_completed` fire **at most once per install**
  (`ActivationState.markOnce`, a UserDefaults flag), so a count of them *is* a count of installs
  that reached that stage. Nobody who plays ten puzzles contributes ten rows.

No install id, no device id, nothing new to declare on the privacy nutrition label — the
identifier posture at the top of this file is unchanged. The price is that you cannot follow one
guest through the funnel, only measure the width of each stage. At the volumes this was built for
(zero) that is the right trade; revisit it if per-cohort activation ever becomes the question.

**Known gap:** `first_game_completed` is written when the game's full-screen cover is *dismissed*
(that's the only signal the presenting view gets back). A player who finishes the puzzle and kills
the app from the result screen doesn't emit it — the milestone stays unset, so it fires on their
next completed daily instead. It under-counts same-session, never over-counts.

### Activation: installs → first win → next day

```sql
select
  count(*) filter (where event_name = 'app_opened'
                     and properties->>'first_open' = 'true')      as installs,
  count(*) filter (where event_name = 'onboarding_step_viewed'
                     and properties->>'step' = 'how_to_play')     as picked_a_sport,
  count(*) filter (where event_name = 'first_game_started')       as started_first_game,
  count(*) filter (where event_name = 'first_game_completed')     as first_wins,
  count(*) filter (where event_name = 'app_opened'
                     and properties->>'day_index' = '1')          as next_day_returns
from events
where created_at > now() - interval '30 days';
```

`picked_a_sport` counts arrivals at step 2, which can only happen by tapping a sport on step 1 —
so `installs → picked_a_sport` is the drop-off on the first screen, and
`started_first_game → first_wins` is the drop-off inside the first puzzle.

### Post-onboarding moments (shown → accepted → completed)

The three prompts that fire *after* first run — claim a username, set a favorite team, add a
friend (see `Moment`). There is deliberately **no** `moment_dismissed`: a dismissal is
`shown - accepted`, and storing a derivable fact twice is how two counts start disagreeing.

```sql
select properties->>'moment'                                        as moment,
       properties->>'trigger'                                       as trigger,
       count(*) filter (where event_name = 'moment_shown')          as shown,
       count(*) filter (where event_name = 'moment_accepted')       as accepted,
       count(*) filter (where event_name = 'moment_completed')      as completed
from events
where event_name in ('moment_shown', 'moment_accepted', 'moment_completed')
  and created_at > now() - interval '30 days'
group by 1, 2 order by 3 desc;
```

Two different failures live in the two gaps, and they get fixed in different places:
`shown → accepted` is the **prompt's** copy and timing, `accepted → completed` is the
**destination screen's** drop-off (someone opened `IdentityEditorSheet` and never saved).

The thresholds in `MomentEngine` are the thing this data exists to second-guess —
`games_played` and `day_index` ride along on `moment_shown` so a query can ask whether five
games is where the username ask actually lands, without re-deriving the count in SQL:

```sql
select properties->>'moment'                as moment,
       (properties->>'games_played')::int   as games_played,
       count(*)                             as shown
from events
where event_name = 'moment_shown' and created_at > now() - interval '30 days'
group by 1, 2 order by 1, 2;
```

### Where the first run stops

```sql
select properties->>'index' as step_index,
       properties->>'step'  as step,
       count(*)             as reached
from events
where event_name = 'onboarding_step_viewed'
  and created_at > now() - interval '30 days'
group by 1, 2 order by 1;
```

### Retention curve, and whether push can even reach these installs

```sql
select (properties->>'day_index')::int                              as day_index,
       count(*)                                                     as launches,
       count(*) filter (where properties->>'push' = 'authorized')   as push_authorized,
       count(*) filter (where properties->>'push' = 'denied')       as push_denied,
       count(*) filter (where properties->>'push' = 'not_determined') as push_unasked
from events
where event_name = 'app_opened' and created_at > now() - interval '30 days'
group by 1 order by 1;
```

The `push` split is how Home's streak-reminder primer is measured — there is no
`push_primer_answered` event, because the primer's only outcome is the authorization status this
already records on every launch: an install reading `not_determined` on day 0 and `authorized`
later converted, `denied` refused at the system prompt, and still-`not_determined` never engaged
the card. Note that `authorized` is necessary but **not sufficient** for a push to arrive:
`device_tokens.user_id` is `not null`, so a signed-out grant only becomes a real subscription once
that install signs in.

## The questions that matter right now

### Purchase funnel by gate (paywall → attempt → sale, last 30 days)

The money query: for each gate, how many paywall views became a trip to Apple's sheet, and how
many of those became a sale.

```sql
with recent as (
  select * from events where created_at > now() - interval '30 days'
),
attempts as (
  select user_id, created_at,
         properties->>'trigger'    as trigger,
         properties->>'product_id' as product_id
  from recent where event_name = 'purchase_attempted'
),
stages as (
  select 'viewed' as stage, properties->>'trigger' as trigger, user_id
    from recent where event_name = 'paywall_viewed'
  union all
  select 'attempted', trigger, user_id from attempts
  union all
  -- purchase_completed has no trigger of its own (it's logged a layer below the paywall), so
  -- borrow it from the same user's most recent attempt on the same product.
  select 'completed', last_attempt.trigger, c.user_id
    from recent c
    cross join lateral (
      select a.trigger from attempts a
       where a.user_id = c.user_id
         and a.product_id = c.properties->>'product_id'
         and a.created_at <= c.created_at
       order by a.created_at desc limit 1
    ) last_attempt
   where c.event_name = 'purchase_completed'
)
select trigger,
       count(*) filter (where stage = 'viewed')    as views,
       count(*) filter (where stage = 'attempted') as attempts,
       count(*) filter (where stage = 'completed') as purchases,
       round(100.0 * count(*) filter (where stage = 'attempted')
                   / nullif(count(*) filter (where stage = 'viewed'), 0), 1)    as view_to_attempt_pct,
       round(100.0 * count(*) filter (where stage = 'completed')
                   / nullif(count(*) filter (where stage = 'attempted'), 0), 1) as attempt_to_buy_pct
from stages
group by 1 order by views desc;
```

Two things this query will not tell you, by construction:

- **Signed-out purchases drop out of `purchases`.** `cross join lateral` needs `a.user_id =
  c.user_id`, which is never true for `null`, so a purchase made before sign-in is counted in
  `views`/`attempts` but not attributed to a gate. Cross-check the raw total with
  `select count(*) from events where event_name = 'purchase_completed'` — a gap is signed-out
  buyers, not a broken funnel.
- **These are event counts, not people.** A user who opens the paywall three times counts
  three views. Swap in `count(distinct user_id)` for a per-user funnel, remembering that every
  signed-out row collapses into a single `null` user.

### Day-1 / day-7 retention (by first-seen cohort)

```sql
with firsts as (
  select user_id, min(created_at::date) as first_day
  from events where user_id is not null group by user_id
)
select f.first_day,
       count(*)                                                   as cohort_size,
       count(*) filter (where exists (
         select 1 from events e where e.user_id = f.user_id
           and e.created_at::date = f.first_day + 1))             as d1,
       count(*) filter (where exists (
         select 1 from events e where e.user_id = f.user_id
           and e.created_at::date = f.first_day + 7))             as d7
from firsts f
group by f.first_day order by f.first_day desc;
```

### Format completion rate (started → completed, last 14 days)

```sql
select properties->>'format'                                       as format,
       count(*) filter (where event_name = 'game_started')         as started,
       count(*) filter (where event_name = 'game_completed')       as completed
from events
where event_name in ('game_started', 'game_completed')
  and created_at > now() - interval '14 days'
group by 1 order by 1;
```

`game_completed.format` is a `GameFormatKind` (`keep4Normal`/`keep4Hard`/`whoAmI`) while
`game_started.format` is the surface (`keep4`/`whoami`) — compare with
`case when properties->>'format' like 'keep4%' then 'keep4' else 'whoami' end` if you need an
exact join.

### Onboarding → first game funnel

```sql
select
  count(distinct user_id) filter (where event_name = 'onboarding_completed') as onboarded,
  count(distinct user_id) filter (where event_name = 'sign_in_completed')    as signed_in,
  count(distinct user_id) filter (where event_name = 'game_completed')       as played
from events;
```

(Signed-out rows have `user_id = null`, so signed-out onboardings undercount here —
add `count(*) filter (...)` variants if guest volume matters.)

### Community publish → play conversion

```sql
select count(*) filter (where event_name = 'puzzle_published')          as published,
       count(*) filter (where event_name = 'community_puzzle_played')   as plays,
       count(distinct properties->>'puzzle_id')
         filter (where event_name = 'community_puzzle_played')          as distinct_puzzles_played
from events
where created_at > now() - interval '30 days';
```

`community_puzzles.play_count` (bumped by the DB trigger) stays the source of truth for
per-puzzle totals; the event adds the `source` split (feed vs. deep link).

### Share + report volume

```sql
select event_name, properties->>'surface' as surface, count(*)
from events
where event_name in ('share_tapped', 'report_filed')
  and created_at > now() - interval '30 days'
group by 1, 2 order by 1, 2;
```

### The viral loop (k-factor)

`share_tapped` used to carry `surface` alone, and the Grid — the format the whole growth thesis
rests on — didn't log it at all, so the six rows in the table couldn't answer a single question
about distribution. The loop is now instrumented end to end:

```
share_tapped → share_link_opened → challenge_started → challenge_completed
```

**Which artifact actually spreads.** The one question worth asking first, because Immaculate
Grid's entire growth story is that a spoiler-free emoji board out-travelled everything else:

```sql
select properties->>'format'   as format,
       properties->>'artifact' as artifact,
       count(*)                as shares,
       count(distinct user_id) as sharers
from events
where event_name = 'share_tapped' and created_at > now() - interval '30 days'
group by 1, 2 order by shares desc;
```

**The loop itself.** Both ratios are the k-factor's two halves — invites per sharer, and what
fraction of an invite survives to a played board:

```sql
with loop as (
  select count(*) filter (where event_name = 'share_tapped')        as shared,
         count(*) filter (where event_name = 'share_link_opened')   as opened,
         count(*) filter (where event_name = 'challenge_started')   as started,
         count(*) filter (where event_name = 'challenge_completed') as completed,
         count(distinct user_id) filter (where event_name = 'share_tapped') as sharers
  from events where created_at > now() - interval '30 days'
)
select shared, opened, started, completed,
       round(shared::numeric / nullif(sharers, 0), 2)  as invites_per_sharer,
       round(opened::numeric / nullif(shared, 0), 3)   as open_rate,
       round(completed::numeric / nullif(opened, 0), 3) as invite_to_play
from loop;
```

**Do recipients ever win?** A loop where the challenged party always loses does not run twice:

```sql
select properties->>'outcome' as outcome, count(*)
from events where event_name = 'challenge_completed' group by 1;
```

Three things this deliberately does **not** claim:

- **`open_rate` is a floor, not a rate.** `share_link_opened` only fires for a recipient who
  *already has the app* — a `balliq://` URL does nothing on a device without it. Every install
  driven by a share is invisible to this query by construction (see below).
- **It's events, not people.** Swap in `count(distinct user_id)`, remembering signed-out rows
  carry `user_id = null` and collapse into one bucket.
- **`challenge_started.board = 'fallback'`** means a Keep 4 challenge named a day this device had
  no puzzle for, so the head-to-head was suppressed and the player got today's board instead. A
  rising share of `fallback` means the pool isn't deep enough for challenges to survive a day.

### Install attribution — the one gap, and how to close it

Every shared link is an App Store URL carrying a campaign token (`ShareMessage.storeURL`):
`?ct=chal_grid_nfl`, `?ct=res_whoami_nba`, `?ct=puzzle_invite`. Apple reports these under App
Store Connect → Analytics → **Campaigns**, which is the only way to see installs caused by a
share — the app itself cannot observe an install it caused.

**It is not switched on yet, and an agent cannot switch it on.** Apple only attributes `ct` when
the link also carries the provider token `pt`, which has to be read out of App Store Connect.
Once you have it, it's a one-line change in `ShareMessage.storeURL` — add
`URLQueryItem(name: "pt", value: "<token>")` next to `ct` — and every share link starts
reporting. Until then the tokens are inert but harmless, and the loop's *in-app* half is fully
measured regardless.

The other half of the same gap is **deferred deep linking**: a recipient who installs from a
share lands on Home, not on the challenged board, because a custom-scheme URL can't survive an
install. Closing that needs Universal Links — a hosted `apple-app-site-association` file plus an
`associated-domains` entitlement — which changes provisioning and is a user decision, not an
agent one. `ChallengeLink` is already shaped for it: the day a domain exists, `storeURL` becomes
an `https://` challenge URL and `parse` needs no change at all.

## Content health (pipeline side)

Every ingest run — `--dry-run` included — writes `tools/ingest/content_health.json`
(built by [`tools/ingest/health.py`](../tools/ingest/health.py)): per-theme pool depth,
seasons excluded by min-stat floors vs. niche filters, era-baseline coverage gaps, and
puzzles actually built. Run-level `totals` flag the two failure modes to watch:
`themes_below_pool_floor` (a theme too shallow to build an 8-card puzzle) and
`themes_with_era_gaps` (era-adjusted grades silently falling back to the global mean).

To check whether daily themes produce puzzles nobody plays, join the artifact's theme keys
against play events: daily puzzle ids are `<theme-key>-<variant>` , so

```sql
select split_part(properties->>'puzzle_id', '-', 1), count(*)  -- rough theme grouping
from events where event_name = 'community_puzzle_played' group by 1;
```

covers community; for daily puzzles use `game_completed` counts by `format`/`sport` until a
per-puzzle daily id is added to that event (deliberately left out of v1 to keep it lean).
