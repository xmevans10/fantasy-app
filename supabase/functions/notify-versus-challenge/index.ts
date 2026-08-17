// Triggered by the `versus_challenges_notify` DB trigger (pg_net `net.http_post`, see
// schema.sql — no dashboard webhook needed) on INSERT to `versus_challenges`. Looks up the
// opponent's notification preference + device tokens and sends the "challenge received" push.
//
// Goes through `_shared/cadence.ts`'s `sendOnce` rather than calling `sendApnsPush` itself, so
// the push lands in `notification_log` like the scheduled slots do. `versus_challenge` stays
// CAP-EXEMPT there — a duel has a clock and silently withholding "someone challenged you" is
// how a player forfeits for a reason they can never see — but exempt from the CAP is not exempt
// from the LOG: the audit row is written either way, and it counts against the budget the
// capped categories are measured against.
//
// The dedupe key is the challenge id, which is the subtle half. Under the old
// (user_id, category, local_day) index the second challenge you received in a day would have
// lost the insert race with the first and never been announced; keyed by `challenge:<id>` each
// distinct challenge gets its own row and its own send, while a pg_net retry of the same insert
// still collides and stays silent. See migration 0022.
import { serviceClient } from "../_shared/supabase.ts";
import { buildVersusChallengePayload } from "../_shared/apns.ts";
import { categoryEnabled, recipientTokens, sendOnce } from "../_shared/cadence.ts";

interface WebhookBody {
  record: { id: number; challenger_id: string; opponent_id: string };
}

Deno.serve(async (req) => {
  const { record }: WebhookBody = await req.json();
  const sb = serviceClient();

  if (!await categoryEnabled(sb, record.opponent_id, "versus_challenge")) {
    return new Response(JSON.stringify({ skipped: "opted_out" }), { status: 200 });
  }

  const { data: challenger } = await sb
    .from("profiles").select("username").eq("id", record.challenger_id).maybeSingle();
  const { tokens, utcOffsetMinutes } = await recipientTokens(sb, record.opponent_id);

  const result = await sendOnce(sb, {
    userId: record.opponent_id,
    tokens,
    utcOffsetMinutes,
    nowMs: Date.now(),
    payload: buildVersusChallengePayload(challenger?.username ?? "A player"),
    dedupeKey: `challenge:${record.id}`,
  });

  return new Response(JSON.stringify({ ...result, devices: tokens.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
