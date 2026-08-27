// Binds already-completed StoreKit purchases to the calling Supabase user.
//
// The gap this fills: `appAccountToken` — the only thing tying an Apple transaction to a
// BallIQ account — is set at purchase time from the signed-in user's uuid, so a purchase made
// while signed out carries none, and Apple keeps echoing back that absence for the life of the
// subscription. `app-store-notifications` therefore skipped those forever, and the buyer never
// got a `public.entitlements` row: no cross-device restore, no refund handling, no revenue
// attribution. In production on 2026-08-26, 19 of 25 purchase attempts were signed out.
//
// Rather than demand an account before letting anyone buy (which would have gated 92% of
// paywall traffic), the app sells to everyone and calls this afterwards — from
// `RepositoryContainer.claimEntitlements()`, on every sign-in sync and right after a purchase.
// The client posts the signed transactions it already holds; this verifies them against
// Apple's PKI and writes the rows.
//
// `verify_jwt` is left at the platform default (on), so an unauthenticated request never
// reaches this code. The bearer token is re-read below anyway — the platform proves the token
// is *valid*, not *whose*.
import { serviceClient } from "../_shared/supabase.ts";
import { loadAppleRootPem } from "../_shared/app_store_config.ts";
import {
  AppleSignedPayloadError,
  AppleTransactionInfo,
  verifyAppleSignedPayload,
} from "../_shared/app_store_notifications.ts";
import { APP_BUNDLE_ID, ClaimRefusal, decideClaim, EntitlementRow } from "../_shared/entitlement_claims.ts";

/** Bounded so one request can't be used to grind the verifier. A real device holds one row per
 * product it owns — four, today. */
const MAX_TRANSACTIONS = 16;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : "";
  if (!jwt) return json({ error: "missing bearer token" }, 401);

  const sb = serviceClient();
  // Resolves the token against GoTrue rather than decoding it here — the caller's identity is
  // the whole security boundary, and a hand-rolled decode would trust an unverified claim.
  const { data: userData, error: userError } = await sb.auth.getUser(jwt);
  const userId = userData?.user?.id;
  if (userError || !userId) return json({ error: "not authenticated" }, 401);

  // snake_case on the wire, because the client encodes every Supabase payload with
  // `JSONEncoder.supabase` (`.convertToSnakeCase`) — the same encoder PostgREST writes need.
  // Naming this field `signedTransactions` would have meant a second encoder on the Swift side
  // and a 400 on every single claim if anyone forgot; `SupabaseClientTests` pins the wire name
  // from the other end.
  let body: { signed_transactions?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const signed = body.signed_transactions;
  if (!Array.isArray(signed) || signed.some((s) => typeof s !== "string")) {
    return json({ error: "signed_transactions must be an array of strings" }, 400);
  }
  if (signed.length === 0) return json({ ok: true, claimed: 0, refused: {} });
  if (signed.length > MAX_TRANSACTIONS) {
    return json({ error: `at most ${MAX_TRANSACTIONS} transactions per request` }, 400);
  }

  const rootPem = await loadAppleRootPem(fetch);
  if (!rootPem) {
    console.error("APPLE_ROOT_CA_PEM unavailable (env + Vault both empty) — cannot verify");
    return json({ error: "not configured" }, 500);
  }

  const expectedBundleId = Deno.env.get("APP_BUNDLE_ID") ?? APP_BUNDLE_ID;
  const rows: EntitlementRow[] = [];
  const refused: Record<string, number> = {};
  let unverified = 0;

  const note = (reason: ClaimRefusal) => {
    refused[reason] = (refused[reason] ?? 0) + 1;
  };

  for (const jws of signed as string[]) {
    let tx: AppleTransactionInfo;
    try {
      tx = await verifyAppleSignedPayload(jws, rootPem) as unknown as AppleTransactionInfo;
    } catch (e) {
      // A blob that doesn't verify is the ordinary case for a hostile caller, not an outage:
      // counted, not logged per-item, and never fatal to the rest of the batch. Deliberately
      // catches everything rather than only `AppleSignedPayloadError` — one unparseable entry
      // must not cost the caller the genuine transactions sitting next to it in the same
      // request, and there is no useful way to act on an unexpected error here beyond
      // distrusting the blob that caused it. (`verifyAppleSignedPayload` now normalises
      // malformed input to `AppleSignedPayloadError` too; this is the second line of defence.)
      if (!(e instanceof AppleSignedPayloadError)) {
        console.error("unexpected error verifying a submitted transaction:", e);
      }
      unverified++;
      continue;
    }
    if (!tx.originalTransactionId || !tx.productId) {
      unverified++;
      continue;
    }

    // Who owns this original transaction already, if anyone. Indexed
    // (`entitlements_original_transaction_idx`).
    const { data: owner } = await sb
      .from("entitlements")
      .select("user_id")
      .eq("original_transaction_id", tx.originalTransactionId)
      .limit(1)
      .maybeSingle();

    const outcome = decideClaim(tx, userId, {
      expectedBundleId,
      existingOwner: owner?.user_id ?? null,
    });
    if (!outcome.ok) {
      note(outcome.reason);
      continue;
    }
    rows.push(outcome.row);
  }

  if (rows.length > 0) {
    const { error } = await sb.from("entitlements").upsert(rows, { onConflict: "user_id,product_id" });
    if (error) {
      // 23505 on `entitlements_one_owner_per_transaction` means another account claimed one of
      // these between the read above and this write — the race the constraint exists to close.
      // It is a refusal, not an outage, and reporting it as a 500 would send the client into a
      // retry loop over something that will never succeed.
      if (error.code === "23505") {
        return json({ ok: true, claimed: 0, refused: { "already-claimed": rows.length }, unverified }, 409);
      }
      console.error("failed to upsert claimed entitlements:", error.message);
      return json({ error: "db write failed" }, 500);
    }
  }

  return json({ ok: true, claimed: rows.length, refused, unverified });
});
