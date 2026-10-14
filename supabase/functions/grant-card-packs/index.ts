// Credits card packs for StoreKit consumable purchases.
//
// The client posts the signed transaction(s) for card packs it has bought but not yet finished;
// this verifies each against Apple's PKI, credits the caller's `card_pack_wallet` through
// `grant_card_packs` (idempotent per transaction id), and answers with the transaction ids the
// client may now finish. A transaction is only reported finishable once it is on the books, so
// a failure here leaves it unfinished and StoreKit hands it back on the next launch.
//
// `verify_jwt` stays on; the bearer token is resolved against GoTrue below, as in
// claim-entitlement, because the platform proves the token is valid, not whose it is.
import { serviceClient } from "../_shared/supabase.ts";
import { loadAppleRootPem } from "../_shared/app_store_config.ts";
import { AppleTransactionInfo, verifyAppleSignedPayload } from "../_shared/app_store_notifications.ts";
import { APP_BUNDLE_ID } from "../_shared/entitlement_claims.ts";
import { decidePackGrant } from "../_shared/card_packs.ts";

const MAX_TRANSACTIONS = 16;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : "";
  if (!jwt) return json({ error: "missing bearer token" }, 401);

  const sb = serviceClient();
  const { data: userData, error: userError } = await sb.auth.getUser(jwt);
  const userId = userData?.user?.id;
  if (userError || !userId) return json({ error: "not authenticated" }, 401);

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
  if (signed.length > MAX_TRANSACTIONS) return json({ error: `at most ${MAX_TRANSACTIONS} transactions per request` }, 400);

  const rootPem = await loadAppleRootPem(fetch);
  if (!rootPem) {
    console.error("APPLE_ROOT_CA_PEM unavailable — cannot verify");
    return json({ error: "not configured" }, 500);
  }
  const expectedBundleId = Deno.env.get("APP_BUNDLE_ID") ?? APP_BUNDLE_ID;

  // `finishable`: credited now or already credited earlier — either way the client may finish it.
  const finishable: string[] = [];
  const refused: Record<string, number> = {};
  let credited = 0;

  for (const jws of signed as string[]) {
    let tx: AppleTransactionInfo;
    try {
      tx = await verifyAppleSignedPayload(jws, rootPem) as unknown as AppleTransactionInfo;
    } catch {
      refused["unverified"] = (refused["unverified"] ?? 0) + 1;
      continue;
    }
    const decision = decidePackGrant(tx, userId, expectedBundleId);
    if (!decision.ok) {
      refused[decision.reason] = (refused[decision.reason] ?? 0) + 1;
      continue;
    }
    const { data, error } = await sb.rpc("grant_card_packs", {
      p_user: userId,
      p_transaction: decision.transactionId,
      p_product: decision.productId,
      p_packs: decision.packs,
    });
    if (error) {
      console.error("grant_card_packs failed:", error.message);
      return json({ error: "db write failed", finishable, credited }, 500);
    }
    if (data === true) credited += decision.packs;
    finishable.push(decision.transactionId);
  }

  return json({ ok: true, credited, finishable, refused });
});
