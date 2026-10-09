import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/** Service-role client. Never expose its results unfiltered. */
export function adminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not set");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

export interface Caller {
  userId: string;
  isAnonymous: boolean;
}

/** Verifies the bearer JWT (locally with JWKS when available) and returns the caller. */
export async function authenticate(request: Request, admin: SupabaseClient): Promise<Caller | null> {
  const header = request.headers.get("Authorization") ?? "";
  const jwt = header.replace(/^Bearer\s+/i, "");
  if (!jwt) return null;
  const { data, error } = await admin.auth.getClaims(jwt);
  const claims = data?.claims;
  if (error || !claims?.sub) return null;
  return { userId: claims.sub, isAnonymous: claims.is_anonymous === true };
}

export function clientIP(request: Request): string {
  return request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
}

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

/** Runs work after the response is sent (usage accounting, logs). */
export function background(promise: PromiseLike<unknown>): void {
  const task = Promise.resolve(promise).catch((error) => console.error("background task failed", error));
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(task);
}
