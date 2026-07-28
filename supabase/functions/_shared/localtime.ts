// Device-local time helpers for the cron notify functions. `utcOffsetMinutes` is the
// device's UTC offset captured at token registration (`device_tokens.utc_offset_minutes`,
// positive = east of UTC). The app writes `last_played_day` as a local-time "yyyy-MM-dd"
// (see BallIQ/Data/Repositories/ProgressRepository.swift), so any server-side comparison
// against it must use the device's local day, never the UTC day — at 8pm US-Eastern the
// UTC calendar has already rolled to tomorrow.

/** The device's local hour (0–23) at `nowMs`. */
export function localHour(utcOffsetMinutes: number, nowMs: number): number {
  const nowUtcMinutes = Math.floor(nowMs / 60_000);
  const localMinutes = ((nowUtcMinutes + utcOffsetMinutes) % 1440 + 1440) % 1440;
  return Math.floor(localMinutes / 60);
}

/** The device's local calendar day ("yyyy-MM-dd") at `nowMs` — the same string the app
 * stores in `progress.last_played_day`, and (since 2026-07-28) the same day the app resolves
 * daily puzzle content by (`PuzzleStore.localDayString` → `active_date`). */
export function localDayString(utcOffsetMinutes: number, nowMs: number): string {
  return new Date(nowMs + utcOffsetMinutes * 60_000).toISOString().slice(0, 10);
}

/** Every calendar day that some device could be calling "today" at `nowMs`, ascending.
 *
 * A cron function handles all timezones in ONE invocation, but real device offsets span
 * UTC-12…UTC+14 — a 26-hour spread, so at any instant devices straddle at most three
 * calendar days. Content keyed by day (`puzzles.active_date`) therefore has to be fetched
 * for all three and then selected per device via `localDayString`; using the server's own
 * UTC day for everyone is the bug this exists to prevent. */
export function candidateLocalDays(nowMs: number): string[] {
  const day = 86_400_000;
  return [-day, 0, day].map((delta) => new Date(nowMs + delta).toISOString().slice(0, 10));
}
