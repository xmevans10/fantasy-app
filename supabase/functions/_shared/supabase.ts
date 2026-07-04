import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/** Service-role client for Edge Functions (bypasses RLS — server-trusted code only). */
export function serviceClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
}
