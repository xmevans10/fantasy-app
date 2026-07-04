// Runs frequently (hand-off: schedule e.g. every 15 min via pg_cron). Forfeits any challenge
// whose 24h window has lapsed with at least one side not having submitted a score, via the same
// `resolve_versus_challenge` RPC the normal completion path uses (handles winner + series advance).
import { serviceClient } from "../_shared/supabase.ts";

Deno.serve(async (_req) => {
  const sb = serviceClient();

  const { data: expired, error } = await sb
    .from("versus_challenges")
    .select("id")
    .eq("status", "pending")
    .lt("expires_at", new Date().toISOString());
  if (error) throw error;

  let resolved = 0;
  for (const challenge of expired ?? []) {
    const { error: rpcErr } = await sb.rpc("resolve_versus_challenge", { p_challenge_id: challenge.id });
    if (!rpcErr) resolved++;
  }

  return new Response(JSON.stringify({ checked: expired?.length ?? 0, resolved }), {
    headers: { "Content-Type": "application/json" },
  });
});
