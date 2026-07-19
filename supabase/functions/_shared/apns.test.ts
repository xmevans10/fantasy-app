import { assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildDailyDropPayload,
  buildFriendRequestPayload,
  buildLeaguePositionPayload,
  buildSeasonEndPayload,
  buildStreakAtRiskPayload,
  buildVersusChallengePayload,
  resetApnsTokenCacheForTesting,
  sendApnsPush,
  signApnsJwt,
} from "./apns.ts";

// Throwaway EC P-256 keypair generated solely for these tests (openssl ecparam -genkey
// -name prime256v1 | openssl pkcs8 -topk8 -nocrypt). NOT a real APNs key — do not reuse.
const TEST_PRIVATE_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg7JRPoeO42OmvU9aN
yYGoJN4huVpoRDArTgYrnEo3DVahRANCAARrz7SNDgC2dFTky/jxS6/D9+8e0Ae+
8iy5Vbre/nZGVbqMJXqFQz/Ign89hSmPwGCMC9h9AkZ9Tp3JIyVMVKB/
-----END PRIVATE KEY-----`;
const TEST_PUBLIC_KEY_PEM = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEa8+0jQ4AtnRU5Mv48Uuvw/fvHtAH
vvIsuVW63v52RlW6jCV6hUM/yIJ/PYUpj8BgjAvYfQJGfU6dySMlTFSgfw==
-----END PUBLIC KEY-----`;

function base64urlDecode(s: string): Uint8Array {
  const padded = s.replace(/-/g, "+").replace(/_/g, "/").padEnd(s.length + ((4 - (s.length % 4)) % 4), "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function importTestPublicKey(): Promise<CryptoKey> {
  const stripped = TEST_PUBLIC_KEY_PEM.replace(/-----BEGIN PUBLIC KEY-----/, "")
    .replace(/-----END PUBLIC KEY-----/, "").replace(/\s+/g, "");
  const binary = atob(stripped);
  const der = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) der[i] = binary.charCodeAt(i);
  return crypto.subtle.importKey("spki", der as BufferSource, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
}

Deno.test("signApnsJwt produces a 3-segment token with the correct header", async () => {
  const jwt = await signApnsJwt("KEYID123", "TEAMID456", TEST_PRIVATE_KEY_PEM, () => 1_700_000_000_000);
  const [headerB64, claimsB64, sigB64] = jwt.split(".");
  assertEquals(jwt.split(".").length, 3);

  const header = JSON.parse(new TextDecoder().decode(base64urlDecode(headerB64)));
  assertEquals(header.alg, "ES256");
  assertEquals(header.kid, "KEYID123");

  const claims = JSON.parse(new TextDecoder().decode(base64urlDecode(claimsB64)));
  assertEquals(claims.iss, "TEAMID456");
  assertEquals(claims.iat, 1_700_000_000);

  // Signature round-trip: verify with the corresponding public key — proves the signing
  // routine produces a spec-valid ES256 signature without needing Apple's servers at all.
  const publicKey = await importTestPublicKey();
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    base64urlDecode(sigB64) as BufferSource,
    new TextEncoder().encode(`${headerB64}.${claimsB64}`),
  );
  assertEquals(valid, true);
});

Deno.test("sendApnsPush reuses the cached token within the TTL, re-mints after", async () => {
  resetApnsTokenCacheForTesting();
  Deno.env.set("APNS_KEY_ID", "KEYID123");
  Deno.env.set("APNS_TEAM_ID", "TEAMID456");
  Deno.env.set("APNS_PRIVATE_KEY", TEST_PRIVATE_KEY_PEM);
  Deno.env.set("APNS_BUNDLE_ID", "com.balliqfantasy.app");

  const seenAuthHeaders: string[] = [];
  const fakeFetch: typeof fetch = async (_url, init) => {
    const headers = init?.headers as Record<string, string>;
    seenAuthHeaders.push(headers.authorization);
    return new Response(null, { status: 200 });
  };

  let clock = 1_700_000_000_000;
  await sendApnsPush("device-token-1", buildStreakAtRiskPayload(3), { fetch: fakeFetch, now: () => clock });
  clock += 60_000; // 1 minute later — well within the 50-minute TTL
  await sendApnsPush("device-token-2", buildStreakAtRiskPayload(3), { fetch: fakeFetch, now: () => clock });
  assertEquals(seenAuthHeaders[0], seenAuthHeaders[1], "token should be reused within TTL");

  clock += 51 * 60 * 1000; // past the 50-minute re-mint threshold
  await sendApnsPush("device-token-3", buildStreakAtRiskPayload(3), { fetch: fakeFetch, now: () => clock });
  const [, claimsB64Third] = seenAuthHeaders[2].replace("bearer ", "").split(".");
  const [, claimsB64First] = seenAuthHeaders[0].replace("bearer ", "").split(".");
  assertEquals(seenAuthHeaders[0] === seenAuthHeaders[2], false, "token should be re-minted after TTL");
  const thirdIat = JSON.parse(new TextDecoder().decode(base64urlDecode(claimsB64Third))).iat;
  const firstIat = JSON.parse(new TextDecoder().decode(base64urlDecode(claimsB64First))).iat;
  assertEquals(thirdIat > firstIat, true);

  resetApnsTokenCacheForTesting();
  Deno.env.delete("APNS_KEY_ID");
  Deno.env.delete("APNS_TEAM_ID");
  Deno.env.delete("APNS_PRIVATE_KEY");
  Deno.env.delete("APNS_BUNDLE_ID");
});

Deno.test("sendApnsPush sends the correct request shape (topic, push-type, payload)", async () => {
  resetApnsTokenCacheForTesting();
  Deno.env.set("APNS_KEY_ID", "KEYID123");
  Deno.env.set("APNS_TEAM_ID", "TEAMID456");
  Deno.env.set("APNS_PRIVATE_KEY", TEST_PRIVATE_KEY_PEM);
  Deno.env.set("APNS_BUNDLE_ID", "com.balliqfantasy.app");

  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  const fakeFetch: typeof fetch = async (url, init) => {
    capturedUrl = url.toString();
    capturedInit = init;
    return new Response(null, { status: 200 });
  };

  await sendApnsPush("abc123", buildVersusChallengePayload("xander"), { fetch: fakeFetch });

  assertEquals(capturedUrl, "https://api.push.apple.com/3/device/abc123");
  const headers = capturedInit?.headers as Record<string, string>;
  assertEquals(headers["apns-topic"], "com.balliqfantasy.app");
  assertEquals(headers["apns-push-type"], "alert");
  assertStringIncludes(headers.authorization, "bearer ");
  const body = JSON.parse(capturedInit?.body as string);
  assertEquals(body.aps.category, "versus_challenge");
  assertStringIncludes(body.aps.alert.body, "xander");
  assertEquals(body.tab, "versus");

  resetApnsTokenCacheForTesting();
  Deno.env.delete("APNS_KEY_ID");
  Deno.env.delete("APNS_TEAM_ID");
  Deno.env.delete("APNS_PRIVATE_KEY");
  Deno.env.delete("APNS_BUNDLE_ID");
});

Deno.test("sendApnsPush throws on a non-2xx APNs response", async () => {
  resetApnsTokenCacheForTesting();
  Deno.env.set("APNS_KEY_ID", "KEYID123");
  Deno.env.set("APNS_TEAM_ID", "TEAMID456");
  Deno.env.set("APNS_PRIVATE_KEY", TEST_PRIVATE_KEY_PEM);
  Deno.env.set("APNS_BUNDLE_ID", "com.balliqfantasy.app");

  const fakeFetch: typeof fetch = async () =>
    new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 });

  let threw = false;
  try {
    await sendApnsPush("bad-token", buildStreakAtRiskPayload(1), { fetch: fakeFetch });
  } catch (e) {
    threw = true;
    assertStringIncludes((e as Error).message, "BadDeviceToken");
  }
  assertEquals(threw, true);

  resetApnsTokenCacheForTesting();
  Deno.env.delete("APNS_KEY_ID");
  Deno.env.delete("APNS_TEAM_ID");
  Deno.env.delete("APNS_PRIVATE_KEY");
  Deno.env.delete("APNS_BUNDLE_ID");
});

Deno.test("streak-at-risk payload includes the current streak length", () => {
  const payload = buildStreakAtRiskPayload(7);
  assertEquals(payload.category, "streak_at_risk");
  assertStringIncludes(payload.body, "7-day streak");
});

Deno.test("versus-challenge payload names the challenger", () => {
  const payload = buildVersusChallengePayload("xander");
  assertStringIncludes(payload.body, "xander");
  assertEquals(payload.data?.tab, "versus");
});

Deno.test("league-position payload varies by zone", () => {
  const promoted = buildLeaguePositionPayload("promoted");
  const relegated = buildLeaguePositionPayload("relegated");
  assertStringIncludes(promoted.title.toLowerCase(), "promoting");
  assertStringIncludes(relegated.title.toLowerCase(), "relegation");
});

Deno.test("season-end payload includes hours remaining", () => {
  const payload = buildSeasonEndPayload(18);
  assertStringIncludes(payload.body, "18h");
});

Deno.test("friend-request payload names the requester", () => {
  const payload = buildFriendRequestPayload("xander");
  assertStringIncludes(payload.body, "xander");
  assertEquals(payload.data?.tab, "friends");
});

Deno.test("daily-drop payload names today's theme when known, stays generic otherwise", () => {
  const themed = buildDailyDropPayload("One-Team Legends");
  assertEquals(themed.category, "daily_drop");
  assertStringIncludes(themed.body, "One-Team Legends");
  assertEquals(themed.data?.tab, "home");

  const generic = buildDailyDropPayload(null);
  assertEquals(generic.category, "daily_drop");
  assertStringIncludes(generic.body, "mystery player");
});
