// Runs hourly (pg_cron: supabase/migrations/0002_notify_daily_drop.sql). Finds users whose
// device-reported local time is currently ~9am and who haven't played today, and sends the
// "today's puzzles just dropped" push — with the actual minted K4C4 theme in the copy when
// today's row exists, so the notification proves the content is new instead of asserting it.
//
// Same local-time caveat as notify-streak-risk: `device_tokens.utc_offset_minutes` is the
// offset at registration, which drifts if the user travels. Good enough for a 9am-ish nudge.
import { serviceClient } from "../_shared/supabase.ts";
import { buildDailyDropPayload } from "../_shared/apns.ts";
import { DEVICE_TOKEN_COLUMNS, pushRecipients, sendOnce } from "../_shared/cadence.ts";
import { candidateLocalDays, localDayString, localHour } from "../_shared/localtime.ts";
import { favouriteSport, rotatingSport } from "../_shared/sport.ts";

const TARGET_LOCAL_HOUR = 9; // 9am

/** How far back play history counts toward "your sport". Long enough to survive a quiet
 * fortnight, short enough that someone who has moved from baseball to NFL stops being told
 * about baseball. */
const PLAY_WINDOW_MS = 60 * 24 * 60 * 60 * 1000; // 60 days

Deno.serve(async (_req) => {
  const sb = serviceClient();
  const nowMs = Date.now();

  // The minted K4C4 themes, indexed by (day → sport → theme).
  //
  // Both dimensions are load-bearing. Sport, because daily_puzzle.py mints every sport its
  // own canonical pick and a push naming a sport the user never plays is noise. Day, because
  // the app resolves the daily by the DEVICE's local calendar day (2026-07-28 local-midnight
  // rollover, `PuzzleStore.localDayString`) — this function used to fetch one UTC day's rows
  // for every device on the theory that one instant is one day, which is false across a
  // 26-hour offset range: at 9am local in Auckland the server's UTC clock still reads
  // yesterday, so the push would have named yesterday's theme while the app showed today's.
  // Three days is the complete set (see `candidateLocalDays`), and still one query.
  const days = candidateLocalDays(nowMs);

  // `puzzle_history` — not `puzzles.active_date` — is what identifies the canonical daily.
  //
  // active_date is ALSO stamped in bulk across the trailing archive window by main.py's
  // `assign_active_dates`, so several keep4 rows can share one date for one sport (live on
  // 2026-08-18: seven for NFL on 2026-08-17). Selecting on active_date alone therefore named
  // whichever row PostgREST happened to return last — routinely a stale archive row rather
  // than the puzzle the app actually shows. daily_puzzle.py writes exactly one
  // `puzzle_history` row per (served_date, sport, format), which is the mint itself, so
  // resolving through it is the only way to name the row the player will open.
  const { data: historyRows } = await sb
    .from("puzzle_history").select("sport, puzzle_id, served_date")
    .eq("format", "keep4").in("served_date", days);
  const dailyIds = (historyRows ?? []).map((r) => r.puzzle_id as string);
  const { data: dailyRows } = dailyIds.length
    ? await sb.from("puzzles").select("id, content").in("id", dailyIds)
    : { data: [] as Array<{ id: string; content: unknown }> };
  const themeById = new Map<string, string>();
  for (const row of dailyRows ?? []) {
    const theme = (row.content as { theme?: string } | undefined)?.theme;
    if (theme) themeById.set(row.id as string, theme);
  }
  const themesByDay = new Map<string, Map<string, string>>();
  for (const row of historyRows ?? []) {
    const theme = themeById.get(row.puzzle_id as string);
    if (!theme) continue;
    const day = row.served_date as string;
    if (!themesByDay.has(day)) themesByDay.set(day, new Map());
    themesByDay.get(day)!.set(row.sport as string, theme);
  }

  // One decision per PERSON, delivered to all of their devices, each on the APNs host its own
  // token was minted for — see `pushRecipients`.
  const { data: rows } = await sb
    .from("device_tokens").select(DEVICE_TOKEN_COLUMNS);
  const tokens = pushRecipients(rows);

  // Which sport each recipient actually plays, from `game_results`.
  //
  // `profiles.primary_sport` is the field this used to read, and it is NULL for every profile
  // in production (11/11 on 2026-08-19) — nothing in the app ever sets it. So the lookup always
  // missed and every push fell through to "first entry of the themes map", which is baseball,
  // because daily_puzzle.py mints sports in sorted order and PostgREST returns them that way.
  // Result: every user got BASEBALL's theme every single day, and baseball drew a pitching
  // theme on 7 of 8 days, so the push read "Ace pitching seasons" over and over — to people
  // whose actual play history was 14 NFL games and 3 baseball.
  //
  // One batched query, aggregated per user in memory; a per-recipient query would be N+1 for
  // a value that is cheap to fetch once.
  const userIds = tokens.map((t) => t.user_id);
  const { data: playRows } = userIds.length
    ? await sb.from("game_results").select("user_id, sport")
        .in("user_id", userIds).gte("played_at", new Date(nowMs - PLAY_WINDOW_MS).toISOString())
    : { data: [] as Array<{ user_id: string; sport: string }> };
  const playsByUser = new Map<string, Map<string, number>>();
  for (const r of playRows ?? []) {
    if (!r.sport) continue;
    const counts = playsByUser.get(r.user_id) ?? new Map<string, number>();
    counts.set(r.sport, (counts.get(r.sport) ?? 0) + 1);
    playsByUser.set(r.user_id, counts);
  }

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

    // Lead with the sport this person actually plays. Read from THIS device's local day (see
    // the index comment above), so a push can never name a different day's puzzle; with no
    // themes for the day at all, `null` degrades to the generic drop copy.
    const themesBySport = themesByDay.get(localToday);
    const available = [...(themesBySport?.keys() ?? [])].sort();
    const sport = favouriteSport(playsByUser.get(t.user_id), available)
      ?? rotatingSport(localToday, available);
    const theme = (sport && themesBySport?.get(sport)) || null;

    // Through `sendOnce` so this counts against the same daily ceiling as the other slots and
    // leaves an audit row — see _shared/cadence.ts.
    const result = await sendOnce(sb, {
      userId: t.user_id, tokens: t.tokens, utcOffsetMinutes: t.utc_offset_minutes,
      nowMs, payload: buildDailyDropPayload(theme, sport),
    });
    if (result.sent) sent++;
  }

  const themeCount = [...themesByDay.values()].reduce((n, m) => n + m.size, 0);
  console.log(`[daily-drop] days=${days.join(",")} themes=${themeCount} ` +
    `checked=${tokens?.length ?? 0} sent=${sent}`);
  return new Response(JSON.stringify({ checked: tokens?.length ?? 0, sent, themes: themeCount }), {
    headers: { "Content-Type": "application/json" },
  });
});
