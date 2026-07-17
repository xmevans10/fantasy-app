// Resolves the Apple Root CA - G3 PEM (the trust anchor for App Store Server Notifications V2
// JWS chain verification). The `APPLE_ROOT_CA_PEM` env secret wins when present; otherwise this
// fetches it once per isolate from Supabase Vault via the service-role-only
// `get_app_store_config()` RPC — the same pattern `apns.ts` uses for the APNs key, adopted
// because no management token exists in the agent environment to set true Edge Function
// secrets. The cert is public (published on Apple's PKI page), so Vault storage is for
// operational convenience/rotation, not confidentiality.

let cachedRootPem: string | null = null;

export async function loadAppleRootPem(doFetch: typeof fetch): Promise<string | undefined> {
  const fromEnv = Deno.env.get("APPLE_ROOT_CA_PEM");
  if (fromEnv) return fromEnv;
  if (cachedRootPem) return cachedRootPem;

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return undefined;

  try {
    const res = await doFetch(`${supabaseUrl}/rest/v1/rpc/get_app_store_config`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        authorization: `Bearer ${serviceKey}`,
        "content-type": "application/json",
      },
      body: "{}",
    });
    if (!res.ok) throw new Error(`get_app_store_config ${res.status}`);
    const vault = (await res.json()) as Record<string, string> | null;
    const pem = vault?.APPLE_ROOT_CA_PEM;
    if (pem) cachedRootPem = pem;
    return pem;
  } catch (e) {
    console.error("[app-store-config] vault fetch failed:", e);
    return undefined;
  }
}
