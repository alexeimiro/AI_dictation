// POST /functions/v1/signup-status  { userId }
// → { confirmed } — lets "Check your email" advance when the link was opened on another device,
// without re-signing in every few seconds (each sign-in would need a fresh captcha token).
import { adminClient, corsHeaders, json } from "../_shared/http.ts";
import { withinLimit } from "../_shared/limits.ts";

const admin = adminClient();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const body = await request.json().catch(() => null) as { userId?: unknown } | null;
  const userId = typeof body?.userId === "string" ? body.userId : "";
  if (!UUID.test(userId)) return json({ error: "bad_request" }, 400);

  if (!(await withinLimit(admin, request, "signup-status", 40))) {
    return json({ error: "rate_limited" }, 429);
  }

  const { data, error } = await admin.auth.admin.getUserById(userId);
  if (error || !data.user) return json({ confirmed: false });
  return json({ confirmed: data.user.email_confirmed_at != null });
});
