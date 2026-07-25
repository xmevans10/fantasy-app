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

  // Today's minted K4C4 themes, if daily-puzzle.yml has landed them — one row PER SPORT now
  // (daily_puzzle.py mints every sport its own canonical pick), so this is a sport→theme map
  // rather than a single shared theme. One lookup shared by every push this run, since all
  // devices at 9am local share this same UTC instant (`active_date` is keyed by UTC day,
  // same as the app's fetch).
  const utcToday = new Date(nowMs).toISOString().slice(0, 10);
  const { data: dailyRows } = await sb
    .from("puzzles").select("sport, content").eq("format", "keep4").eq("active_date", utcToday);
  const themesBySport = new Map<string, string>();
  for (const row of dailyRows ?? []) {
    const theme = (row.content as { theme?: string } | undefined)?.theme;
    if (theme) themesBySport.set(row.sport as string, theme);
  }
  // Copy fallback when a user's sport can't be resolved: any minted theme beats a bare
  // "new puzzles dropped" assertion, same reasoning as the original single-theme design.
  const anyTheme = themesBySport.values().next().value ?? null;

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

    // Lead with the user's own sport's theme when their profile declares one — with every
    // sport minting daily, a generic theme could name a sport this user never plays.
    const { data: profile } = await sb
      .from("profiles").select("primary_sport").eq("id", t.user_id).maybeSingle();
    const theme = (profile?.primary_sport && themesBySport.get(profile.primary_sport)) || anyTheme;

    await sendApnsPush(t.token, buildDailyDropPayload(theme))
      .catch((e) => console.error("push failed", e));
    sent++;
  }

  console.log(`[daily-drop] themes=${themesBySport.size} checked=${tokens?.length ?? 0} sent=${sent}`);
  return new Response(JSON.stringify({ checked: tokens?.length ?? 0, sent, themes: themesBySport.size }), {
    headers: { "Content-Type": "application/json" },
  });
});
