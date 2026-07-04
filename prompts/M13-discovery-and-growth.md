# M13 — Discovery & growth loop

> Read [README.md](README.md) first for shared architecture + build/verify commands and hard constraints.

## Status update (2026-07-02): shipped.

- **Text search** (client-side, per the confirmed key decision): `BallIQ/Models/PuzzleSearch.swift`
  (token-prefix matcher, diacritic/punctuation-tolerant) + `PrimeSearchField` in Browse (K4C4
  themes + player names; Who Am I? deliberately excluded — would leak answers) and Community
  (titles + descriptions). Tests: `PuzzleSearchTests`.
- **Pre-play sharing**: `BallIQ/Features/Share/PuzzleShareSheet.swift` (`SharablePuzzle` +
  `PuzzlePreviewCardView` with the ScoringKind badge) reachable from Home dailies, Browse, and
  Community cards (Community's overflow is now a Share/Report menu). `ContentView.handle` gained a
  daily-pool fallback so `balliq://play/<daily-id>` resolves too (verified in-simulator).
- **This-Week trending** (user-confirmed over all-time/decay): `CommunitySort.week` +
  `weekly_play_counts` SECURITY DEFINER RPC (schema.sql M13 section, **unapplied — hand-off**) +
  pure `CommunityTrending.sorted` (falls back to recent order until the RPC is deployed).
  Tests: `TrendingSortTests`.
- Stretch item 4 (personalized Home surfacing) was **not built**, per scope guidance.

## Goal

Make it possible to *find* a specific puzzle, and make sharing one actually pull a new player in
rather than just bragging to people who already have the app. Both Browse and Community currently
have zero text search — sport-pill filtering and New/Popular sort are the only ways to narrow 30+
daily puzzles or a growing community feed. The share flow shares a *result*, not an invitation to
*play*.

## Why now

Content volume has grown fast (M7: 853-player NBA pool, 18 curated + generated niche themes; M10:
community puzzles now carry real scoring-kind badges that make them feel distinct and shareable).
Discovery and growth tooling haven't kept pace — this is the natural next lever once the content and
trust-and-safety (M12) foundations are solid enough to support more traffic.

## Current state to build on

- **Update (2026-07-02):** `BrowseView` gained decade + NFL-position filter chips (a follow-up
  task, not part of this milestone) — see `BallIQ/Models/BrowseFilters.swift` and
  `BallIQTests/BrowseFiltersTests.swift`. Decade buckets by the median `PlayerSeason.seasonYear`
  among a puzzle's 8 players; position is a whole-word regex match against `Keep4Puzzle.theme`
  (NFL-only — NBA theme titles use role words, not position letters, and were deliberately left
  out). **This is precedent, not the deliverable** — it narrows an already-loaded list by facet; it
  is not text search. `CommunityView` has no equivalent filtering at all yet.
- `BrowseView`/`CommunityView` filter by sport pill (+ Browse's new decade/position pills) and
  New/Popular sort only (`SportFilter`, `CommunitySort`) — **no text field, no free-text
  player-name or title search anywhere.** That gap is this milestone's core deliverable.
- `CommunityPuzzleRepository.feed` already builds a PostgREST query with `select`/`order`/`eq`
  filters — a title `ilike` filter is a small, well-precedented addition to the same query builder.
- `ShareCardView` renders a result card (final score, top season) for `ShareLink`; there's no
  "share this puzzle before you've played it" path, and the rendered card doesn't carry the
  `ScoringKind` badge introduced in M10 even though the badge exists precisely to make a puzzle look
  distinct at a glance.
- `balliq://play/<id>` deep links already work end-to-end (`ContentView.handle(_:)`) — the
  infrastructure a "invite a friend to this puzzle" share already needs is in place.

## Scope

1. **Text search.** A search field in Browse (matches puzzle `theme`/title, and ideally player name
   within `players`) and in Community (matches `title`, falls back to server-side `ilike` on
   `content->>title` or a client-side filter over the already-fetched feed if volume stays low).
   Debounced, doesn't block the existing sport/sort filters.
2. **Pre-play puzzle sharing.** A share action on a puzzle card (daily or community) that shares the
   `balliq://play/<id>` deep link with a rendered preview card — reuse `ShareCardView`'s rendering
   approach but for the *puzzle*, not a completed result, including its `ScoringKind` badge so a
   shared "Author's Call" puzzle reads differently from a shared PPR daily.
3. **Trending/Popular refinement.** `CommunitySort.popular` currently just orders by
   `play_count.desc` with no time decay — a puzzle from three months ago with 50 plays outranks
   everything new forever. Add a lightweight recency-weighted variant (e.g. plays in the last 7
   days, if `community_plays` timestamps support it) as a third sort option, or confirm with the
   user that pure all-time popularity is the intended behavior before changing it.
4. **Personalized Home surfacing (stretch).** Given a user's play history (sport filter, formats
   played), surface one relevant Browse/Community puzzle on Home beyond just today's two dailies —
   e.g. "You haven't tried a community puzzle yet" or "New in NBA." Keep this genuinely simple
   (a rule-based suggestion, not a recommendation model) — don't over-scope.

## Key decisions (recommend, then confirm)

- Server-side search (`ilike` query) vs. client-side filter over the fetched feed: server-side scales
  better but needs a new indexed query path; client-side is simpler and fine while total puzzle
  counts stay in the hundreds. Recommend client-side first, revisit if content volume grows.
- Whether trending needs real time-decay math or a simpler "sort: this week" bucket is enough —
  don't build decay-curve math for a feed this size without confirming it's warranted.

## Deliverables

- Working text search in both Browse and Community.
- Pre-play share flow for any puzzle, deep-linkable, showing the scoring-kind badge.
- A trending/recency sort option (or a confirmed decision not to add one).

## Verification / success criteria

- Search narrows results correctly for a partial title match and a partial player-name match
  (screenshot both).
- Sharing a puzzle (not a result) produces a working `balliq://play/<id>` link that opens the same
  puzzle for a fresh install/simulator.
- New tests: search filtering logic (pure function, same pattern as `CommunityView.merge`), any new
  sort ordering.
- All existing tests green.

## Hand-offs (cannot be done by the agent)

- None expected — this milestone is fully buildable and verifiable with existing tooling (simulator
  + deep-link testing via `xcrun simctl openurl`).
