import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { tierForRating } from "./season_tiers.ts";
import { buildRatingSeasonClosedPayload } from "./apns.ts";

// Band boundaries must match Swift's Tier ranges (bronze 0–999, silver 1000–1199, gold 1200–1399,
// platinum 1400–1599, diamond 1600–1799, legend 1800+). A drift here mis-labels earned badges.
Deno.test("tierForRating matches the Swift tier bands at the boundaries", () => {
  assertEquals(tierForRating(0), "bronze");
  assertEquals(tierForRating(999), "bronze");
  assertEquals(tierForRating(1000), "silver");
  assertEquals(tierForRating(1199), "silver");
  assertEquals(tierForRating(1200), "gold");
  assertEquals(tierForRating(1399), "gold");
  assertEquals(tierForRating(1400), "platinum");
  assertEquals(tierForRating(1599), "platinum");
  assertEquals(tierForRating(1600), "diamond");
  assertEquals(tierForRating(1799), "diamond");
  assertEquals(tierForRating(1800), "legend");
  assertEquals(tierForRating(5000), "legend");
});

Deno.test("season-closed push capitalizes the tier and points at Leagues", () => {
  const p = buildRatingSeasonClosedPayload("platinum");
  assertEquals(p.category, "season_end");
  assertEquals(p.title, "Season complete!");
  assertEquals(p.body.includes("Platinum"), true);
  assertEquals(p.data, { tab: "leagues" });
});
