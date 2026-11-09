// POST /functions/v1/delete-account (authenticated)
// Body (optional): { appleAuthorizationCode } for an account that signed in with Apple: a fresh
// code from Apple, exchanged and revoked first, as Apple requires (_shared/apple_signin.ts).
// Deletes the caller's account; all their rows cascade (profiles, dictionary, snippets, notes,
// usage, entitlements, …). App Store subscriptions are not cancelled — the app tells the user.
//   200 { deleted: true, apple: "revoked" | "exchange_failed" | "revoke_failed" | "skipped" }
//   401 unauthorized · 503 unavailable
// The revocation never blocks the deletion.
import { appleSignInConfig, revokeWithCode } from "../_shared/apple_signin.ts";
import { adminClient, authenticate, corsHeaders, json } from "../_shared/http.ts";

const admin = adminClient();
const apple = appleSignInConfig();

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const caller = await authenticate(request, admin);
  if (!caller) return json({ error: "unauthorized" }, 401);

  const body = await request.json().catch(() => ({})) as { appleAuthorizationCode?: unknown };
  const code = typeof body.appleAuthorizationCode === "string" && body.appleAuthorizationCode.length <= 1000
    ? body.appleAuthorizationCode : null;
  const appleOutcome = code && apple
    ? await revokeWithCode(code, apple, { signal: AbortSignal.timeout(8000) })
    : "skipped";

  const { error } = await admin.auth.admin.deleteUser(caller.userId);
  if (error) {
    console.error("delete user failed", error);
    return json({ error: "unavailable" }, 503);
  }
  console.log(JSON.stringify({ event: "account_deleted", anonymous: caller.isAnonymous, apple: appleOutcome }));
  return json({ deleted: true, apple: appleOutcome });
});
