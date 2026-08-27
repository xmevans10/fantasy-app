// Deciding who a StoreKit transaction belongs to, and what row it becomes in
// `public.entitlements`. Pure — no I/O — because two different callers depend on agreeing
// exactly: the Apple webhook (`app-store-notifications`) and the client-driven backfill
// (`claim-entitlement`). Those had every reason to drift, and a drift here is invisible:
// both paths "work", they just disagree about who owns a subscription.
//
// **Why a claim path exists at all.** `appAccountToken` is set at purchase time from the
// signed-in user's uuid (`StoreService.purchase`), so a purchase made while signed out
// carries no token — and Apple echoes back only what was set then, *forever*. The webhook
// used to drop those notifications on the floor, which meant an anonymous subscriber never
// got a server-side entitlement row and never would, not even on renewal. Measured
// 2026-08-26: of 25 `purchase_attempted` events in production, 19 were signed out.
import { AppleTransactionInfo, deriveEntitlementStatus, EntitlementStatus } from "./app_store_notifications.ts";

/** BallIQ's App Store bundle id. Overridable so a future target (or a test) isn't stuck with it. */
export const APP_BUNDLE_ID = "com.balliqfantasy.app";

export interface EntitlementRow {
  user_id: string;
  product_id: string;
  status: EntitlementStatus;
  original_transaction_id: string;
  expires_at: string | null;
  updated_at: string;
}

/** The single definition of what a verified transaction becomes in the table. Both writers
 * use it, so `status`/`expires_at` can never be derived two different ways. */
export function entitlementRow(
  tx: AppleTransactionInfo,
  userId: string,
  now: Date = new Date(),
): EntitlementRow {
  return {
    user_id: userId,
    product_id: tx.productId,
    status: deriveEntitlementStatus(tx, now),
    original_transaction_id: tx.originalTransactionId,
    expires_at: tx.expiresDate ? new Date(tx.expiresDate).toISOString() : null,
    updated_at: now.toISOString(),
  };
}

export type ClaimRefusal =
  /** The JWS verified, but it isn't for this app. */
  | "wrong-bundle"
  /** The transaction names a different BallIQ account in `appAccountToken`. */
  | "other-account"
  /** Some other account already claimed this original transaction. */
  | "already-claimed"
  /** Expired or refunded — nothing to grant. */
  | "not-active";

export type ClaimOutcome =
  | { ok: true; row: EntitlementRow }
  | { ok: false; reason: ClaimRefusal };

/**
 * Whether `userId` may claim `tx`, and the row it becomes if so.
 *
 * A signed JWS from Apple proves the *purchase* is real; it does not prove the person
 * presenting it made it. `Transaction.jwsRepresentation` is readable by the app that owns the
 * transaction, so the threat model is a copied blob replayed by a second account. Three checks
 * close that:
 *
 *  - `wrong-bundle` — a JWS from some other app, signed by the same Apple PKI, verifies fine.
 *    Without this check any App Store receipt would grant BallIQ Pro.
 *  - `other-account` — a transaction bought *while signed in* already names its owner. Nobody
 *    else may take it, no matter who presents the blob.
 *  - `already-claimed` — an anonymous transaction is claimable exactly once. First account to
 *    present it owns it; everyone after is refused. Deleting that account cascades the row
 *    away (`entitlements.user_id references auth.users on delete cascade`), which frees the
 *    transaction to be claimed again — the one case where re-claiming is legitimate.
 *
 * A refusal is never a lockout: entitlement is also derived on-device from the Apple ID's own
 * transaction store (`StoreService.refreshEntitlements`), so the person who actually paid keeps
 * Pro regardless of what this returns.
 */
export function decideClaim(
  tx: AppleTransactionInfo,
  userId: string,
  opts: { expectedBundleId?: string; existingOwner?: string | null; now?: Date },
): ClaimOutcome {
  const now = opts.now ?? new Date();
  const expectedBundleId = opts.expectedBundleId ?? APP_BUNDLE_ID;

  // `bundleId` is absent from some older payload shapes; absent is not a mismatch. Present and
  // wrong is.
  if (tx.bundleId !== undefined && tx.bundleId !== expectedBundleId) {
    return { ok: false, reason: "wrong-bundle" };
  }
  if (tx.appAccountToken !== undefined && tx.appAccountToken !== userId) {
    return { ok: false, reason: "other-account" };
  }
  if (opts.existingOwner && opts.existingOwner !== userId) {
    return { ok: false, reason: "already-claimed" };
  }
  if (deriveEntitlementStatus(tx, now) !== "active") {
    return { ok: false, reason: "not-active" };
  }
  return { ok: true, row: entitlementRow(tx, userId, now) };
}

/**
 * Which user a *notification* is about. `appAccountToken` when Apple has one, otherwise the
 * account that previously claimed this original transaction.
 *
 * The fallback is what keeps a claimed anonymous subscription alive. Apple never starts
 * sending `appAccountToken` for a purchase that was made without one, so every renewal,
 * cancellation and refund for that subscription arrives anonymous for the life of the
 * subscription. Resolving through the prior claim means the row's `expires_at` and `status`
 * keep tracking reality instead of freezing at whatever the claim wrote and silently aging
 * into "expired".
 */
export function resolveNotificationOwner(
  tx: AppleTransactionInfo,
  existingOwner: string | null,
): string | null {
  return tx.appAccountToken ?? existingOwner ?? null;
}
