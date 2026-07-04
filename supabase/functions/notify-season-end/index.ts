// Runs a few times a day (hand-off: schedule via pg_cron). Notifies cohort members once their
// active season is within its final 24h window. Idempotent-ish: relies on the cron cadence being
// coarse enough (e.g. twice a day) that this doesn't spam — a `notified_at` column would be the
// next step if duplicate pushes turn out to be a problem.
import { serviceClient } from "../_shared/supabase.ts";
import { buildSeasonEndPayload, sendApnsPush } from "../_shared/apns.ts";

Deno.serve(async (_req) => {
  const sb = serviceClient();
  const now = new Date();
  const in24h = new Date(now.getTime() + 24 * 60 * 60 * 1000);

  const { data: season } = await sb
    .from("seasons")
    .select("id, ends_at")
    .eq("status", "active")
    .lte("ends_at", in24h.toISOString())
    .gte("ends_at", now.toISOString())
    .maybeSingle();
  if (!season) return new Response(JSON.stringify({ notified: 0 }), { status: 200 });

  const hoursRemaining = Math.round((new Date(season.ends_at).getTime() - now.getTime()) / 3_600_000);
  const { data: members } = await sb
    .from("cohort_members")
    .select("user_id")
    .eq("season_id", season.id);

  let notified = 0;
  for (const m of members ?? []) {
    const { data: settings } = await sb
      .from("notification_settings").select("season_end").eq("user_id", m.user_id).maybeSingle();
    if (settings && settings.season_end === false) continue;
    const { data: tokens } = await sb.from("device_tokens").select("token").eq("user_id", m.user_id);
    const payload = buildSeasonEndPayload(hoursRemaining);
    for (const { token } of tokens ?? []) {
      await sendApnsPush(token, payload).catch((e) => console.error("push failed", e));
    }
    notified++;
  }

  return new Response(JSON.stringify({ seasonId: season.id, notified }), {
    headers: { "Content-Type": "application/json" },
  });
});
