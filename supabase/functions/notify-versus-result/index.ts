// Triggered by the `versus_challenges_result_notify` DB trigger (pg_net `net.http_post`, see
// schema.sql) whenever a score column goes null -> non-null on a duel.
//
// This is the engagement loop the async mode never had. Two distinct moments come through the
// same trigger, and they need different copy, so the row is re-read here rather than trusted
// from the payload — by the time this runs, `submit_versus_result` may already have called
// `resolve_versus_challenge` and settled the duel:
//
//   * the other side hasn't played yet  -> "your opponent finished, you're up"
//   * the other side had already played -> the duel is settled, tell them how it went
//
// The finisher is never pushed: they are looking at their own result screen.
//
// Routed through `_shared/cadence.ts`'s `sendOnce` so it is logged in `notification_log`. It
// stays CAP-EXEMPT, and not by accident: both payloads below carry the category
// `versus_challenge`, which is the one entry in cadence.ts's CAP_EXEMPT set, and the reason
// given there — "we didn't tell you it was your turn because you'd had three pushes" is how
// someone forfeits a timed duel for an invisible reason — describes the "your opponent
// finished, you're up" push more exactly than it describes anything else the app sends. Making
// it capped would have meant exempting the challenge but not the far more time-critical reply
// to it. Exempt still means logged, and still means it consumes budget the capped categories
// are measured against.
//
// The dedupe key is `result:<duel id>` — derived from the triggering row ONLY. It deliberately
// does not include `settled`, even though the copy does: `resolve_versus_challenge` can settle
// the duel between the trigger firing and this function running, so a key that read live status
// would come out different on a pg_net retry and let the retry through as a second push. Keying
// on the duel id alone means one result push per duel per recipient, retries included, while
// still leaving room for the *other* Versus push on that duel (`challenge:<id>`, same category,
// same day) because the keys differ. See migration 0022.
import { serviceClient } from "../_shared/supabase.ts";
import { buildVersusFinishedPayload, buildVersusSettledPayload } from "../_shared/apns.ts";
import { categoryEnabled, recipientTokens, sendOnce } from "../_shared/cadence.ts";

interface WebhookBody {
  record: { id: number; finisher_id: string; waiting_id: string };
}

Deno.serve(async (req) => {
  const { record }: WebhookBody = await req.json();
  const sb = serviceClient();

  // Same opt-out category as the challenge-received push: a player who muted Versus muted all
  // of it. A missing row means all categories on (see notification_settings' doc comment).
  if (!await categoryEnabled(sb, record.waiting_id, "versus_challenge")) {
    return new Response(JSON.stringify({ skipped: "opted_out" }), { status: 200 });
  }

  const { data: duel } = await sb
    .from("versus_challenges")
    .select("id, status, winner_id, time_limit_seconds")
    .eq("id", record.id)
    .maybeSingle();
  if (!duel) {
    return new Response(JSON.stringify({ skipped: "gone" }), { status: 200 });
  }

  const { data: finisher } = await sb
    .from("profiles").select("username").eq("id", record.finisher_id).maybeSingle();
  const { tokens, utcOffsetMinutes } = await recipientTokens(sb, record.waiting_id);

  const name = finisher?.username ?? "Your opponent";
  // `status` is the discriminator, not the presence of a winner: a draw settles as `completed`
  // with `winner_id` null, which is a result to report, not an unfinished duel.
  const settled = duel.status !== "pending";
  const payload = settled
    ? buildVersusSettledPayload(name, duel.winner_id === record.waiting_id, duel.winner_id === null)
    : buildVersusFinishedPayload(name, duel.time_limit_seconds ?? 120);

  const result = await sendOnce(sb, {
    userId: record.waiting_id,
    tokens,
    utcOffsetMinutes,
    nowMs: Date.now(),
    payload,
    dedupeKey: `result:${record.id}`,
  });

  return new Response(JSON.stringify({ ...result, settled, devices: tokens.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
