import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import * as x509 from "https://esm.sh/@peculiar/x509@1.9.7?target=deno";
import {
  AppleSignedPayloadError,
  deriveEntitlementStatus,
  verifyAppleSignedPayload,
} from "./app_store_notifications.ts";

x509.cryptoProvider.set(crypto);

const ALG = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" };

function toStdBase64(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const b of arr) binary += String.fromCharCode(b);
  return btoa(binary);
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** A throwaway root → intermediate → leaf chain generated fresh per test run — proves the
 * verification logic (chain-walking, root pinning, JWS signature check) is internally sound.
 * This is NOT Apple's real PKI; production trust comes from the `APPLE_ROOT_CA_PEM` secret. */
async function buildFixtureChain() {
  const rootKeys = await crypto.subtle.generateKey(ALG, true, ["sign", "verify"]);
  const root = await x509.X509CertificateGenerator.create({
    serialNumber: "01", subject: "CN=Test Root", issuer: "CN=Test Root",
    notBefore: new Date("2020-01-01"), notAfter: new Date("2035-01-01"),
    signingAlgorithm: ALG, publicKey: rootKeys.publicKey, signingKey: rootKeys.privateKey,
  });

  const intKeys = await crypto.subtle.generateKey(ALG, true, ["sign", "verify"]);
  const intermediate = await x509.X509CertificateGenerator.create({
    serialNumber: "02", subject: "CN=Test Intermediate", issuer: "CN=Test Root",
    notBefore: new Date("2020-01-01"), notAfter: new Date("2035-01-01"),
    signingAlgorithm: ALG, publicKey: intKeys.publicKey, signingKey: rootKeys.privateKey,
  });

  const leafKeys = await crypto.subtle.generateKey(ALG, true, ["sign", "verify"]);
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03", subject: "CN=Test Leaf", issuer: "CN=Test Intermediate",
    notBefore: new Date("2020-01-01"), notAfter: new Date("2035-01-01"),
    signingAlgorithm: ALG, publicKey: leafKeys.publicKey, signingKey: intKeys.privateKey,
  });

  return { root, intermediate, leaf, leafKeys };
}

async function signJws(
  payload: Record<string, unknown>,
  leaf: x509.X509Certificate,
  intermediate: x509.X509Certificate,
  leafPrivateKey: CryptoKey,
): Promise<string> {
  const header = {
    alg: "ES256",
    x5c: [toStdBase64(leaf.rawData), toStdBase64(intermediate.rawData)],
  };
  const headerB64 = base64url(new TextEncoder().encode(JSON.stringify(header)));
  const payloadB64 = base64url(new TextEncoder().encode(JSON.stringify(payload)));
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, leafPrivateKey, signingInput);
  return `${headerB64}.${payloadB64}.${base64url(new Uint8Array(sig))}`;
}

Deno.test("verifyAppleSignedPayload accepts a JWS chained to the trusted root", async () => {
  const { root, intermediate, leaf, leafKeys } = await buildFixtureChain();
  const jws = await signJws({ notificationType: "SUBSCRIBED" }, leaf, intermediate, leafKeys.privateKey);

  const decoded = await verifyAppleSignedPayload(jws, root.toString("pem"));
  assertEquals(decoded.notificationType, "SUBSCRIBED");
});

Deno.test("verifyAppleSignedPayload rejects a chain pinned to a different root", async () => {
  const { intermediate, leaf, leafKeys } = await buildFixtureChain();
  const { root: otherRoot } = await buildFixtureChain(); // unrelated root
  const jws = await signJws({ notificationType: "SUBSCRIBED" }, leaf, intermediate, leafKeys.privateKey);

  await assertRejects(
    () => verifyAppleSignedPayload(jws, otherRoot.toString("pem")),
    AppleSignedPayloadError,
    "does not terminate at the trusted root",
  );
});

Deno.test("verifyAppleSignedPayload rejects a tampered payload (signature no longer matches)", async () => {
  const { root, intermediate, leaf, leafKeys } = await buildFixtureChain();
  const jws = await signJws({ notificationType: "SUBSCRIBED" }, leaf, intermediate, leafKeys.privateKey);
  const [h, p, s] = jws.split(".");
  const tamperedPayload = base64url(new TextEncoder().encode(JSON.stringify({ notificationType: "REFUND" })));
  const tampered = `${h}.${tamperedPayload}.${s}`;

  await assertRejects(
    () => verifyAppleSignedPayload(tampered, root.toString("pem")),
    AppleSignedPayloadError,
    "signature verification failed",
  );
});

Deno.test("verifyAppleSignedPayload rejects a chain signed by an unrelated key (not just wrong root)", async () => {
  const { root, intermediate } = await buildFixtureChain();
  const { leaf: rogueLeaf, leafKeys: rogueKeys } = await buildFixtureChain().then(async (fixture) => {
    // A leaf whose issuer name claims "Test Intermediate" but is actually self-signed —
    // simulates an attacker who controls a leaf key but not the real intermediate's key.
    const rogue = await x509.X509CertificateGenerator.create({
      serialNumber: "99", subject: "CN=Rogue Leaf", issuer: "CN=Test Intermediate",
      notBefore: new Date("2020-01-01"), notAfter: new Date("2035-01-01"),
      signingAlgorithm: ALG, publicKey: fixture.leafKeys.publicKey, signingKey: fixture.leafKeys.privateKey,
    });
    return { leaf: rogue, leafKeys: fixture.leafKeys };
  });
  const jws = await signJws({ notificationType: "SUBSCRIBED" }, rogueLeaf, intermediate, rogueKeys.privateKey);

  await assertRejects(
    () => verifyAppleSignedPayload(jws, root.toString("pem")),
    AppleSignedPayloadError,
    "certificate chain broken",
  );
});

Deno.test("verifyAppleSignedPayload rejects a non-ES256 alg", async () => {
  const { root, intermediate, leaf, leafKeys } = await buildFixtureChain();
  const jws = await signJws({ notificationType: "SUBSCRIBED" }, leaf, intermediate, leafKeys.privateKey);
  const [h, p, s] = jws.split(".");
  const header = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(h.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))));
  header.alg = "none";
  const forgedHeader = base64url(new TextEncoder().encode(JSON.stringify(header)));
  const forged = `${forgedHeader}.${p}.${s}`;

  await assertRejects(() => verifyAppleSignedPayload(forged, root.toString("pem")), AppleSignedPayloadError);
});

// MARK: - deriveEntitlementStatus (pure)

Deno.test("deriveEntitlementStatus: active when no expiry/revocation", () => {
  assertEquals(deriveEntitlementStatus({ productId: "p", originalTransactionId: "1", transactionId: "1" }), "active");
});

Deno.test("deriveEntitlementStatus: expired when expiresDate is in the past", () => {
  const now = new Date("2026-07-07T00:00:00Z");
  const info = { productId: "p", originalTransactionId: "1", transactionId: "1", expiresDate: Date.parse("2026-01-01T00:00:00Z") };
  assertEquals(deriveEntitlementStatus(info, now), "expired");
});

Deno.test("deriveEntitlementStatus: active when expiresDate is in the future", () => {
  const now = new Date("2026-07-07T00:00:00Z");
  const info = { productId: "p", originalTransactionId: "1", transactionId: "1", expiresDate: Date.parse("2027-01-01T00:00:00Z") };
  assertEquals(deriveEntitlementStatus(info, now), "active");
});

Deno.test("deriveEntitlementStatus: revoked takes priority over expiry", () => {
  const now = new Date("2026-07-07T00:00:00Z");
  const info = {
    productId: "p", originalTransactionId: "1", transactionId: "1",
    expiresDate: Date.parse("2027-01-01T00:00:00Z"), revocationDate: Date.parse("2026-06-01T00:00:00Z"),
  };
  assertEquals(deriveEntitlementStatus(info, now), "revoked");
});
