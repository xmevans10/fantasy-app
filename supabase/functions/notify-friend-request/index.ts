// Triggered by the `friends_notify_request` DB trigger (pg_net) on INSERT to `public.friends`
// with status='pending' — already wired live, no dashboard webhook to set up. Looks up the
// addressee's notification preference + device tokens and sends the "friend request" push.
//
// Goes through `_shared/cadence.ts`'s `sendOnce`, and unlike the two Versus notifiers this one
// is CAPPED (`friend_request` is not in cadence.ts's CAP_EXEMPT set, which is the whole of the
// mechanism — there is nothing to add here). That asymmetry is the point: a duel has a clock
// and a forfeit, so withholding "your opponent played" costs the recipient a game they can't
// see themselves losing, whereas a friend request has no deadline at all. If someone has
// already had their three pushes today, the request waits in the app and nothing is lost.
//
// Dedupe key `friend:<requester uuid>`: several different people can send you a request on one
// day and each is worth its own push, so a per-day-per-category guard would have announced only
// the first. Keyed by requester, a pg_net retry of the same INSERT still collides and stays
// silent. See migration 0022.
import { serviceClient } from "../_shared/supabase.ts";
import { buildFriendRequestPayload } from "../_shared/apns.ts";
import { categoryEnabled, recipientTokens, sendOnce } from "../_shared/cadence.ts";

interface WebhookBody {
  record: { requester_id: string; addressee_id: string };
}

Deno.serve(async (req) => {
  const { record }: WebhookBody = await req.json();
  const sb = serviceClient();

  if (!await categoryEnabled(sb, record.addressee_id, "friend_request")) {
    return new Response(JSON.stringify({ skipped: "opted_out" }), { status: 200 });
  }

  const { data: requester } = await sb
    .from("profiles").select("username").eq("id", record.requester_id).maybeSingle();
  const { tokens, utcOffsetMinutes } = await recipientTokens(sb, record.addressee_id);

  const result = await sendOnce(sb, {
    userId: record.addressee_id,
    tokens,
    utcOffsetMinutes,
    nowMs: Date.now(),
    payload: buildFriendRequestPayload(requester?.username ?? "A player"),
    dedupeKey: `friend:${record.requester_id}`,
  });

  return new Response(JSON.stringify({ ...result, devices: tokens.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
