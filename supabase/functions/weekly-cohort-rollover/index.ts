// Runs once a week (hand-off: schedule via `select cron.schedule(...)` after enabling the
// `pg_cron` + `pg_net` extensions — see prompts/M4-social-retention.md). Closes the active
// season (computing each member's promotion/relegation zone from `weekly_xp`), then opens a
// fresh season and re-buckets every rated user into ~30-size cohorts by current best rating.
//
// Design note (flagged, not silently decided): cohort membership next season is driven purely
// by current best rating, not by `prior_zone` — the simplest version that's still correct per
// the brief ("simplest correct version first"). `prior_zone` is stored per member so the client
// can show "you were promoted/relegated" and so `notify-league-position` can target pushes; it
// does not yet bias *where* a promoted player lands. If a tighter coupling between zone and next
// cohort is wanted later, this is the place to add it.
import { serviceClient } from "../_shared/supabase.ts";
import { buildLeaguePositionPayload, sendApnsPush } from "../_shared/apns.ts";

const COHORT_SIZE = 30;
const PROMOTE_COUNT = 5;
const RELEGATE_COUNT = 5;

type Zone = "promoted" | "relegated" | "held";

Deno.serve(async (_req) => {
  const sb = serviceClient();

  const { data: activeSeason } = await sb
    .from("seasons").select("id").eq("status", "active").maybeSingle();

  const zoneByUser = new Map<string, Zone>();
  if (activeSeason) {
    const { data: cohorts } = await sb
      .from("cohorts").select("id").eq("season_id", activeSeason.id);

    for (const cohort of cohorts ?? []) {
      const { data: members } = await sb
        .from("cohort_members")
        .select("user_id, weekly_xp")
        .eq("cohort_id", cohort.id)
        .order("weekly_xp", { ascending: false });
      const n = members?.length ?? 0;
      const promoteCutoff = Math.min(PROMOTE_COUNT, Math.floor(n / 2));
      const relegateCutoff = Math.min(RELEGATE_COUNT, Math.floor(n / 2));
      (members ?? []).forEach((m, i) => {
        const zone: Zone = i < promoteCutoff ? "promoted"
          : i >= n - relegateCutoff ? "relegated"
          : "held";
        zoneByUser.set(m.user_id, zone);
      });
    }

    await sb.from("seasons").update({ status: "closed" }).eq("id", activeSeason.id);

    // Notify promoted/relegated players (the "held" middle stays quiet — not worth a push).
    for (const [userId, zone] of zoneByUser) {
      if (zone === "held") continue;
      const { data: settings } = await sb
        .from("notification_settings").select("league_position").eq("user_id", userId).maybeSingle();
      if (settings && settings.league_position === false) continue;
      const { data: tokens } = await sb.from("device_tokens").select("token").eq("user_id", userId);
      const payload = buildLeaguePositionPayload(zone);
      for (const { token } of tokens ?? []) {
        await sendApnsPush(token, payload).catch((e) => console.error("push failed", e));
      }
    }
  }

  const startsAt = new Date();
  const endsAt = new Date(startsAt.getTime() + 7 * 24 * 60 * 60 * 1000);
  const { data: season, error: seasonErr } = await sb
    .from("seasons")
    .insert({ starts_at: startsAt.toISOString(), ends_at: endsAt.toISOString() })
    .select("id").single();
  if (seasonErr) throw seasonErr;

  const { data: ratings } = await sb.from("ratings").select("user_id, rating");
  const bestByUser = new Map<string, number>();
  for (const r of ratings ?? []) {
    bestByUser.set(r.user_id, Math.max(bestByUser.get(r.user_id) ?? 0, r.rating));
  }
  const ranked = [...bestByUser.entries()].sort((a, b) => b[1] - a[1]);

  let cohortCount = 0;
  for (let i = 0; i < ranked.length; i += COHORT_SIZE) {
    const chunk = ranked.slice(i, i + COHORT_SIZE);
    const { data: cohort, error: cohortErr } = await sb
      .from("cohorts")
      .insert({ season_id: season.id, size_limit: COHORT_SIZE })
      .select("id").single();
    if (cohortErr) throw cohortErr;
    cohortCount++;

    const rows = chunk.map(([userId, rating]) => ({
      cohort_id: cohort.id,
      season_id: season.id,
      user_id: userId,
      joined_rating: rating,
      prior_zone: zoneByUser.get(userId) ?? null,
    }));
    const { error: memberErr } = await sb.from("cohort_members").insert(rows);
    if (memberErr) throw memberErr;
  }

  return new Response(
    JSON.stringify({ seasonId: season.id, cohorts: cohortCount, players: ranked.length }),
    { headers: { "Content-Type": "application/json" } },
  );
});
