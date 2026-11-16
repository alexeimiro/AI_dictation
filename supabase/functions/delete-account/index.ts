// POST /functions/v1/delete-account (authenticated)
// Body (optional): { appleAuthorizationCode } for an account that signed in with Apple: a fresh
// code from Apple, exchanged and revoked first, as Apple requires (_shared/apple_signin.ts).
// Deletes the caller's account; all their rows cascade (profiles, dictionary, snippets, notes,
// usage, entitlements, …). App Store subscriptions are not cancelled — the app tells the user.
// One thing outlives the account, for 30 days: a fingerprint of its sign-in with the words it used
// this week, its trial and its invite, so that signing up again doesn't reset the free plan
// (_shared/delete_account.ts, migration 20261117000000).
//   200 { deleted: true, apple: "revoked" | "exchange_failed" | "revoke_failed" | "skipped",
//         kept: "kept" | "none" | "failed" }
//   401 unauthorized · 503 unavailable
// Neither the revocation nor the record ever blocks the deletion.
import { appleSignInConfig, revokeWithCode } from "../_shared/apple_signin.ts";
import { createDeleteAccountHandler } from "../_shared/delete_account.ts";
import { adminClient, authenticate } from "../_shared/http.ts";

const admin = adminClient();
const apple = appleSignInConfig();

Deno.serve(createDeleteAccountHandler({
  authenticate: (request) => authenticate(request, admin),
  revokeApple: apple && ((code) => revokeWithCode(code, apple, { signal: AbortSignal.timeout(8000) })),
  retire: async (userId) => {
    const { data, error } = await admin.rpc("retire_account", { p_user: userId });
    if (error) throw new Error(`${error.code ?? "unknown"} ${error.message ?? ""}`.trim());
    return String(data);
  },
  deleteUser: async (userId) => {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) throw error;
  },
}));
