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
//     (user_id, category, local_day, dedupe_key). That makes the write the idempotency guard as
//     well as the audit trail: an hourly cron that double-fires — a retry, an overlapping run,
//     clock skew at an offset boundary — loses the race on the insert and simply doesn't send.
//
// `dedupe_key` (migration 0022) is what let the trigger-driven half join. The scheduled slots
// pass none: one 9am, one 1pm, one 8pm, so "once per category per local day" IS the slot. The
// trigger-driven categories are the opposite — two people can challenge you on the same
// Tuesday and both are real — so they pass a key naming the event, and the guard narrows from
// "once a day" to "once per event". See `sendOnce`'s `dedupeKey` for the rule it must satisfy.
import { ApnsTokenInvalid, pruneDeadToken, sendApnsPush,
         type ApnsEnvironment, type PushPayload } from "./apns.ts";
import { localDayString } from "./localtime.ts";

/** Ceiling per recipient per local day, across every category. */
export const DAILY_PUSH_CAP = 3;

/** Categories that are a direct reply to something the recipient's opponent just did. They are
 * exempt from the cap because suppressing them breaks a mechanic rather than reducing noise:
 * a duel has a 24h clock, and "we didn't tell you it was your turn because you'd had three
 * pushes" is how someone loses a duel by forfeit for a reason they can't see.
 *
 * `versus_challenge` is the category on all three Versus payloads — challenge received,
 * opponent finished, duel settled (see apns.ts) — so notify-versus-result is exempt by the
 * same rule and for the same reason: "your opponent played, the clock is running" is the
 * single most forfeit-critical push the app sends, and it is exactly the sentence the comment
 * above is about. Exempt is not unlogged: every one of them still writes its audit row, still
 * respects the per-event guard, and still counts toward the budget the CAPPED categories see.
 *
 * `friend_request` is deliberately NOT here. Nothing is lost by a friend request arriving via
 * the badge instead of a buzz — it has no clock and no forfeit — so it is capped like the
 * scheduled slots. */
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
/** A device and the APNs host its token is valid on — the two are inseparable, see apns.ts. */
export interface DeviceToken {
  token: string;
  environment: ApnsEnvironment;
}

export async function sendOnce(
  sb: Client,
  opts: {
    userId: string;
    /** **Every** device this user has registered. The cap and the once-per-day guard are per
     * *person*, but the delivery is per *device* — someone with an iPhone and an iPad should
     * get the notification on both. Keying the log by token instead would have let one person
     * collect three pushes for one event; keying delivery by the log (the first version of
     * this) silently dropped every device after the first. */
    tokens: DeviceToken[];
    utcOffsetMinutes: number;
    nowMs: number;
    payload: PushPayload;
    /** Names the *event* this push answers, for the categories that can legitimately fire more
     * than once in a day ("challenge:42", "result:42", "friend:<uuid>"). Omitted by the
     * scheduled slots, where once-per-category-per-day is the intended guard.
     *
     * **It must be derived only from the triggering row**, never from state that can change
     * between the trigger firing and this function running. A key computed from, say, whether
     * the duel had settled yet would come out different on a pg_net retry, and the retry would
     * send a second push — the precise failure the guard exists to stop. */
    dedupeKey?: string;
  },
): Promise<SendResult> {
  const { userId, tokens, utcOffsetMinutes, nowMs, payload, dedupeKey } = opts;
  const day = localDayString(utcOffsetMinutes, nowMs);

  if (!CAP_EXEMPT.has(payload.category)) {
    if (await sentToday(sb, userId, utcOffsetMinutes, nowMs) >= DAILY_PUSH_CAP) {
      return { sent: false, reason: "capped" };
    }
  }

  const { error } = await sb
    .from("notification_log")
    .insert({
      user_id: userId,
      category: payload.category,
      local_day: day,
      dedupe_key: dedupeKey ?? null,
    });
  if (error) {
    // 23505 = unique violation: this exact push already went out today — the whole category for
    // a scheduled slot, or this one event for a trigger-driven one. Any other error is worth
    // seeing in the function log, but neither case should send.
    if (error.code !== "23505") console.error("[cadence] log insert failed", error);
    return { sent: false, reason: "already_sent" };
  }

  let delivered = 0;
  for (const { token, environment } of tokens) {
    try {
      await sendApnsPush(token, payload, { environment });
      delivered++;
    } catch (e) {
      // A dead token is not a transient failure — retrying it forever is how a small fleet of
      // stale tokens turns into a permanent 0% delivery rate. Drop it and keep going; the other
      // devices for this person still deserve the push.
      if (e instanceof ApnsTokenInvalid) await pruneDeadToken(sb, token);
      console.error("[cadence] push failed", e);
    }
  }
  return delivered > 0 ? { sent: true } : { sent: false, reason: "failed" };
}

/** Every device token for one recipient, plus the offset to resolve their local day with.
 *
 * The three trigger-driven notifiers each know exactly one recipient (unlike the cron ones,
 * which sweep every token row), and each needs the same two things `sendOnce` takes. Before
 * the cadence routing they only fetched `token`, because a fire-and-forget send has no notion
 * of a day.
 *
 * One offset has to win, because the cap and the log are per *person* while tokens are per
 * *device* — and mixed offsets are not hypothetical: live right now, one of the two
 * push-reachable users has a UTC-240 device and two UTC+120 devices. The first row wins, which
 * is the same choice `notify-engagement` makes when it groups tokens by user. The cost of
 * picking wrong is a local-day boundary resolved a few hours early or late for that one
 * person; no push is lost or duplicated by it. */
export async function recipientTokens(
  sb: Client,
  userId: string,
): Promise<{ tokens: DeviceToken[]; utcOffsetMinutes: number }> {
  const { data } = await sb
    .from("device_tokens").select("token, utc_offset_minutes, apns_environment")
    .eq("user_id", userId);
  const rows = (data ?? []) as Array<
    { token: string; utc_offset_minutes: number | null; apns_environment: string | null }>;
  return {
    tokens: rows.map((r) => ({
      token: r.token,
      // Defaulting to production matches the column default and shipped App Store behaviour;
      // a debug build corrects its own row on the next registration upsert.
      environment: (r.apns_environment === "development" ? "development" : "production"),
    })),
    utcOffsetMinutes: rows[0]?.utc_offset_minutes ?? 0,
  };
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
