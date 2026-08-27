// Receives App Store Server Notifications V2 (Apple POSTs here on every subscription/purchase
// lifecycle event — renewal, cancellation, refund, etc.) and persists verified entitlement
// state into `public.entitlements`. This is the server-side half of M5 monetization: the
// client's on-device `Transaction.currentEntitlements` read (`StoreService`) is instant-UX only
// and can't be trusted alone (a jailbroken/modified client could fake it) — this table, written
// only by this service-role function, is what `RemoteSync` actually trusts across devices.
//
// Remaining hand-off (cannot be done by the agent): set the production App Store Server
// Notifications URL to this function's URL in App Store Connect (App Information → App Store
// Server Notifications). The trust anchor (`APPLE_ROOT_CA_PEM`, Apple's Root CA — G3) is now
// resolved at runtime: the env secret wins if present, else it's fetched once per isolate from
// Supabase Vault via `get_app_store_config()` (2026-07-17 — same fallback the APNs key uses,
// because no management token exists here to set true Edge Function secrets). The whole
// verify/persist path is covered by `_shared/app_store_notifications.test.ts`'s self-generated
// fixture chain.
import { serviceClient } from "../_shared/supabase.ts";
import { loadAppleRootPem } from "../_shared/app_store_config.ts";
import {
  AppleNotificationPayload,
  AppleSignedPayloadError,
  AppleTransactionInfo,
  verifyAppleSignedPayload,
} from "../_shared/app_store_notifications.ts";
import { entitlementRow, resolveNotificationOwner } from "../_shared/entitlement_claims.ts";

Deno.serve(async (req) => {
  const rootPem = await loadAppleRootPem(fetch);
  if (!rootPem) {
    console.error("APPLE_ROOT_CA_PEM unavailable (env + Vault both empty) — cannot verify");
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

  const sb = serviceClient();

  // `appAccountToken` is our own uuid, set at purchase time via
  // `Product.PurchaseOption.appAccountToken` (see `StoreService.purchase`), so it is present
  // only when the buyer was signed in *at the moment of purchase*.
  //
  // When it's absent, fall back to whoever previously claimed this original transaction
  // through `claim-entitlement`. That fallback is not a nicety — Apple echoes back only what
  // was set at purchase time, and never starts supplying a token that wasn't there. Without
  // it, every renewal, cancellation and refund for an anonymous-bought subscription stays
  // unattributable for the life of the subscription, so a claimed row would freeze at the
  // `expires_at` the claim wrote and silently age into "expired" while the user is still
  // paying. Indexed by `entitlements_original_transaction_idx`.
  const { data: priorOwner } = await sb
    .from("entitlements")
    .select("user_id")
    .eq("original_transaction_id", transaction.originalTransactionId)
    .limit(1)
    .maybeSingle();

  const userId = resolveNotificationOwner(transaction, priorOwner?.user_id ?? null);
  if (!userId) {
    console.warn(
      `notification for transaction ${transaction.transactionId} has no appAccountToken and no ` +
        `prior claim — skipping (the buyer can still claim it by signing in)`,
    );
    return new Response(JSON.stringify({ ok: true, skipped: "no appAccountToken" }), {
      headers: { "Content-Type": "application/json" },
    });
  }

  const row = entitlementRow(transaction, userId);
  const status = row.status;
  const { error } = await sb.from("entitlements").upsert(row, { onConflict: "user_id,product_id" });

  if (error) {
    console.error("failed to upsert entitlement:", error.message);
    return new Response(JSON.stringify({ error: "db write failed" }), { status: 500 });
  }

  return new Response(JSON.stringify({ ok: true, notificationType: notification.notificationType, status }), {
    headers: { "Content-Type": "application/json" },
  });
});
