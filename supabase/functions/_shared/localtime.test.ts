import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { localDayString, localHour } from "./localtime.ts";

// The production regression this file locks down: at 8pm US-Eastern (offset -240) the UTC
// clock reads 00:xx of the NEXT calendar day, so a UTC-day comparison against the app's
// local-time `last_played_day` never matches and the "already played today" suppression
// silently stops suppressing for every US-timezone user.
const T_0030_UTC_JUL17 = Date.UTC(2026, 6, 17, 0, 30); // 8:30pm Jul 16 in UTC-4

Deno.test("localHour: 00:30 UTC is 8pm the previous evening in UTC-4", () => {
  assertEquals(localHour(-240, T_0030_UTC_JUL17), 20);
});

Deno.test("localDayString: 00:30 UTC Jul 17 is still Jul 16 in UTC-4", () => {
  assertEquals(localDayString(-240, T_0030_UTC_JUL17), "2026-07-16");
});

Deno.test("localDayString: matches the UTC day for a zero offset", () => {
  assertEquals(localDayString(0, T_0030_UTC_JUL17), "2026-07-17");
});

Deno.test("localHour/localDayString: positive offset rolls forward across midnight", () => {
  const t = Date.UTC(2026, 6, 16, 23, 0); // 23:00 UTC Jul 16 = 12:00 Jul 17 in UTC+13
  assertEquals(localHour(780, t), 12);
  assertEquals(localDayString(780, t), "2026-07-17");
});

Deno.test("localHour: wraps negative local minutes back into 0-23", () => {
  const t = Date.UTC(2026, 6, 17, 2, 0); // 02:00 UTC = 18:00 previous day in UTC-8
  assertEquals(localHour(-480, t), 18);
  assertEquals(localDayString(-480, t), "2026-07-16");
});
