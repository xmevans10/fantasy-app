// Choosing WHICH sport a daily-drop push talks about.
//
// Pure, and in `_shared` rather than beside the notifier, because the notifier calls
// `Deno.serve` at module load — importing it from a test would boot a server. Everything the
// cadence layer keeps testable lives here for the same reason.
//
// The bug this exists to prevent (production, 2026-08-19): the notifier read
// `profiles.primary_sport`, which is NULL for every profile because nothing in the app sets
// it, then fell through to "first entry of the themes map". Map order comes from PostgREST,
// which returns `puzzle_history` in the order daily_puzzle.py wrote it, which is sorted by
// sport — so the answer was *always baseball*, for every user, every day. Baseball then drew
// a pitching theme on 7 of 8 days, and the push read "Ace pitching seasons" over and over to a
// user whose own history was 14 NFL games to 3 baseball.

/** The sport this person plays most, restricted to sports that actually have a puzzle today.
 *
 * Counting is deliberately over a recent window (see the caller) rather than all time: someone
 * who has moved from baseball to NFL should stop being told about baseball. Ties resolve by
 * the caller's `available` ordering, which is sorted, so the choice is stable run to run
 * instead of depending on map insertion order — the exact thing that caused the bug above. */
export function favouriteSport(
  counts: Map<string, number> | undefined,
  available: string[],
): string | null {
  if (!counts || available.length === 0) return null;
  let best: string | null = null;
  let bestN = 0;
  for (const sport of available) {
    const n = counts.get(sport) ?? 0;
    if (n > bestN) {
      best = sport;
      bestN = n;
    }
  }
  return best;
}

/** For someone with no play history — a brand-new install, which is exactly who a morning drop
 * is meant to reach. Rotates by local day so their first week shows several sports rather than
 * hammering whichever one sorts first. Deterministic, so two devices on the same day agree. */
export function rotatingSport(localDay: string, available: string[]): string | null {
  if (available.length === 0) return null;
  let h = 0;
  for (const ch of localDay) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return available[h % available.length];
}
