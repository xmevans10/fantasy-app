// Which sport the daily-drop push features.
//
// One notification for everyone, rotating a sport per day: NFL, then NBA, then MLB, then
// soccer, then tennis, then back to NFL. Not personalised — every recipient on a given
// calendar day gets the same push, and the featured sport is a function of the day alone.
//
// Pure, and in `_shared` rather than beside the notifier, because the notifier calls
// `Deno.serve` at module load — importing it from a test would boot a server.
//
// The bug this replaced (production, 2026-08-19): the notifier read `profiles.primary_sport`,
// which is NULL for every profile because nothing in the app sets it, then fell through to
// "first entry of the themes map". Map order comes from PostgREST, which returns
// `puzzle_history` in the order daily_puzzle.py wrote it, which is sorted by sport — so the
// answer was *always baseball*, every day, for everyone. Baseball then drew a pitching theme
// on 7 of 8 days and the push read "Ace pitching seasons" over and over.

/** The rotation, in order. Fixed rather than derived from whatever minted that day, so the
 * cycle stays stable and predictable even when one sport's mint is missing — a gap is skipped
 * for that day, it does not shift everyone else's turn. */
export const SPORT_ROTATION = ["nfl", "nba", "baseball", "soccer", "tennis"] as const;

/** Whole days since the epoch for a "YYYY-MM-DD" local day.
 *
 * Parsed field-by-field through `Date.UTC` rather than `new Date(str)` so the result is a pure
 * function of the string — the notifier hands us a device-LOCAL day, and re-interpreting that
 * in the server's zone is exactly the class of bug `localtime.ts` exists to avoid. */
function dayIndex(localDay: string): number {
  const [y, m, d] = localDay.split("-").map(Number);
  return Math.floor(Date.UTC(y, (m ?? 1) - 1, d ?? 1) / 86_400_000);
}

/** The sport to feature on `localDay`, skipping any that has no puzzle minted for that day.
 *
 * Everyone on the same calendar day resolves the same sport, which is the point: this is one
 * shared notification, not a per-user one. Returns null only when nothing minted at all, which
 * degrades to the generic drop copy. */
export function sportForDay(localDay: string, available: string[]): string | null {
  if (available.length === 0) return null;
  const offered = new Set(available);
  const start = ((dayIndex(localDay) % SPORT_ROTATION.length) + SPORT_ROTATION.length)
    % SPORT_ROTATION.length;
  for (let i = 0; i < SPORT_ROTATION.length; i++) {
    const sport = SPORT_ROTATION[(start + i) % SPORT_ROTATION.length];
    if (offered.has(sport)) return sport;
  }
  // Something minted, but nothing in the rotation — a sport the pipeline added and this list
  // has not caught up with. Name it rather than dropping to generic copy.
  return [...available].sort()[0];
}
