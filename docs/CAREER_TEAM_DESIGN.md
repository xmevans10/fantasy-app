# Career progression and favorite-team hub — 2026-10-04

## Verified context

Playbook is `xmevans10/fantasy-app`, native SwiftUI. App Store Connect returned HTTP 200:
latest uploaded build 57, VALID, uploaded October 2. Remote main is 718b3f5 and still declares
build 55. The local checkout carries the build-57 portrait treatment and many unrelated edits.
This branch starts from remote main and carries only the relevant current K4C4 treatment plus
this feature; it deliberately does not publish the other local work or upload a TestFlight build.

Live Supabase GET returned 390 K4C4 boards. Some clubs have exclusive boards, many do not.
A board containing one favorite player is not a team-only puzzle. No daily team inventory
or streak is claimed by this implementation.

## Research and decision

| Evidence | Product implication |
| --- | --- |
| [Duolingo Score](https://blog.duolingo.com/duolingo-score/) gives granular course progress rather than only broad proficiency bands. | Show a level number and exact distance to the next level on Home, Profile and results. |
| [Duolingo streak experiment](https://blog.duolingo.com/improving-the-streak/) separated daily goals from streaks and reported higher retention, with a tradeoff in goal completion. | Preserve streak as habit feedback; career level is permanent and skill rating remains competitive. These are distinct signals. |
| [Trivia Crack missions](https://triviacrack.help.etermax.com/hc/en-us/articles/360024627294-Seasonal-Missions) show mission progress and successive reward levels. | Make the next milestone legible; avoid adding a second mission economy until the core progress loop is visible. |
| [Pokémon GO leveling update](https://pokemongo.com/news/pgo-leveling-update-details-2025) rebalances progress and adds level rewards. | Avoid indefinitely widening gaps. Keep early thresholds and cap the later interval; actual reward economies are out of scope. |
| [MLB favorite teams](https://www.mlb.com/news/how-to-follow-favorite-players-in-mlb-app) personalize Home and prioritize the selected club. [NBA personalization](https://support.watch.nba.com/hc/en-us/articles/360056384154-What-is-the-NBA-App) also centers interests and teams. | A team-colored Home entry and dedicated collection, reusing existing favorites and club identity. |
| [Goal-gradient study](https://www.columbia.edu/~rk566/Session4/Goal-Gradient_Illusionary_Goal_Progress.pdf) investigates effort as a reward approaches. | Display the nearby next level and exact XP remaining. This is a design inference, not measured Playbook retention. |
| [Endowed progress](https://academic.oup.com/jcr/article-abstract/32/4/504/1787425) examines artificial advancement. | Preserve genuinely earned XP rather than inventing a starting reward. |
| [Gamification experiment](https://doi.org/10.1016/j.chb.2016.12.033) finds different elements affect different psychological needs. | Treat titles as recognition of participation; do not relabel XP as demonstrated sports expertise. |

## Implemented scope

Career titles: Rookie 1, Regular 5, Starter 10, Veteran 20, Captain 35, Club legend 50.
The original quadratic thresholds are unchanged through level 10 (8,100 cumulative XP).
Subsequent gaps are 1,900 XP. No XP is rewritten, and no existing career level decreases.
At the 100-XP base payout that is at most 19 ordinary completions per later level; existing
perfect/day/streak bonuses shorten that. This pacing is a first design choice to evaluate,
not a claim about measured user preference. Levels continue after the last named milestone.
Shared results show level-up feedback and current progress. Elo metal tiers remain explicitly
labeled competitive rating; changing that math would conflate mastery with participation.

Team hub: Home entry, existing searchable picker, real team colors/name/crest, guest preferences
persisted locally, signed-in preferences kept in the existing profile store. Collection reuses
the existing archive repository and Pro entitlement. Every listed board has exactly eight unique
seasons, all with the selected sport and club abbreviation. Unknown/ambiguous soccer identity
is excluded because player cards lack a league field. Empty collections are honest and retryable.
No new backend schema, invented records, independent team XP or team streak.

K4C4: full-height portraits enlarged to the right-hand field, bottom aligned behind an opaque
metadata footer and a shared horizontal rule. Long names retain two lines; compact recap cards
keep the existing badge. Stats, Keep/Cut controls and scoring are unchanged.

## Next product decision

Before making this a team *daily*, expand curated exclusive-team inventory across clubs and
attach league-qualified franchise metadata to puzzles. Evaluate team entry-to-play conversion,
empty collection frequency, games between levels and return behavior using the existing
analytics pipeline. No numerical retention claim or unattended tracking job is added here.

## Validation

- Debug and Release simulator builds succeeded.
- Full Swift suite on iPhone 15 / iOS 18.3: 1,009 tests, 0 failures, 1 existing skip.
- Final focused checks after portrait and compact-Home refinements: 9 tests, 0 failures.
- SE full run: 1,009 tests, one failure in the unchanged image-bucket test, which assumes
  a 3× display; the standard iPhone run passes it. This change does not alter image caching.
- Python suite: 888 passed, 1 skipped initially; three external-F1-network failures and
  two sandbox-local-server errors. All five affected cases passed in the unrestricted
  23-test recheck (23 passed), yielding 893 passed and 1 skipped across the suite.
- Real component renders checked at 343pt width / 330pt and 520pt card heights, all seven
  sport cases, long names, no photo, no team, near-level threshold and level 50. Before/after
  fixtures cover the five sports with bundled boards. Hosted Home and empty hub captured on SE.
- No schema or production-data mutation and no TestFlight upload.

Authentication context repair: expected the documented root GitHub token to work, received
HTTP 401. Updated CLAUDE.md's Git section in place (KB_STALE); SSH independently authenticated
as xmevans10. The docs change does not rotate or expose credentials.
