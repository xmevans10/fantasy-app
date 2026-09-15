import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { buildWeekPackPayload } from "./apns.ts";
import { PACK_MIN_BUILD, packCapable, packForDay, type PublishedPack } from "./week_packs.ts";

const nfl: PublishedPack = { id: "nfl-2026-wk01", sport: "nfl", label: "2026 Week 1",
  release_date: "2026-09-16", boards: 5, headline: "2026 Week 1: top performances" };
const mlb: PublishedPack = { id: "baseball-2026-09-07-to-2026-09-13", sport: "baseball",
  label: "Sep 7 to 13", release_date: "2026-09-17", boards: 4, headline: null };

Deno.test("a pack is announced only on its own release day", () => {
  assertEquals(packForDay([nfl], "2026-09-15"), null);
  assertEquals(packForDay([nfl], "2026-09-16")?.pack.id, "nfl-2026-wk01");
  assertEquals(packForDay([nfl], "2026-09-17"), null);
});

Deno.test("an empty pack is never announced", () => {
  assertEquals(packForDay([{ ...nfl, boards: 0 }], "2026-09-16"), null);
});

Deno.test("two packs on one day become one push that counts the other", () => {
  const nba = { ...mlb, id: "nba-x", sport: "nba", release_date: "2026-09-17" };
  const pick = packForDay([mlb, nba], "2026-09-17");
  assertEquals(pick?.others, 1);
});

Deno.test("builds older than the pack UI, and unknown builds, get no pack push", () => {
  const tokens = [
    { token: "old", environment: "production" as const, app_build: PACK_MIN_BUILD - 1 },
    { token: "unknown", environment: "production" as const, app_build: null },
    { token: "new", environment: "production" as const, app_build: PACK_MIN_BUILD },
  ];
  assertEquals(packCapable(tokens).map((t) => t.token), ["new"]);
});

Deno.test("pack payload names sport, week and lead board, with no em dash", () => {
  const p = buildWeekPackPayload(nfl);
  assertEquals(p.category, "week_pack");
  assertEquals(p.title, "Your NFL Week 1 Pack is here");
  assertEquals(p.body, "5 boards on the week that just ended, led by “Top performances”.");
  assertEquals(p.data, { tab: "home", sport: "nfl", pack: "nfl-2026-wk01" });
  assertEquals(p.body.includes("—") || p.title.includes("—"), false);
});

Deno.test("pack payload without a lead board, plus a second pack the same day", () => {
  const p = buildWeekPackPayload(mlb, 1);
  assertEquals(p.title, "Your MLB Sep 7 to 13 Pack is here");
  assertEquals(p.body, "4 boards on the week that just ended. Plus 1 more pack today.");
});
