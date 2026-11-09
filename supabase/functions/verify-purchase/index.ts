// POST /functions/v1/verify-purchase (authenticated)
// Body: { transaction: <StoreKit 2 signed transaction (JWS)> }, sent after a purchase, a renewal
// the app sees, and Restore purchase. Verified against Apple's root certificates (with online
// revocation checks); Murmur Pro then lasts until the subscription expires. The handler is
// _shared/app_store.ts.
//   200 the caller's quota_status row (plan, on_trial, trial_ends_at, words_this_week, …)
//   400 bad_request | invalid_transaction | unknown_product · 401 unauthorized
//   409 other_account: the subscription belongs to another Murmur account · 503 unavailable
// Env: APP_STORE_SANDBOX=0 refuses Sandbox purchases. They're accepted by default, since TestFlight
// testers use the same backend.
import { appleVerifier, createPurchaseHandler } from "../_shared/app_store.ts";
import { applyEntitlement, subscriptionOwner } from "../_shared/entitlements.ts";
import { adminClient, authenticate } from "../_shared/http.ts";

const admin = adminClient();

Deno.serve(createPurchaseHandler({
  authenticate: (request) => authenticate(request, admin),
  verifier: appleVerifier({ allowSandbox: Deno.env.get("APP_STORE_SANDBOX") !== "0", onlineChecks: true }),
  ownerOf: (originalTransactionId) => subscriptionOwner(admin, originalTransactionId),
  apply: (userId, update) => applyEntitlement(admin, userId, update),
}));
