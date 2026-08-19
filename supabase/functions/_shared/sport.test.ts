import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { favouriteSport, rotatingSport } from "./sport.ts";

const DAY_SPORTS = ["baseball", "nba", "nfl", "soccer", "tennis"];

Deno.test("favouriteSport picks what the user actually plays, not what sorts first", () => {
  // The live case on 2026-08-19: 14 NFL games to 3 baseball, being told about baseball daily.
  const counts = new Map([["nfl", 14], ["baseball", 3], ["nba", 3]]);
  assertEquals(favouriteSport(counts, DAY_SPORTS), "nfl");
});

Deno.test("favouriteSport ignores sports with no puzzle today", () => {
  // They play soccer most, but soccer's mint is missing for this day.
  const counts = new Map([["soccer", 20], ["nba", 2]]);
  assertEquals(favouriteSport(counts, ["baseball", "nba"]), "nba");
});

Deno.test("favouriteSport returns null with no history, so the caller can rotate", () => {
  assertEquals(favouriteSport(undefined, DAY_SPORTS), null);
  assertEquals(favouriteSport(new Map(), DAY_SPORTS), null);
  // Counts that are all for unavailable sports are also "no signal", not a zero-count pick.
  assertEquals(favouriteSport(new Map([["tennis", 5]]), ["nba"]), null);
});

Deno.test("favouriteSport breaks ties by the caller's sorted order, not map order", () => {
  const insertionOrder = new Map([["tennis", 4], ["baseball", 4]]);
  assertEquals(favouriteSport(insertionOrder, DAY_SPORTS), "baseball");
  // Same counts, opposite insertion order — must not change the answer.
  const reversed = new Map([["baseball", 4], ["tennis", 4]]);
  assertEquals(favouriteSport(reversed, DAY_SPORTS), "baseball");
});

Deno.test("rotatingSport spreads a new user's first week across sports", () => {
  const week = ["2026-08-19", "2026-08-20", "2026-08-21", "2026-08-22",
                "2026-08-23", "2026-08-24", "2026-08-25"]
    .map((d) => rotatingSport(d, DAY_SPORTS));
  // The whole point: not seven days of the same sport.
  assertEquals(new Set(week).size > 1, true);
  assertEquals(week.every((s) => s !== null && DAY_SPORTS.includes(s)), true);
});

Deno.test("rotatingSport is deterministic per day and safe when nothing is minted", () => {
  assertEquals(rotatingSport("2026-08-19", DAY_SPORTS), rotatingSport("2026-08-19", DAY_SPORTS));
  assertEquals(rotatingSport("2026-08-19", []), null);
  assertEquals(rotatingSport("2026-08-19", ["nba"]), "nba");
});
