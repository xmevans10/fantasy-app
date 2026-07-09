// Receives App Store Server Notifications V2 (Apple POSTs here on every subscription/purchase
// lifecycle event — renewal, cancellation, refund, etc.) and persists verified entitlement
// state into `public.entitlements`. This is the server-side half of M5 monetization: the
// client's on-device `Transaction.currentEntitlements` read (`StoreService`) is instant-UX only
// and can't be trusted alone (a jailbroken/modified client could fake it) — this table, written
// only by this service-role function, is what `RemoteSync` actually trusts across devices.
//
// Hand-off (cannot be done by the agent): set the production notifications URL to this
// function's URL in App Store Connect (App Information → App Store Server Notifications), and
// set `APPLE_ROOT_CA_PEM` (Apple's Root CA — G3) as an Edge Function secret. Until both exist,
// no real traffic reaches this function — it's fully covered by
// `_shared/app_store_notifications.test.ts`'s self-generated fixture chain in the meantime.
import { serviceClient } from "../_shared/supabase.ts";
import {
  AppleNotificationPayload,
  AppleSignedPayloadError,
  AppleTransactionInfo,
  deriveEntitlementStatus,
  verifyAppleSignedPayload,
} from "../_shared/app_store_notifications.ts";

Deno.serve(async (req) => {
  const rootPem = Deno.env.get("APPLE_ROOT_CA_PEM");
  if (!rootPem) {
    console.error("APPLE_ROOT_CA_PEM not set — cannot verify any notification yet");
    return new Response(JSON.stringify({ error: "not configured" }), { status: 500 });
  }

  let body: { signedPayload?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "invalid JSON body" }), { status: 400 });
  }
  if (!body.signedPayload) {
    return new Response(JSON.stringify({ error: "missing signedPayload" }), { status: 400 });
  }

  let notification: AppleNotificationPayload;
  try {
    notification = await verifyAppleSignedPayload(body.signedPayload, rootPem) as unknown as AppleNotificationPayload;
  } catch (e) {
    if (e instanceof AppleSignedPayloadError) {
      console.error("rejected notification: signature/chain verification failed:", e.message);
      return new Response(JSON.stringify({ error: "verification failed" }), { status: 400 });
    }
    throw e;
  }

  // Apple sends a periodic TEST notification (no real transaction) to confirm the endpoint is
  // reachable — ack it and stop, nothing to persist.
  const signedTransactionInfo = notification.data?.signedTransactionInfo;
  if (!signedTransactionInfo) {
    return new Response(JSON.stringify({ ok: true, notificationType: notification.notificationType }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const transaction = await verifyAppleSignedPayload(signedTransactionInfo, rootPem) as unknown as AppleTransactionInfo;

  // `appAccountToken` is our own uuid, set at purchase time via
  // `Product.PurchaseOption.appAccountToken` (see `StoreService.purchase`). Without it we have
  // no way to know which Supabase user this transaction belongs to — ack and skip rather than
  // guessing or writing an orphaned row.
  if (!transaction.appAccountToken) {
    console.warn(`notification for transaction ${transaction.transactionId} has no appAccountToken — skipping`);
    return new Response(JSON.stringify({ ok: true, skipped: "no appAccountToken" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const status = deriveEntitlementStatus(transaction);
  const sb = serviceClient();
  const { error } = await sb.from("entitlements").upsert({
    user_id: transaction.appAccountToken,
    product_id: transaction.productId,
    status,
    original_transaction_id: transaction.originalTransactionId,
    expires_at: transaction.expiresDate ? new Date(transaction.expiresDate).toISOString() : null,
    updated_at: new Date().toISOString(),
  }, { onConflict: "user_id,product_id" });

  if (error) {
    console.error("failed to upsert entitlement:", error.message);
    return new Response(JSON.stringify({ error: "db write failed" }), { status: 500 });
  }

  return new Response(JSON.stringify({ ok: true, notificationType: notification.notificationType, status }), {
    headers: { "Content-Type": "application/json" },
  });
});
