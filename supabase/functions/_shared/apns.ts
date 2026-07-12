// Shared push-payload builder + sender. The payload builders are pure (unit-testable from
// Deno's test runner). JWT signing + delivery below is real (Web Crypto, no external library);
// the remaining hand-off is only the actual secret material.
//
// Hand-off (cannot be done by the agent): generate an APNs auth key (.p8) in the Apple
// Developer portal, enable the "Push Notifications" capability on the App ID, and set
// APNS_KEY_ID / APNS_TEAM_ID / APNS_PRIVATE_KEY / APNS_BUNDLE_ID as Edge Function secrets
// (`supabase secrets set ...`). Until then this function logs instead of sending.

export type NotificationCategory =
  | "streak_at_risk"
  | "league_position"
  | "versus_challenge"
  | "season_end"
  | "friend_request";

export interface PushPayload {
  category: NotificationCategory;
  title: string;
  body: string;
  /** Arbitrary deep-link data the app reads on tap, e.g. { tab: "versus", challengeId: 42 }. */
  data?: Record<string, unknown>;
}

export function buildStreakAtRiskPayload(streak: number): PushPayload {
  return {
    category: "streak_at_risk",
    title: "Your streak is at risk!",
    body: `You're on a ${streak}-day streak. Play today's puzzle before midnight to keep it alive.`,
    data: { tab: "home" },
  };
}

export function buildLeaguePositionPayload(zone: "promoted" | "relegated" | "safe" | "danger"): PushPayload {
  const copy: Record<typeof zone, [string, string]> = {
    promoted: ["You're promoting!", "You're in the top 5 of your league — finish strong to lock it in."],
    relegated: ["You're at risk of relegation", "You've dropped into the bottom 5. Play today to climb back up."],
    safe: ["League update", "You're holding steady in the middle of your league."],
    danger: ["Close race in your league", "Your league position is close — check the standings."],
  };
  const [title, body] = copy[zone];
  return { category: "league_position", title, body, data: { tab: "leagues" } };
}

export function buildVersusChallengePayload(challengerUsername: string): PushPayload {
  return {
    category: "versus_challenge",
    title: "New Versus challenge",
    body: `${challengerUsername} challenged you to today's puzzle.`,
    data: { tab: "versus" },
  };
}

export function buildSeasonEndPayload(hoursRemaining: number): PushPayload {
  return {
    category: "season_end",
    title: "Season ending soon",
    body: `Your league's season ends in ${hoursRemaining}h — make sure your XP is locked in.`,
    data: { tab: "leagues" },
  };
}

export function buildFriendRequestPayload(requesterUsername: string): PushPayload {
  return {
    category: "friend_request",
    title: "New friend request",
    body: `${requesterUsername} wants to be friends on BallIQ.`,
    data: { tab: "friends" },
  };
}

// MARK: - ES256 JWT signing (Web Crypto, no external library)

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64urlJson(obj: unknown): string {
  return base64url(new TextEncoder().encode(JSON.stringify(obj)));
}

/** Strips the PEM header/footer/newlines from a `.p8` key and returns the raw PKCS8 DER bytes. */
function pemToPkcs8Der(pem: string): Uint8Array {
  const stripped = pem
    .replace(/-----BEGIN (EC )?PRIVATE KEY-----/, "")
    .replace(/-----END (EC )?PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(stripped);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/**
 * Signs an APNs auth token: ES256 JWT with header `{alg: "ES256", kid: keyId}` and claims
 * `{iss: teamId, iat: now}`. Web Crypto's ECDSA signature output is already the raw `r‖s`
 * concatenation JWS ES256 wants — no DER re-encoding needed, unlike some other crypto libraries.
 * Exported (not just used internally) so tests can verify the signing math without a real key.
 */
export async function signApnsJwt(
  keyId: string,
  teamId: string,
  privateKeyPem: string,
  now: () => number = Date.now,
): Promise<string> {
  const header = base64urlJson({ alg: "ES256", kid: keyId });
  const claims = base64urlJson({ iss: teamId, iat: Math.floor(now() / 1000) });
  const signingInput = `${header}.${claims}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8Der(privateKeyPem) as BufferSource,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

// Module-level cache: APNs auth tokens are valid up to 1h; re-signing per-push is wasteful,
// especially inside a cron batch that pushes to many device tokens at once. Re-minted 10 minutes
// before the real 1h expiry to leave margin for in-flight requests.
let cachedToken: { token: string; mintedAt: number } | null = null;
const TOKEN_TTL_MS = 50 * 60 * 1000;

async function apnsToken(keyId: string, teamId: string, privateKey: string, now: () => number): Promise<string> {
  if (cachedToken && now() - cachedToken.mintedAt < TOKEN_TTL_MS) return cachedToken.token;
  const token = await signApnsJwt(keyId, teamId, privateKey, now);
  cachedToken = { token, mintedAt: now() };
  return token;
}

/** Clears the module-level token cache. Test-only — production never needs to force a re-mint. */
export function resetApnsTokenCacheForTesting(): void {
  cachedToken = null;
}

/**
 * Sends one push via APNs. `deps` is an injection seam so tests can assert the exact request
 * shape (URL, headers, body) without a network call or a real APNs key.
 */
export async function sendApnsPush(
  deviceToken: string,
  payload: PushPayload,
  deps: { fetch?: typeof fetch; now?: () => number } = {},
): Promise<void> {
  const doFetch = deps.fetch ?? fetch;
  const now = deps.now ?? Date.now;

  const keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID");
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY");
  const bundleId = Deno.env.get("APNS_BUNDLE_ID");

  if (!keyId || !teamId || !privateKey || !bundleId) {
    console.log(`[apns:stub] would send to ${deviceToken}:`, JSON.stringify(payload));
    return;
  }

  const jwt = await apnsToken(keyId, teamId, privateKey, now);
  const res = await doFetch(`https://api.push.apple.com/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": bundleId,
      "apns-push-type": "alert",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title: payload.title, body: payload.body }, category: payload.category },
      ...payload.data,
    }),
  });

  if (!res.ok) {
    const reason = await res.text().catch(() => "");
    // 410/Unregistered means the device token is stale — the caller (notify-* functions) should
    // prune it from device_tokens; wiring that cleanup is a fast-follow, not done here.
    throw new Error(`sendApnsPush: APNs rejected push (${res.status}): ${reason}`);
  }
}
