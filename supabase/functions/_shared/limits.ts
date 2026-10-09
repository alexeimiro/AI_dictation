import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { clientIP } from "./http.ts";

/** SHA-256 of the client IP, so rate-limit keys don't store personal data. */
export async function hashedIP(request: Request): Promise<string> {
  const bytes = new TextEncoder().encode(clientIP(request));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest).slice(0, 12), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** True if the caller is still within `limit` requests per window for `scope`. */
export async function withinLimit(
  admin: SupabaseClient,
  request: Request,
  scope: string,
  limit: number,
  windowSeconds = 60,
): Promise<boolean> {
  const key = `${scope}:${await hashedIP(request)}`;
  const { data, error } = await admin.rpc("consume_bucket", {
    p_key: key,
    p_limit: limit,
    p_window_seconds: windowSeconds,
  });
  if (error) {
    console.error("rate limit check failed", error);
    return true;
  }
  return data === true;
}
