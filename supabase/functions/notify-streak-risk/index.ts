// Runs hourly (hand-off: schedule via pg_cron). Finds users whose device-reported local time is
// currently ~8pm and who haven't played today, and sends the streak-at-risk push.
//
// Design note (flagged): there's no per-user IANA timezone in the schema yet, only the UTC offset
// captured at device-token registration (`device_tokens.utc_offset_minutes`), which drifts if the
// user travels. Good enough for "simplest correct version first"; revisit if DST/travel complaints
// show up.
import { serviceClient } from "../_shared/supabase.ts";
import { buildStreakAtRiskPayload, sendApnsPush } from "../_shared/apns.ts";

const TARGET_LOCAL_HOUR = 20; // 8pm

Deno.serve(async (_req) => {
  const sb = serviceClient();
  const nowUtcMinutes = new Date().getUTCHours() * 60 + new Date().getUTCMinutes();

  const { data: tokens } = await sb
    .from("device_tokens").select("user_id, token, utc_offset_minutes");

  const today = new Date().toISOString().slice(0, 10);
  let sent = 0;

  for (const t of tokens ?? []) {
    const localMinutes = ((nowUtcMinutes + t.utc_offset_minutes) % 1440 + 1440) % 1440;
    const localHour = Math.floor(localMinutes / 60);
    if (localHour !== TARGET_LOCAL_HOUR) continue;

    const { data: settings } = await sb
      .from("notification_settings").select("streak_at_risk").eq("user_id", t.user_id).maybeSingle();
    if (settings && settings.streak_at_risk === false) continue;

    const { data: progress } = await sb
      .from("progress").select("streak, last_played_day").eq("user_id", t.user_id).maybeSingle();
    if (!progress || progress.streak <= 0 || progress.last_played_day === today) continue;

    await sendApnsPush(t.token, buildStreakAtRiskPayload(progress.streak))
      .catch((e) => console.error("push failed", e));
    sent++;
  }

  return new Response(JSON.stringify({ checked: tokens?.length ?? 0, sent }), {
    headers: { "Content-Type": "application/json" },
  });
});
