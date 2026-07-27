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
| `share_tapped` | Result share, publish-link share, pre-play puzzle share (M13) | `surface` (result/publish_link/puzzle_home/puzzle_browse/puzzle_community), `puzzle_id` (pre-play only) |
| `report_filed` | RepositoryContainer.reportCommunity() | `puzzle_id` |
| `paywall_viewed` | PaywallView `.task` (once per presentation) | `trigger` |
| `purchase_attempted` | PaywallView.buy(), before StoreKit is called | `product_id`, `trigger` |
| `purchase_failed` | PaywallView.buy(), on cancel or throw | `product_id`, `trigger`, `reason` (`cancelled`/`error`) |
| `purchase_completed` | RepositoryContainer.purchase(), on a verified transaction | `product_id` |

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
