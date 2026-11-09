// POST /functions/v1/app-store-notifications (no auth: Apple signs the payload)
// App Store Server Notifications V2, set as the app's Production and Sandbox URL in App Store
// Connect. Renewals, expiries, billing grace periods, refunds and revocations update the account
// the subscription was bought for (its appAccountToken, else its original transaction). The
// handler is _shared/app_store.ts.
//   200 { ok: true } once handled or when there's nothing to do · 400 invalid_notification
//   503 unavailable: the database failed, and Apple retries
// Env: APP_STORE_SANDBOX=0 refuses Sandbox notifications.
import { appleVerifier, createNotificationHandler } from "../_shared/app_store.ts";
import { applyEntitlement, subscriptionOwner } from "../_shared/entitlements.ts";
import { adminClient } from "../_shared/http.ts";

const admin = adminClient();

Deno.serve(createNotificationHandler({
  verifier: appleVerifier({ allowSandbox: Deno.env.get("APP_STORE_SANDBOX") !== "0", onlineChecks: true }),
  ownerOf: (originalTransactionId) => subscriptionOwner(admin, originalTransactionId),
  apply: (userId, update) => applyEntitlement(admin, userId, update),
}));
