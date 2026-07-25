// M5 Phase F — closes the active 8-week rating season and opens the next. Clones the
// `weekly-cohort-rollover` structure (service-role client, self-gating cron): the DB cron fires
// this weekly, but it no-ops unless the active season has actually reached its `ends_at`, since
// pg_cron has no native 8-week expression (see supabase/migrations/0003_*).
//
// On a real rollover it (1) mints each participant's end-of-season badge from the peak tier they
// reached (`season_ratings.peak_rating`), (2) marks the season closed, (3) opens the next season
// (starts = old ends, ends = +8 weeks). Season ratings are seeded client-side on the first ranked
// game of the new season (soft-reset of the all-time rating), so nothing is pre-created here.
import { serviceClient } from "../_shared/supabase.ts";
import { buildRatingSeasonClosedPayload, sendApnsPush } from "../_shared/apns.ts";
import { tierForRating } from "../_shared/season_tiers.ts";

const CYCLE_WEEKS = 8;

Deno.serve(async (_req) => {
  const sb = serviceClient();

  const { data: active } = await sb
    .from("rating_seasons").select("id, ends_at").eq("status", "active").maybeSingle();

  // Self-gate: only roll over once the active season has actually ended. A weekly cron tick before
  // then is a no-op (mirrors how the season boundary, not the cron cadence, drives the rollover).
  if (!active) {
    return json({ rolled: false, reason: "no active season" });
  }
  if (new Date(active.ends_at).getTime() > Date.now()) {
    return json({ rolled: false, reason: "season not yet ended", endsAt: active.ends_at });
  }

  // 1) Mint badges from each participant's peak (best per user+sport). Insert-if-absent so a retried
  //    run never double-writes (the table's PK is (season_id, user_id, sport)).
  const { data: peaks } = await sb
    .from("season_ratings")
    .select("user_id, sport, peak_rating")
    .eq("season_id", active.id);

  let badges = 0;
  // Per user, the highest tier they reached across sports — that's what the "season complete" push
  // celebrates (a player can have badges in several sports; the push names their best).
  const bestTier = new Map<string, { rating: number; tier: string }>();
  for (const row of peaks ?? []) {
    const tier = tierForRating(row.peak_rating);
    const { error } = await sb.from("season_badges").upsert({
      season_id: active.id,
      user_id: row.user_id,
      sport: row.sport,
      peak_tier: tier,
      peak_rating: row.peak_rating,
    }, { onConflict: "season_id,user_id,sport", ignoreDuplicates: true });
    if (!error) {
      badges++;
      const prev = bestTier.get(row.user_id);
      if (!prev || row.peak_rating > prev.rating) bestTier.set(row.user_id, { rating: row.peak_rating, tier });
    }
  }

  // 2) Close the finished season.
  await sb.from("rating_seasons").update({ status: "closed" }).eq("id", active.id);

  // 3) Open the next one, contiguous with the old (starts where the last ended).
  const startsAt = new Date(active.ends_at);
  const endsAt = new Date(startsAt.getTime() + CYCLE_WEEKS * 7 * 24 * 60 * 60 * 1000);
  const { data: next, error: nextErr } = await sb
    .from("rating_seasons")
    .insert({ starts_at: startsAt.toISOString(), ends_at: endsAt.toISOString() })
    .select("id").single();
  if (nextErr) throw nextErr;

  // Season-complete push to everyone who earned a badge (reuses the existing notify path + opt-out).
  for (const [userId, best] of bestTier) {
    const { data: settings } = await sb
      .from("notification_settings").select("season_end").eq("user_id", userId).maybeSingle();
    if (settings && settings.season_end === false) continue;
    const { data: tokens } = await sb.from("device_tokens").select("token").eq("user_id", userId);
    const payload = buildRatingSeasonClosedPayload(best.tier);
    for (const { token } of tokens ?? []) {
      await sendApnsPush(token, payload).catch((e) => console.error("push failed", e));
    }
  }

  return json({ rolled: true, closedSeason: active.id, nextSeason: next.id, badges });
});

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), { headers: { "Content-Type": "application/json" } });
}
