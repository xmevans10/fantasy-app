// Card pack purchases: which verified Apple transactions credit packs, and how many.
//
// Pure, like entitlement_claims.ts, so the rules are testable without the verifier or a DB.
// Card packs are consumables: Apple forgets them once the app finishes the transaction, so the
// client holds the transaction open until `grant-card-packs` has credited it, and the
// `card_pack_purchases` primary key (transaction id) makes a replay a no-op rather than a gift.

import { type AppleTransactionInfo } from "./app_store_notifications.ts";

/** Product id -> packs credited. Must match `StoreProduct` on the client. */
export const CARD_PACK_PRODUCTS: Record<string, number> = {
  "com.balliqfantasy.app.cards.pack1": 1,
  "com.balliqfantasy.app.cards.pack5": 5,
  "com.balliqfantasy.app.cards.pack12": 12,
};

export type PackRefusal = "wrong-app" | "not-a-card-pack" | "revoked" | "other-account";

export type PackDecision =
  | { ok: true; transactionId: string; productId: string; packs: number }
  | { ok: false; reason: PackRefusal };

/** Whether `tx` credits packs to `userId`. The client only sells packs to a signed-in player
 * and stamps the purchase with their uuid, so a transaction stamped for anyone else — or for
 * no one — is refused: it would let one account cash in another's receipt. */
export function decidePackGrant(
  tx: AppleTransactionInfo,
  userId: string,
  expectedBundleId: string,
): PackDecision {
  if (tx.bundleId !== undefined && tx.bundleId !== expectedBundleId) return { ok: false, reason: "wrong-app" };
  const packs = CARD_PACK_PRODUCTS[tx.productId];
  if (packs === undefined) return { ok: false, reason: "not-a-card-pack" };
  if (tx.revocationDate !== undefined) return { ok: false, reason: "revoked" };
  if ((tx.appAccountToken ?? "").toLowerCase() !== userId.toLowerCase()) {
    return { ok: false, reason: "other-account" };
  }
  return { ok: true, transactionId: tx.transactionId, productId: tx.productId, packs };
}
