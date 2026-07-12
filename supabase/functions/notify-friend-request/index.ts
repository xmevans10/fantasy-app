// Triggered by the `friends_notify_request` DB trigger (pg_net) on INSERT to `public.friends`
// with status='pending' — already wired live, no dashboard webhook to set up. Looks up the
// addressee's notification preference + device tokens and sends the "friend request" push.
import { serviceClient } from "../_shared/supabase.ts";
import { buildFriendRequestPayload, sendApnsPush } from "../_shared/apns.ts";

interface WebhookBody {
  record: { requester_id: string; addressee_id: string };
}

Deno.serve(async (req) => {
  const { record }: WebhookBody = await req.json();
  const sb = serviceClient();

  const { data: settings } = await sb
    .from("notification_settings")
    .select("friend_request")
    .eq("user_id", record.addressee_id)
    .maybeSingle();
  if (settings && settings.friend_request === false) {
    return new Response(JSON.stringify({ skipped: "opted_out" }), { status: 200 });
  }

  const { data: requester } = await sb
    .from("profiles").select("username").eq("id", record.requester_id).maybeSingle();
  const { data: tokens } = await sb
    .from("device_tokens").select("token").eq("user_id", record.addressee_id);

  const payload = buildFriendRequestPayload(requester?.username ?? "A player");
  for (const { token } of tokens ?? []) {
    await sendApnsPush(token, payload).catch((e) => console.error("push failed", e));
  }

  return new Response(JSON.stringify({ sent: tokens?.length ?? 0 }), {
    headers: { "Content-Type": "application/json" },
  });
});
