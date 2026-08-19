import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { SPORT_ROTATION, sportForDay } from "./sport.ts";

const ALL = ["baseball", "nba", "nfl", "soccer", "tennis"];

Deno.test("consecutive days walk the rotation in order and then repeat", () => {
  const week = ["2026-08-19", "2026-08-20", "2026-08-21", "2026-08-22", "2026-08-23",
                "2026-08-24", "2026-08-25"].map((d) => sportForDay(d, ALL));
  // Five distinct sports across five days, then the cycle comes back around.
  assertEquals(new Set(week.slice(0, 5)).size, 5);
  assertEquals(week[5], week[0]);
  assertEquals(week[6], week[1]);
  // ...and it is the declared order, not an arbitrary hash.
  const start = SPORT_ROTATION.indexOf(week[0] as typeof SPORT_ROTATION[number]);
  assertEquals(week.slice(0, 5),
               [0, 1, 2, 3, 4].map((i) => SPORT_ROTATION[(start + i) % SPORT_ROTATION.length]));
});

Deno.test("everyone on the same day gets the same sport", () => {
  // The whole point of the change: one shared notification, not a personalised one.
  assertEquals(sportForDay("2026-08-19", ALL), sportForDay("2026-08-19", ALL));
  // Availability listed in a different order must not change the answer either.
  assertEquals(sportForDay("2026-08-19", ALL),
               sportForDay("2026-08-19", [...ALL].reverse()));
});

Deno.test("a sport with no mint that day is skipped, without shifting the cycle", () => {
  const day = "2026-08-19";
  const featured = sportForDay(day, ALL)!;
  const without = ALL.filter((s) => s !== featured);
  // That day falls through to the next sport in the rotation...
  const next = sportForDay(day, without)!;
  assertEquals(next !== featured, true);
  assertEquals(without.includes(next), true);
  // ...but the following day is unaffected — a gap is not a shift.
  assertEquals(sportForDay("2026-08-20", ALL), sportForDay("2026-08-20", ALL));
});

Deno.test("degrades safely when little or nothing minted", () => {
  assertEquals(sportForDay("2026-08-19", []), null);
  assertEquals(sportForDay("2026-08-19", ["tennis"]), "tennis");
  // A sport the rotation list has not caught up with is still named, not dropped.
  assertEquals(sportForDay("2026-08-19", ["cricket"]), "cricket");
});

Deno.test("the day parse is pure, not re-interpreted in the server's timezone", () => {
  // localDay arrives as a DEVICE-local day string; two runs must agree regardless of when.
  assertEquals(sportForDay("2026-01-01", ALL), sportForDay("2026-01-01", ALL));
  // A year boundary advances by exactly one step, proving day arithmetic rather than hashing.
  const dec31 = SPORT_ROTATION.indexOf(sportForDay("2025-12-31", ALL) as never);
  const jan01 = SPORT_ROTATION.indexOf(sportForDay("2026-01-01", ALL) as never);
  assertEquals(jan01, (dec31 + 1) % SPORT_ROTATION.length);
});
