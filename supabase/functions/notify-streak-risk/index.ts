// Runs hourly (hand-off: schedule via pg_cron). Finds users whose device-reported local time is
// currently ~8pm and who haven't played today, and sends the streak-at-risk push.
//
// Design note (flagged): there's no per-user IANA timezone in the schema yet, only the UTC offset
// captured at device-token registration (`device_tokens.utc_offset_minutes`), which drifts if the
// user travels. Good enough for "simplest correct version first"; revisit if DST/travel complaints
// show up.
import { serviceClient } from "../_shared/supabase.ts";
import { buildStreakAtRiskPayload } from "../_shared/apns.ts";
import { sendOnce } from "../_shared/cadence.ts";
import { localDayString, localHour } from "../_shared/localtime.ts";

const TARGET_LOCAL_HOUR = 20; // 8pm

Deno.serve(async (_req) => {
  const sb = serviceClient();
  const nowMs = Date.now();

  const { data: rows } = await sb
    .from("device_tokens").select("user_id, token, utc_offset_minutes");
  // One decision per PERSON, delivered to all of their devices. Iterating raw token rows
  // (the first version) evaluated a multi-device user once per device.
  const byUser = new Map<string, { user_id: string; utc_offset_minutes: number; tokens: string[] }>();
  for (const r of rows ?? []) {
    const e = byUser.get(r.user_id)
      ?? { user_id: r.user_id, utc_offset_minutes: r.utc_offset_minutes, tokens: [] };
    e.tokens.push(r.token);
    byUser.set(r.user_id, e);
  }
  const tokens = [...byUser.values()];

  let sent = 0;

  for (const t of tokens ?? []) {
    if (localHour(t.utc_offset_minutes, nowMs) !== TARGET_LOCAL_HOUR) continue;

    const { data: settings } = await sb
      .from("notification_settings").select("streak_at_risk").eq("user_id", t.user_id).maybeSingle();
    if (settings && settings.streak_at_risk === false) continue;

    // `last_played_day` is the app's LOCAL calendar day, so compare against the device's
    // local day — at 8pm US-Eastern the UTC day has already rolled over.
    const localToday = localDayString(t.utc_offset_minutes, nowMs);
    const { data: progress } = await sb
      .from("progress").select("streak, last_played_day").eq("user_id", t.user_id).maybeSingle();
    if (!progress || progress.streak <= 0 || progress.last_played_day === localToday) continue;

    // Through `sendOnce` so this counts against the same daily ceiling as the other slots and
    // leaves an audit row — see _shared/cadence.ts.
    const result = await sendOnce(sb, {
      userId: t.user_id, tokens: t.tokens, utcOffsetMinutes: t.utc_offset_minutes,
      nowMs, payload: buildStreakAtRiskPayload(progress.streak),
    });
    if (result.sent) sent++;
  }

  console.log(`[streak-risk] checked=${tokens?.length ?? 0} sent=${sent}`);
  return new Response(JSON.stringify({ checked: tokens?.length ?? 0, sent }), {
    headers: { "Content-Type": "application/json" },
  });
});
