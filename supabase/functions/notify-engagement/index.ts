// Runs hourly (pg_cron: supabase/migrations/0018_notify_engagement.sql). Owns the two slots
// added to reach a three-a-day cadence, alongside the existing 9am drop:
//
//   09:00 local  notify-daily-drop     "today's puzzles just dropped"
//   13:00 local  THIS, "your move"     the most urgent true thing this player could do now
//   20:00 local  notify-streak-risk    streak at risk -> otherwise THIS, the evening recap
//
// **Each slot picks from a priority chain of things that are actually true**, rather than
// firing a fixed message to hit a number. That distinction is the whole design: App Review
// 4.5.4 forbids push as a promotional channel and Apple can revoke push privileges for abuse,
// so a slot that has nothing true left to say sends nothing. In practice an active player has
// something in every chain — there are 30 ladder rungs and a live league position on any given
// day — so three is the normal outcome without ever manufacturing one.
//
// The cap, the once-per-day guard and the audit row all live in `_shared/cadence.ts`; this file
// only decides *what* is worth saying.
import { serviceClient } from "../_shared/supabase.ts";
import {
  buildEveningRecapPayload,
  buildLadderNudgePayload,
  buildLeagueNudgePayload,
  buildYourTurnPayload,
  type PushPayload,
} from "../_shared/apns.ts";
import { categoryEnabled, sendOnce } from "../_shared/cadence.ts";
import { localDayString, localHour } from "../_shared/localtime.ts";

const MIDDAY_HOUR = 13;
const EVENING_HOUR = 20;

// deno-lint-ignore no-explicit-any
type Client = any;

/** An open duel where it's this player's turn, soonest to expire first. The most urgent thing
 * the app can legitimately interrupt someone for: it has a real deadline and a real opponent. */
async function yourTurn(sb: Client, userId: string, nowMs: number): Promise<PushPayload | null> {
  const { data: duels } = await sb
    .from("versus_challenges")
    .select("challenger_id, opponent_id, challenger_score, opponent_score, expires_at")
    .eq("status", "pending")
    .or(`challenger_id.eq.${userId},opponent_id.eq.${userId}`)
    .order("expires_at", { ascending: true });

  for (const d of duels ?? []) {
    const mine = d.challenger_id === userId ? d.challenger_score : d.opponent_score;
    if (mine !== null) continue;                       // already played; nothing to do
    const otherId = d.challenger_id === userId ? d.opponent_id : d.challenger_id;
    const { data: profile } = await sb
      .from("profiles").select("username").eq("id", otherId).maybeSingle();
    const hoursLeft = Math.max(
      1, Math.round((new Date(d.expires_at).getTime() - nowMs) / 3_600_000));
    return buildYourTurnPayload(profile?.username ?? "Your opponent", hoursLeft);
  }
  return null;
}

/** The next rung, named. Silent once the ladder is cleared — there is genuinely nothing left. */
async function nextRung(sb: Client, userId: string): Promise<PushPayload | null> {
  const { data: progress } = await sb
    .from("ladder_progress").select("highest_rung").eq("user_id", userId).maybeSingle();
  const next = (progress?.highest_rung ?? 0) + 1;

  const { data: rung } = await sb
    .from("ladder_rungs").select("rung, bot_id").eq("rung", next).maybeSingle();
  if (!rung) return null;

  const { data: bot } = await sb
    .from("bots").select("name").eq("id", rung.bot_id).maybeSingle();
  return buildLadderNudgePayload(bot?.name ?? "Your next opponent", rung.rung);
}

/** Live cohort standing. Only sent with a real position in a real active cohort. */
async function leagueStanding(sb: Client, userId: string): Promise<PushPayload | null> {
  const { data: me } = await sb
    .from("cohort_members").select("cohort_id, weekly_xp")
    .eq("user_id", userId).order("joined_at", { ascending: false }).limit(1).maybeSingle();
  if (!me) return null;

  const { data: board } = await sb
    .from("cohort_members").select("user_id, weekly_xp")
    .eq("cohort_id", me.cohort_id).order("weekly_xp", { ascending: false });
  if (!board || board.length < 2) return null;         // a league of one is not a standing

  const rank = board.findIndex((r: { user_id: string }) => r.user_id === userId) + 1;
  if (rank < 1) return null;
  const above = rank > 1 ? board[rank - 2].weekly_xp - me.weekly_xp : 0;
  return buildLeagueNudgePayload(rank, Math.max(0, above));
}

/** The evening slot for someone who already played, so `notify-streak-risk` will stay silent.
 * Reports what actually happened today rather than inventing a reason to buzz. */
async function eveningRecap(
  sb: Client, userId: string, localDay: string, streak: number,
): Promise<PushPayload | null> {
  const { count } = await sb
    .from("ladder_attempts")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId).eq("won", true)
    .gte("created_at", `${localDay}T00:00:00Z`);
  if (streak <= 0 && (count ?? 0) === 0) return null;  // nothing happened; say nothing
  return buildEveningRecapPayload(streak, count ?? 0);
}

Deno.serve(async (req) => {
  const sb = serviceClient();
  const nowMs = Date.now();
  // `?dry=1` resolves every decision and reports what *would* go out, sending nothing and
  // logging nothing — so a cadence change can be inspected against real users before it buzzes
  // anyone. Used to verify this function before its cron was enabled.
  const params = new URL(req.url).searchParams;
  const dry = params.get("dry") === "1";
  // `?slot=midday|evening` resolves that slot for everyone regardless of their local hour.
  // **Dry-run only, deliberately** — it exists to inspect the copy each real user would get
  // without waiting for their 1pm, and honouring it on a live send would buzz people off
  // schedule, which is exactly the failure this whole file is careful about.
  const forceSlot = dry ? params.get("slot") : null;

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
  const planned: Array<Record<string, unknown>> = [];

  for (const t of tokens ?? []) {
    const hour = localHour(t.utc_offset_minutes, nowMs);
    const slot = forceSlot
      ?? (hour === MIDDAY_HOUR ? "midday" : hour === EVENING_HOUR ? "evening" : null);
    if (!slot) continue;
    if (!await categoryEnabled(sb, t.user_id, "engagement")) continue;

    const localDay = localDayString(t.utc_offset_minutes, nowMs);
    const { data: progress } = await sb
      .from("progress").select("streak, last_played_day")
      .eq("user_id", t.user_id).maybeSingle();

    let payload: PushPayload | null = null;
    if (slot === "midday") {
      // Most urgent first: a duel with a deadline, then the ladder, then the league.
      payload = await yourTurn(sb, t.user_id, nowMs)
        ?? await nextRung(sb, t.user_id)
        ?? await leagueStanding(sb, t.user_id);
    } else {
      // 8pm. If they haven't played, `notify-streak-risk` owns this slot and will fire on its
      // own — stepping in would double up. Only take the slot when it will otherwise be empty.
      const playedToday = progress?.last_played_day === localDay;
      const streakAtRisk = (progress?.streak ?? 0) > 0 && !playedToday;
      if (streakAtRisk) continue;
      payload = playedToday
        ? await eveningRecap(sb, t.user_id, localDay, progress?.streak ?? 0)
        : await yourTurn(sb, t.user_id, nowMs) ?? await nextRung(sb, t.user_id);
    }
    if (!payload) continue;

    if (dry) {
      planned.push({ user: t.user_id, slot, category: payload.category, title: payload.title,
                     body: payload.body });
      continue;
    }
    const result = await sendOnce(sb, {
      userId: t.user_id, tokens: t.tokens, utcOffsetMinutes: t.utc_offset_minutes,
      nowMs, payload,
    });
    if (result.sent) sent++;
  }

  const summary = { checked: tokens?.length ?? 0, sent, dry, planned: dry ? planned : undefined };
  console.log(`[engagement] ${JSON.stringify(summary)}`);
  return new Response(JSON.stringify(summary), {
    headers: { "Content-Type": "application/json" },
  });
});
