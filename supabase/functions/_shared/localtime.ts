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
 * stores in `progress.last_played_day`. */
export function localDayString(utcOffsetMinutes: number, nowMs: number): string {
  return new Date(nowMs + utcOffsetMinutes * 60_000).toISOString().slice(0, 10);
}
