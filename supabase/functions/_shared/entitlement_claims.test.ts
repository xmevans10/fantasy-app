import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { AppleTransactionInfo } from "./app_store_notifications.ts";
import {
  APP_BUNDLE_ID,
  ClaimOutcome,
  decideClaim,
  entitlementRow,
  resolveNotificationOwner,
} from "./entitlement_claims.ts";

const USER = "11111111-1111-1111-1111-111111111111";
const OTHER_USER = "22222222-2222-2222-2222-222222222222";
const NOW = new Date("2026-08-26T12:00:00.000Z");

function tx(over: Partial<AppleTransactionInfo> = {}): AppleTransactionInfo {
  return {
    productId: "com.balliqfantasy.app.pro.monthly",
    originalTransactionId: "2000000900000001",
    transactionId: "2000000900000009",
    bundleId: APP_BUNDLE_ID,
    expiresDate: NOW.getTime() + 30 * 86_400_000,
    ...over,
  };
}

function refusal(outcome: ClaimOutcome): string {
  return outcome.ok ? "<claimed>" : outcome.reason;
}

// MARK: - The case the whole feature exists for

Deno.test("decideClaim claims an anonymous purchase for the signing-in user", () => {
  // No appAccountToken (bought signed out), nobody has claimed it yet. This is the 19-in-25
  // production case; before the claim path it was unattributable forever.
  const outcome = decideClaim(tx({ appAccountToken: undefined }), USER, {
    existingOwner: null,
    now: NOW,
  });

  assertEquals(outcome.ok, true);
  if (!outcome.ok) return;
  assertEquals(outcome.row.user_id, USER);
  assertEquals(outcome.row.product_id, "com.balliqfantasy.app.pro.monthly");
  assertEquals(outcome.row.original_transaction_id, "2000000900000001");
  assertEquals(outcome.row.status, "active");
});

Deno.test("decideClaim is idempotent — re-claiming your own transaction still succeeds", () => {
  // Called on every sign-in sync, so the steady state is re-claiming what you already own.
  // Refusing here would make the common path log a refusal on every launch.
  const outcome = decideClaim(tx({ appAccountToken: USER }), USER, {
    existingOwner: USER,
    now: NOW,
  });
  assertEquals(outcome.ok, true);
});

Deno.test("decideClaim claims a transaction that already names this user", () => {
  const outcome = decideClaim(tx({ appAccountToken: USER }), USER, { existingOwner: null, now: NOW });
  assertEquals(outcome.ok, true);
});

// MARK: - Replay defence
//
// A signed JWS proves the purchase is real, not that the presenter made it.
// `Transaction.jwsRepresentation` is readable by the owning app, so the threat is a copied
// blob replayed by a second account.

Deno.test("decideClaim refuses a transaction belonging to another account", () => {
  const outcome = decideClaim(tx({ appAccountToken: OTHER_USER }), USER, {
    existingOwner: null,
    now: NOW,
  });
  assertEquals(refusal(outcome), "other-account");
});

Deno.test("decideClaim refuses an anonymous transaction another account already claimed", () => {
  // First claimer wins. Otherwise one purchase could be shared around indefinitely by passing
  // the blob along.
  const outcome = decideClaim(tx({ appAccountToken: undefined }), USER, {
    existingOwner: OTHER_USER,
    now: NOW,
  });
  assertEquals(refusal(outcome), "already-claimed");
});

Deno.test("decideClaim refuses a valid JWS issued for a different app", () => {
  // Apple signs every app's transactions with the same PKI, so a receipt from any other App
  // Store app verifies perfectly. Without the bundle check it would grant BallIQ Pro.
  const outcome = decideClaim(tx({ bundleId: "com.someoneelse.app", appAccountToken: undefined }), USER, {
    existingOwner: null,
    now: NOW,
  });
  assertEquals(refusal(outcome), "wrong-bundle");
});

Deno.test("decideClaim treats an absent bundleId as unknown, not as a mismatch", () => {
  // Older payload shapes omit it; refusing those would break real claims.
  const outcome = decideClaim(tx({ bundleId: undefined, appAccountToken: undefined }), USER, {
    existingOwner: null,
    now: NOW,
  });
  assertEquals(outcome.ok, true);
});

Deno.test("decideClaim reports the ownership refusal ahead of the prior-claim one", () => {
  // Deterministic precedence so the counters in the response mean one thing. A transaction
  // that names another account is refused for that, not for the claim that followed it.
  const outcome = decideClaim(tx({ appAccountToken: OTHER_USER }), USER, {
    existingOwner: OTHER_USER,
    now: NOW,
  });
  assertEquals(refusal(outcome), "other-account");
});

Deno.test("decideClaim refuses a foreign-bundle transaction before any other check", () => {
  const outcome = decideClaim(
    tx({ bundleId: "com.someoneelse.app", appAccountToken: OTHER_USER }),
    USER,
    { existingOwner: OTHER_USER, now: NOW },
  );
  assertEquals(refusal(outcome), "wrong-bundle");
});

// MARK: - Nothing to grant

Deno.test("decideClaim refuses an expired subscription", () => {
  const outcome = decideClaim(
    tx({ appAccountToken: undefined, expiresDate: NOW.getTime() - 1 }),
    USER,
    { existingOwner: null, now: NOW },
  );
  assertEquals(refusal(outcome), "not-active");
});

Deno.test("decideClaim refuses a refunded transaction", () => {
  const outcome = decideClaim(
    tx({ appAccountToken: undefined, revocationDate: NOW.getTime() - 86_400_000 }),
    USER,
    { existingOwner: null, now: NOW },
  );
  assertEquals(refusal(outcome), "not-active");
});

Deno.test("decideClaim refuses a refund even while the paid period still runs", () => {
  // Revocation outranks an expiry date in the future — the money went back.
  const outcome = decideClaim(
    tx({
      appAccountToken: undefined,
      expiresDate: NOW.getTime() + 30 * 86_400_000,
      revocationDate: NOW.getTime() - 1,
    }),
    USER,
    { existingOwner: null, now: NOW },
  );
  assertEquals(refusal(outcome), "not-active");
});

// MARK: - Row shape (shared by both writers, so it can't be derived two ways)

Deno.test("entitlementRow carries the expiry through as ISO-8601", () => {
  const expires = NOW.getTime() + 30 * 86_400_000;
  const row = entitlementRow(tx({ expiresDate: expires }), USER, NOW);

  assertEquals(row.expires_at, new Date(expires).toISOString());
  assertEquals(row.updated_at, NOW.toISOString());
  assertEquals(row.status, "active");
});

Deno.test("entitlementRow leaves expires_at null for a non-consumable pack", () => {
  // Packs never expire; a bogus expiry would make one lapse.
  const row = entitlementRow(
    tx({ productId: "com.balliqfantasy.app.pack.grid", expiresDate: undefined }),
    USER,
    NOW,
  );
  assertEquals(row.expires_at, null);
  assertEquals(row.status, "active");
});

Deno.test("entitlementRow records a refund as revoked", () => {
  const row = entitlementRow(tx({ revocationDate: NOW.getTime() - 1 }), USER, NOW);
  assertEquals(row.status, "revoked");
});

// MARK: - Notification attribution

Deno.test("resolveNotificationOwner prefers Apple's own appAccountToken", () => {
  assertEquals(resolveNotificationOwner(tx({ appAccountToken: USER }), null), USER);
});

Deno.test("resolveNotificationOwner never lets a prior claim override Apple's token", () => {
  // The token was set at purchase time by the buyer's own signed-in session — it outranks any
  // later claim, and letting a claim win would be a hijack primitive.
  assertEquals(resolveNotificationOwner(tx({ appAccountToken: USER }), OTHER_USER), USER);
});

Deno.test("resolveNotificationOwner falls back to whoever claimed the transaction", () => {
  // The renewal path for an anonymous purchase. Apple will never supply a token for it, so
  // without this every renewal after the claim goes unattributed and the row ages into
  // "expired" while the subscription is live.
  assertEquals(resolveNotificationOwner(tx({ appAccountToken: undefined }), USER), USER);
});

Deno.test("resolveNotificationOwner yields null when nobody has claimed an anonymous purchase", () => {
  // Correctly skipped: no row is better than an orphaned one, and the buyer can still claim
  // it later by signing in.
  assertEquals(resolveNotificationOwner(tx({ appAccountToken: undefined }), null), null);
});
