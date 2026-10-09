// POST /functions/v1/auth-lookup  { email }
// → { exists, providers } — decides between "Logging in" (password) and "Create your account".
// Rate-limited per IP (this reveals whether an email has an account).
import { adminClient, corsHeaders, json } from "../_shared/http.ts";
import { withinLimit } from "../_shared/limits.ts";

const admin = adminClient();
const EMAIL = /^[^\s@]{1,64}@[^\s@]{1,255}\.[^\s@]{2,}$/;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const body = await request.json().catch(() => null) as { email?: unknown } | null;
  const email = typeof body?.email === "string" ? body.email.trim() : "";
  if (!EMAIL.test(email) || email.length > 320) return json({ error: "bad_request" }, 400);

  if (!(await withinLimit(admin, request, "auth-lookup", 10))) {
    return json({ error: "rate_limited" }, 429);
  }

  const { data, error } = await admin
    .rpc("auth_lookup", { p_email: email })
    .single<{ account_exists: boolean; confirmed: boolean; providers: string[] }>();
  if (error || !data) {
    console.error("auth_lookup failed", error);
    return json({ error: "unavailable" }, 503);
  }
  return json({ exists: data.account_exists, providers: data.providers });
});
