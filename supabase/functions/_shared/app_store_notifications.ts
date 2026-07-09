// Verification for Apple's signed JWS payloads: the outer App Store Server Notifications V2
// envelope, and the `signedTransactionInfo`/`signedRenewalInfo` strings nested inside it — all
// three use the same "JWS with an x5c certificate chain in the header" shape (RFC 7515 §4.1.6).
//
// Unlike apns.ts (hand-rolled ES256 JWT *signing*, no external library — see that file's own
// comment), *verifying* an X.509 certificate chain requires parsing DER/ASN.1 structures to
// extract each certificate's TBS bytes, signature, and issuer's public key. That's meaningfully
// harder and higher-stakes to get right from scratch than signing a token, so this uses
// `@peculiar/x509` (MIT, esm.sh — same import mechanism already used for
// `@supabase/supabase-js` in _shared/supabase.ts) rather than a hand-rolled ASN.1 parser.
import * as x509 from "https://esm.sh/@peculiar/x509@1.9.7?target=deno";

x509.cryptoProvider.set(crypto);

export class AppleSignedPayloadError extends Error {}

function decodeBase64Url(s: string): Uint8Array<ArrayBuffer> {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/").padEnd(s.length + ((4 - (s.length % 4)) % 4), "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** `x5c` entries are standard base64 (RFC 4648 §4), NOT base64url, per RFC 7515 §4.1.6. */
function decodeBase64Std(s: string): Uint8Array<ArrayBuffer> {
  const binary = atob(s);
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Strips PEM headers/newlines and returns the raw DER bytes — mirrors apns.ts's
 * `pemToPkcs8Der`, applied here to a certificate instead of a private key. */
function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const stripped = pem
    .replace(/-----BEGIN CERTIFICATE-----/, "")
    .replace(/-----END CERTIFICATE-----/, "")
    .replace(/\s+/g, "");
  return decodeBase64Std(stripped);
}

function splitJws(jws: string): { headerB64: string; payloadB64: string; sigB64: string } {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new AppleSignedPayloadError("malformed JWS: expected 3 segments");
  return { headerB64: parts[0], payloadB64: parts[1], sigB64: parts[2] };
}

/**
 * Verifies a JWS's x5c certificate chain terminates at `trustedRootPem` and that the JWS
 * signature itself is valid under the leaf certificate's public key, then returns the decoded
 * JSON payload. Throws `AppleSignedPayloadError` on any verification failure — callers must
 * never act on a caught error's partial state.
 *
 * `trustedRootPem` is Apple's Root CA (G3) certificate, injected via the `APPLE_ROOT_CA_PEM`
 * Edge Function secret rather than hardcoded — avoids transcribing a security-critical
 * certificate blob into source, and lets it rotate without a code deploy.
 */
export async function verifyAppleSignedPayload(
  jws: string,
  trustedRootPem: string,
): Promise<Record<string, unknown>> {
  const { headerB64, payloadB64, sigB64 } = splitJws(jws);
  const header = JSON.parse(new TextDecoder().decode(decodeBase64Url(headerB64))) as {
    alg?: string;
    x5c?: string[];
  };

  if (header.alg !== "ES256") {
    throw new AppleSignedPayloadError(`unsupported JWS alg: ${header.alg}`);
  }
  const x5c = header.x5c;
  if (!x5c || x5c.length === 0) {
    throw new AppleSignedPayloadError("missing x5c certificate chain in JWS header");
  }

  const certs = x5c.map((c) => new x509.X509Certificate(decodeBase64Std(c)));
  const leaf = certs[0];

  // Every provided cert must be signed by the next one in the chain.
  for (let i = 0; i < certs.length - 1; i++) {
    const ok = await certs[i].verify({ publicKey: certs[i + 1].publicKey });
    if (!ok) throw new AppleSignedPayloadError(`certificate chain broken at index ${i}`);
  }

  // The last provided cert must itself be (or be signed by) the pinned trusted root — Apple's
  // notifications typically supply leaf + intermediate only, with the root trusted out-of-band.
  // deno-lint-ignore no-explicit-any -- esm.sh's generated .d.ts for X509Certificate's
  // AsnEncodedType-accepting constructor resolves to `never` under `deno check` (a type-gen
  // quirk, not a real ambiguity — see app_store_notifications.test.ts's passing fixture-chain
  // tests run with --no-check for the same reason). Runtime behavior is correct either way.
  const trustedRoot: any = new x509.X509Certificate(pemToDer(trustedRootPem));
  const lastInChain = certs[certs.length - 1];
  const chainedToRoot = lastInChain.equal(trustedRoot) ||
    (await lastInChain.verify({ publicKey: trustedRoot.publicKey }));
  if (!chainedToRoot) {
    throw new AppleSignedPayloadError("certificate chain does not terminate at the trusted root");
  }

  const now = new Date();
  for (const cert of certs) {
    if (now < cert.notBefore || now > cert.notAfter) {
      throw new AppleSignedPayloadError("a certificate in the chain is outside its validity period");
    }
  }

  const publicKey = await leaf.publicKey.export();
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    decodeBase64Url(sigB64) as BufferSource,
    signingInput,
  );
  if (!valid) throw new AppleSignedPayloadError("JWS signature verification failed");

  return JSON.parse(new TextDecoder().decode(decodeBase64Url(payloadB64)));
}

// MARK: - Notification payload shapes (subset of Apple's App Store Server Notifications V2)

export interface AppleNotificationPayload {
  notificationType: string;
  subtype?: string;
  data?: {
    signedTransactionInfo?: string;
    signedRenewalInfo?: string;
  };
}

export interface AppleTransactionInfo {
  productId: string;
  originalTransactionId: string;
  transactionId: string;
  /** Epoch milliseconds. Absent for non-consumables (they never expire). */
  expiresDate?: number;
  /** Epoch milliseconds — present only when Apple revoked/refunded the transaction. */
  revocationDate?: number;
  /** Our own uuid, set at purchase time via `Product.PurchaseOption.appAccountToken`. */
  appAccountToken?: string;
}

export type EntitlementStatus = "active" | "expired" | "revoked";

/** Pure — no I/O, easy to lock with tests. */
export function deriveEntitlementStatus(info: AppleTransactionInfo, now: Date = new Date()): EntitlementStatus {
  if (info.revocationDate !== undefined) return "revoked";
  if (info.expiresDate !== undefined && info.expiresDate < now.getTime()) return "expired";
  return "active";
}
