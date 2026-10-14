import { assertEquals } from "jsr:@std/assert@1";
import { decidePackGrant } from "./card_packs.ts";

const user = "7F9C1E2A-0000-4000-8000-000000000001";
const tx = {
  productId: "com.balliqfantasy.app.cards.pack5",
  originalTransactionId: "100",
  transactionId: "100",
  bundleId: "com.balliqfantasy.app",
  appAccountToken: user.toLowerCase(),
};

Deno.test("a pack purchase stamped for the caller credits its pack count", () => {
  assertEquals(decidePackGrant(tx, user, "com.balliqfantasy.app"),
    { ok: true, transactionId: "100", productId: "com.balliqfantasy.app.cards.pack5", packs: 5 });
});

Deno.test("another app's transaction is refused", () => {
  assertEquals(decidePackGrant({ ...tx, bundleId: "com.other" }, user, "com.balliqfantasy.app"),
    { ok: false, reason: "wrong-app" });
});

Deno.test("a subscription or unknown product is not a card pack", () => {
  assertEquals(decidePackGrant({ ...tx, productId: "com.balliqfantasy.app.pro.monthly" }, user, "com.balliqfantasy.app"),
    { ok: false, reason: "not-a-card-pack" });
});

Deno.test("a refunded pack is refused", () => {
  assertEquals(decidePackGrant({ ...tx, revocationDate: 1 }, user, "com.balliqfantasy.app"),
    { ok: false, reason: "revoked" });
});

Deno.test("a transaction stamped for another account, or none, is refused", () => {
  assertEquals(decidePackGrant({ ...tx, appAccountToken: "someone-else" }, user, "com.balliqfantasy.app"),
    { ok: false, reason: "other-account" });
  assertEquals(decidePackGrant({ ...tx, appAccountToken: undefined }, user, "com.balliqfantasy.app"),
    { ok: false, reason: "other-account" });
});
