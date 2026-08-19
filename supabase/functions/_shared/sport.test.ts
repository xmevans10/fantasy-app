import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { DEFAULT_PUSH_SPORT, sportForPush } from "./sport.ts";

const ALL = ["baseball", "nba", "nfl", "soccer", "tennis"];

Deno.test("names the sport the user last played, not the one that sorts first", () => {
  // The live 2026-08-19 case: an NFL player being told about baseball every morning, because
  // baseball is simply what PostgREST returned first.
  assertEquals(sportForPush(["nfl", "baseball", "nba"], ALL), "nfl");
  assertEquals(sportForPush(["nba"], ALL), "nba");
});

Deno.test("recency wins over frequency, because the pager reads last-played", () => {
  // Fourteen NFL games, then one NBA game yesterday: Home opens on NBA, so the push says NBA.
  assertEquals(sportForPush(["nba", "nfl", "nfl", "nfl", "nfl"], ALL), "nba");
});

Deno.test("skips a last-played sport that has no board today", () => {
  // They last played soccer, but soccer's mint is missing for this day — fall to the next
  // most recent sport that actually has something to open.
  assertEquals(sportForPush(["soccer", "nba", "nfl"], ["baseball", "nba", "nfl"]), "nba");
});

Deno.test("no history mirrors the client's own NFL fallback", () => {
  // HomeView: `container.sportFilter.sport ?? .nfl`. A brand-new install lands on NFL.
  assertEquals(sportForPush([], ALL), DEFAULT_PUSH_SPORT);
  assertEquals(sportForPush([], ALL), "nfl");
});

Deno.test("names nothing rather than a sport the app will not show", () => {
  // Nothing minted at all → generic copy.
  assertEquals(sportForPush(["nfl"], []), null);
  // History and fallback both unavailable: naming any of these would promise a board the
  // pager does not open on.
  assertEquals(sportForPush(["soccer"], ["baseball", "tennis"]), null);
});
