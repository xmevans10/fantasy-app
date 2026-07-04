// Triggered by a Supabase Database Webhook on INSERT to `versus_challenges` (hand-off: wire the
// webhook in the dashboard — Database > Webhooks — pointing at this function's URL). Looks up the
// opponent's notification preference + device tokens and sends the "challenge received" push.
import { serviceClient } from "../_shared/supabase.ts";
import { buildVersusChallengePayload, sendApnsPush } from "../_shared/apns.ts";

interface WebhookBody {
  record: { id: number; challenger_id: string; opponent_id: string };
}

Deno.serve(async (req) => {
  const { record }: WebhookBody = await req.json();
  const sb = serviceClient();

  const { data: settings } = await sb
    .from("notification_settings")
    .select("versus_challenge")
    .eq("user_id", record.opponent_id)
    .maybeSingle();
  if (settings && settings.versus_challenge === false) {
    return new Response(JSON.stringify({ skipped: "opted_out" }), { status: 200 });
  }

  const { data: challenger } = await sb
    .from("profiles").select("username").eq("id", record.challenger_id).maybeSingle();
  const { data: tokens } = await sb
    .from("device_tokens").select("token").eq("user_id", record.opponent_id);

  const payload = buildVersusChallengePayload(challenger?.username ?? "A player");
  for (const { token } of tokens ?? []) {
    await sendApnsPush(token, payload).catch((e) => console.error("push failed", e));
  }

  return new Response(JSON.stringify({ sent: tokens?.length ?? 0 }), {
    headers: { "Content-Type": "application/json" },
  });
});
