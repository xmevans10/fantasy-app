// Choosing WHICH sport a daily-drop push talks about.
//
// The rule is simple and it is not "the user's favourite": **name the board they will actually
// land on when they tap the notification.** Five K4C4s are minted every day, one per sport, and
// Home opens its daily-games pager on `container.sportFilter.sport ?? .nfl` — the sport they
// last played, falling back to NFL (HomeView.loadDaily). A push naming any other sport promises
// a board the app does not then show, which is worse than naming none.
//
// Pure, and in `_shared` rather than beside the notifier, because the notifier calls
// `Deno.serve` at module load — importing it from a test would boot a server.
//
// The bug this exists to prevent (production, 2026-08-19): the notifier read
// `profiles.primary_sport`, which is NULL for every profile because nothing in the app sets it,
// then fell through to "first entry of the themes map". Map order comes from PostgREST, which
// returns `puzzle_history` in the order daily_puzzle.py wrote it, which is sorted by sport — so
// the answer was *always baseball*, for every user, every day. Baseball then drew a pitching
// theme on 7 of 8 days, and the push read "Ace pitching seasons" over and over to a user whose
// own last-played sport was NFL.

/** What the client falls back to with no last-played sport — must track `HomeView.loadDaily`'s
 * `container.sportFilter.sport ?? .nfl`. A brand-new install lands on NFL, so its push says NFL.
 *
 * This deliberately is NOT rotated for variety. Rotating would read better in a notification
 * list and would be a lie: the app would still open on NFL. If new users should meet a
 * different sport each day, that belongs in the pager's initial page, and this constant then
 * follows it. */
export const DEFAULT_PUSH_SPORT = "nfl";

/** The sport whose board this person will actually be shown.
 *
 * `recentSports` is their play history, most-recent first. The first entry that actually minted
 * a puzzle for the day wins — recency, not frequency, because `sportFilter` is last-played and
 * that is what the pager reads. Someone who played NFL fourteen times and NBA once yesterday
 * opens on NBA, so the push says NBA.
 */
export function sportForPush(recentSports: string[], available: string[]): string | null {
  if (available.length === 0) return null;
  const offered = new Set(available);
  for (const sport of recentSports) {
    if (offered.has(sport)) return sport;
  }
  // No history, or none of it minted today: mirror the client's own fallback, and only if that
  // sport has a board. Otherwise name nothing rather than a sport they will not see.
  return offered.has(DEFAULT_PUSH_SPORT) ? DEFAULT_PUSH_SPORT : null;
}
