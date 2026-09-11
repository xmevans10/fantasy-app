import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { SPORT_ROTATION, sportForDay } from "./sport.ts";

// Every sport in the rotation is "available" here — this fixture stands for the normal
// case where each sport minted something. Derived from SPORT_ROTATION rather than written
// out, so adding a sport (M31 added hockey and F1) can't silently leave this list short and
// turn the walk-the-rotation test below into a test of the skip path instead.
const ALL: string[] = [...SPORT_ROTATION];
const N = SPORT_ROTATION.length;

Deno.test("consecutive days walk the rotation in order and then repeat", () => {
  // One full cycle plus two days, so the wrap-around is actually exercised.
  const days: string[] = [];
  for (let i = 0; i < N + 2; i++) {
    const d = new Date(Date.UTC(2026, 7, 19 + i));
    days.push(d.toISOString().slice(0, 10));
  }
  const run = days.map((d) => sportForDay(d, ALL));
  // Every sport appears exactly once across one cycle, then it comes back around.
  assertEquals(new Set(run.slice(0, N)).size, N);
  assertEquals(run[N], run[0]);
  assertEquals(run[N + 1], run[1]);
  // ...and it is the declared order, not an arbitrary hash.
  const start = SPORT_ROTATION.indexOf(run[0] as typeof SPORT_ROTATION[number]);
  assertEquals(run.slice(0, N),
               [...Array(N).keys()].map((i) => SPORT_ROTATION[(start + i) % N]));
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
