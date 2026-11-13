import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-murmur-warm, x-murmur-dictation",
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
  const key = serverKey(Deno.env.get("SUPABASE_SECRET_KEYS"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  if (!url || !key) throw new Error("SUPABASE_URL / SUPABASE_SECRET_KEYS not set");
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

/**
 * The key that bypasses RLS. Projects with the new API keys get `SUPABASE_SECRET_KEYS`, a JSON
 * object of named keys ({"default": "sb_secret_…"}); the legacy `SUPABASE_SERVICE_ROLE_KEY` is
 * deprecated at the end of 2026 and absent from newer projects.
 */
export function serverKey(secretKeys: string | undefined, legacyKey: string | undefined): string | undefined {
  if (secretKeys) {
    try {
      const keys = JSON.parse(secretKeys) as Record<string, unknown>;
      if (typeof keys.default === "string" && keys.default) return keys.default;
    } catch {
      // Malformed: fall back to the legacy key.
    }
  }
  return legacyKey || undefined;
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

/** The caller's `x-client-info` (app build or SDK version) for the logs, capped: the client sets it. */
export function clientInfo(request: Request): string | null {
  return request.headers.get("x-client-info")?.slice(0, 64) ?? null;
}

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

/** What was handed to `background` and hasn't settled yet. */
const pending = new Set<Promise<unknown>>();

/**
 * Runs work after the response is sent (usage accounting, logs, a live session's sockets). On
 * Supabase the worker is kept alive for it; a long-running server waits for it before it stops
 * (`drainBackground`).
 */
export function background(promise: PromiseLike<unknown>): void {
  const task = Promise.resolve(promise).catch((error) => console.error("background task failed", error));
  pending.add(task);
  task.then(() => pending.delete(task));
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(task);
}

/**
 * Settles once everything handed to `background` has settled, or after `timeoutMs`, whichever is
 * first: what a server about to stop waits for. Resolves to how much was still unfinished.
 */
export async function drainBackground(timeoutMs: number): Promise<number> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<void>((resolve) => timer = setTimeout(resolve, timeoutMs));
  const settled = (async () => {
    // Work can hand over more work while it is waited for.
    while (pending.size > 0) await Promise.allSettled([...pending]);
  })();
  await Promise.race([settled, deadline]);
  clearTimeout(timer);
  return pending.size;
}
