// The one place a push is allowed to leave the building.
//
// Every `notify-*` function used to call `sendApnsPush` directly and forget. That was fine at one
// or two scheduled pushes a day; at three scheduled slots plus three trigger-driven categories
// (duel received, duel finished, friend request) a single eventful day could stack six or seven
// notifications on one person with nothing stopping it, and no record afterwards to prove it
// happened. Both halves of that are fixed here:
//
//   * `DAILY_PUSH_CAP` is a hard ceiling counted in the recipient's LOCAL day. It is a ceiling,
//     not a target — App Review 4.5.4 forbids push as a promotional channel and Apple can revoke
//     push privileges for abuse, so the callers send only when they have something true to say
//     and this stops them going past three even when several things are true at once.
//   * `notification_log` is written before the send, under a unique index on
//     (user_id, category, local_day). That makes the write the idempotency guard as well as the
//     audit trail: an hourly cron that double-fires — a retry, an overlapping run, clock skew at
//     an offset boundary — loses the race on the insert and simply doesn't send.
import { sendApnsPush, type PushPayload } from "./apns.ts";
import { localDayString } from "./localtime.ts";

/** Ceiling per recipient per local day, across every category. */
export const DAILY_PUSH_CAP = 3;

/** Categories that are a direct reply to something the recipient's opponent just did. They are
 * exempt from the cap because suppressing them breaks a mechanic rather than reducing noise:
 * a duel has a 24h clock, and "we didn't tell you it was your turn because you'd had three
 * pushes" is how someone loses a duel by forfeit for a reason they can't see. */
const CAP_EXEMPT: ReadonlySet<string> = new Set(["versus_challenge"]);

// deno-lint-ignore no-explicit-any
type Client = any;

/** How many pushes this user has already had on their own local day. */
export async function sentToday(
  sb: Client,
  userId: string,
  utcOffsetMinutes: number,
  nowMs: number,
): Promise<number> {
  const day = localDayString(utcOffsetMinutes, nowMs);
  const { count } = await sb
    .from("notification_log")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId)
    .eq("local_day", day);
  return count ?? 0;
}

export interface SendResult {
  sent: boolean;
  reason?: "capped" | "already_sent" | "failed";
}

/**
 * Log, then send. Returns whether it actually went out and why not if it didn't.
 *
 * The log write comes first on purpose. Writing after a successful send would leave the cap
 * open to a double-send whenever two runs overlap, and the failure mode of logging first is
 * strictly better: a push that is recorded but not delivered costs the user one slot of silence,
 * while a push delivered but not recorded costs them an extra buzz and hides it from the audit.
 */
export async function sendOnce(
  sb: Client,
  opts: {
    userId: string;
    /** **Every** device this user has registered. The cap and the once-per-day guard are per
     * *person*, but the delivery is per *device* — someone with an iPhone and an iPad should
     * get the notification on both. Keying the log by token instead would have let one person
     * collect three pushes for one event; keying delivery by the log (the first version of
     * this) silently dropped every device after the first. */
    tokens: string[];
    utcOffsetMinutes: number;
    nowMs: number;
    payload: PushPayload;
  },
): Promise<SendResult> {
  const { userId, tokens, utcOffsetMinutes, nowMs, payload } = opts;
  const day = localDayString(utcOffsetMinutes, nowMs);

  if (!CAP_EXEMPT.has(payload.category)) {
    if (await sentToday(sb, userId, utcOffsetMinutes, nowMs) >= DAILY_PUSH_CAP) {
      return { sent: false, reason: "capped" };
    }
  }

  const { error } = await sb
    .from("notification_log")
    .insert({ user_id: userId, category: payload.category, local_day: day });
  if (error) {
    // 23505 = unique violation: this category already went out today. Any other error is worth
    // seeing in the function log, but neither case should send.
    if (error.code !== "23505") console.error("[cadence] log insert failed", error);
    return { sent: false, reason: "already_sent" };
  }

  let delivered = 0;
  for (const token of tokens) {
    try {
      await sendApnsPush(token, payload);
      delivered++;
    } catch (e) {
      console.error("[cadence] push failed", e);
    }
  }
  return delivered > 0 ? { sent: true } : { sent: false, reason: "failed" };
}

/** Whether a category is switched on for this user. A missing settings row means all-on, which
 * is the convention `notification_settings` documents. */
export async function categoryEnabled(
  sb: Client,
  userId: string,
  column: string,
): Promise<boolean> {
  const { data } = await sb
    .from("notification_settings").select(column).eq("user_id", userId).maybeSingle();
  if (!data) return true;
  return (data as Record<string, unknown>)[column] !== false;
}
