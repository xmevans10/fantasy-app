// Runs hourly (pg_cron: supabase/migrations/0002_notify_daily_drop.sql). Finds users whose
// device-reported local time is currently ~9am and who haven't played today, and sends the
// "today's puzzles just dropped" push — with the actual minted K4C4 theme in the copy when
// today's row exists, so the notification proves the content is new instead of asserting it.
//
// Same local-time caveat as notify-streak-risk: `device_tokens.utc_offset_minutes` is the
// offset at registration, which drifts if the user travels. Good enough for a 9am-ish nudge.
import { serviceClient } from "../_shared/supabase.ts";
import { buildDailyDropPayload, sendApnsPush } from "../_shared/apns.ts";
import { localDayString, localHour } from "../_shared/localtime.ts";

const TARGET_LOCAL_HOUR = 9; // 9am

Deno.serve(async (_req) => {
  const sb = serviceClient();
  const nowMs = Date.now();

  // Today's minted K4C4 theme, if daily-puzzle.yml has landed it. The daily is keyed by UTC
  // day (`active_date`, same as the app's fetch) — one lookup shared by every push this run,
  // since all devices at 9am local share this same UTC instant.
  const utcToday = new Date(nowMs).toISOString().slice(0, 10);
  const { data: dailyRows } = await sb
    .from("puzzles").select("content").eq("format", "keep4").eq("active_date", utcToday).limit(1);
  const theme = (dailyRows?.[0]?.content as { theme?: string } | undefined)?.theme ?? null;

  const { data: tokens } = await sb
    .from("device_tokens").select("user_id, token, utc_offset_minutes");

  let sent = 0;

  for (const t of tokens ?? []) {
    if (localHour(t.utc_offset_minutes, nowMs) !== TARGET_LOCAL_HOUR) continue;

    const { data: settings } = await sb
      .from("notification_settings").select("daily_drop").eq("user_id", t.user_id).maybeSingle();
    if (settings && settings.daily_drop === false) continue;

    // Skip anyone who already played today (local day, same convention as streak-risk).
    // Unlike streak-risk there's no streak>0 gate — brand-new and lapsed users are exactly
    // who a morning drop should reach — and a missing progress row still gets the push.
    const localToday = localDayString(t.utc_offset_minutes, nowMs);
    const { data: progress } = await sb
      .from("progress").select("last_played_day").eq("user_id", t.user_id).maybeSingle();
    if (progress?.last_played_day === localToday) continue;

    await sendApnsPush(t.token, buildDailyDropPayload(theme))
      .catch((e) => console.error("push failed", e));
    sent++;
  }

  console.log(`[daily-drop] theme=${theme ?? "(none)"} checked=${tokens?.length ?? 0} sent=${sent}`);
  return new Response(JSON.stringify({ checked: tokens?.length ?? 0, sent, theme }), {
    headers: { "Content-Type": "application/json" },
  });
});
