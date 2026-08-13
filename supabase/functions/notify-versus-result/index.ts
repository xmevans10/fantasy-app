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
import { serviceClient } from "../_shared/supabase.ts";
import { buildVersusFinishedPayload, buildVersusSettledPayload, sendApnsPush } from "../_shared/apns.ts";

interface WebhookBody {
  record: { id: number; finisher_id: string; waiting_id: string };
}

Deno.serve(async (req) => {
  const { record }: WebhookBody = await req.json();
  const sb = serviceClient();

  // Same opt-out category as the challenge-received push: a player who muted Versus muted all
  // of it. A missing row means all categories on (see notification_settings' doc comment).
  const { data: settings } = await sb
    .from("notification_settings")
    .select("versus_challenge")
    .eq("user_id", record.waiting_id)
    .maybeSingle();
  if (settings && settings.versus_challenge === false) {
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
  const { data: tokens } = await sb
    .from("device_tokens").select("token").eq("user_id", record.waiting_id);

  const name = finisher?.username ?? "Your opponent";
  // `status` is the discriminator, not the presence of a winner: a draw settles as `completed`
  // with `winner_id` null, which is a result to report, not an unfinished duel.
  const settled = duel.status !== "pending";
  const payload = settled
    ? buildVersusSettledPayload(name, duel.winner_id === record.waiting_id, duel.winner_id === null)
    : buildVersusFinishedPayload(name, duel.time_limit_seconds ?? 120);

  for (const { token } of tokens ?? []) {
    await sendApnsPush(token, payload).catch((e) => console.error("push failed", e));
  }

  return new Response(JSON.stringify({ sent: tokens?.length ?? 0, settled }), {
    headers: { "Content-Type": "application/json" },
  });
});
