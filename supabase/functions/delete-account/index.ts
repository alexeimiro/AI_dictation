// POST /functions/v1/delete-account (authenticated)
// Deletes the caller's account. All their rows cascade (profiles, dictionary, snippets, notes,
// usage, entitlements, …). App Store subscriptions are not cancelled — the app tells the user.
// TODO(Phase 5): revoke the Sign in with Apple refresh token (https://appleid.apple.com/auth/revoke),
// which requires exchanging the authorization code at sign-in and storing the refresh token.
import { adminClient, authenticate, corsHeaders, json } from "../_shared/http.ts";

const admin = adminClient();

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const caller = await authenticate(request, admin);
  if (!caller) return json({ error: "unauthorized" }, 401);

  const { error } = await admin.auth.admin.deleteUser(caller.userId);
  if (error) {
    console.error("delete user failed", error);
    return json({ error: "unavailable" }, 503);
  }
  console.log(JSON.stringify({ event: "account_deleted", anonymous: caller.isAnonymous }));
  return json({ deleted: true });
});
