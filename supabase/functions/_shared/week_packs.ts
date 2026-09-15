// Week Pack pushes: who gets one, and which pack it names.
//
// Pure, and in `_shared` rather than beside the notifier, for the same reason as sport.ts: the
// notifier calls `Deno.serve` at module load, so a test cannot import it.
//
// The rules, in order:
//   1. A pack is announced on its own release day only (device-local day, the day it opens).
//   2. Only to devices whose build can show a pack. `device_tokens.app_build` is NULL for every
//      build older than the column, and a "your pack is here" push to an app with no pack UI is
//      a promise the app cannot keep.
//   3. On a pack day the pack push REPLACES the daily-drop push for that person. The pack's first
//      board is that day's daily, so one push carries both, and it costs one slot of the shared
//      daily cap rather than two.
//   4. Several packs landing the same day (NBA and MLB both close on Sunday) become one push that
//      names one pack and counts the rest, chosen by the same day rotation as the daily drop.

import { type DeviceToken } from "./cadence.ts";
import { sportForDay } from "./sport.ts";

/** The first build with the Week Pack UI. Bump only if a later build changes what a pack push
 * opens into. */
export const PACK_MIN_BUILD = 53;

export interface PublishedPack {
  id: string;
  sport: string;
  label: string;         // "2026 Week 1", "Sep 7 to 13"
  release_date: string;  // YYYY-MM-DD
  boards: number;
  headline: string | null;
}

export interface PackToken extends DeviceToken {
  app_build: number | null;
}

/** Devices that can open a pack. */
export function packCapable(tokens: PackToken[]): DeviceToken[] {
  return tokens
    .filter((t) => (t.app_build ?? 0) >= PACK_MIN_BUILD)
    .map(({ token, environment }) => ({ token, environment }));
}

/** The pack to announce to someone whose local day is `localDay`, and how many others opened
 * the same day. `null` when nothing opens today. */
export function packForDay(
  packs: PublishedPack[],
  localDay: string,
): { pack: PublishedPack; others: number } | null {
  const today = packs.filter((p) => p.release_date === localDay && p.boards > 0);
  if (today.length === 0) return null;
  const sport = sportForDay(localDay, [...new Set(today.map((p) => p.sport))].sort());
  const pack = today.find((p) => p.sport === sport) ?? today[0];
  return { pack, others: today.length - 1 };
}
