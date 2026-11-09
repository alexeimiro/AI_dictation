import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  APP_STORE,
  appleVerifier,
  createNotificationHandler,
  createPurchaseHandler,
  decide,
  type EntitlementUpdate,
  type TransactionInfo,
  type Verifier,
} from "../_shared/app_store.ts";

const USER = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const OTHER = "11111111-2222-4333-8444-555555555555";
const NOW = Date.UTC(2026, 10, 10, 12);
const DAY = 86_400_000;

const monthly: TransactionInfo = {
  originalTransactionId: "2000000123456789",
  transactionId: "2000000123456799",
  productId: APP_STORE.products[0],
  bundleId: APP_STORE.bundleId,
  expiresDate: NOW + 30 * DAY,
  appAccountToken: USER,
  environment: "Sandbox",
};

Deno.test("an active subscription is Pro until it expires", () => {
  const decision = decide(monthly, USER, NOW);
  assert(decision.ok);
  assertEquals(decision.update, {
    plan: "pro", source: "app_store", expires_at: new Date(NOW + 30 * DAY).toISOString(),
    original_transaction_id: "2000000123456789", product_id: APP_STORE.products[0], environment: "Sandbox",
    revoked_at: null,
  });
});

Deno.test("expired, refunded or revoked is Basic; a billing grace period keeps Pro", () => {
  const expired = decide({ ...monthly, expiresDate: NOW - DAY }, USER, NOW);
  assert(expired.ok && expired.update.plan === "basic");
  const refunded = decide({ ...monthly, revocationDate: NOW - 60_000 }, USER, NOW);
  assert(refunded.ok && refunded.update.plan === "basic" && refunded.update.revoked_at !== null);
  const grace = decide({ ...monthly, expiresDate: NOW - DAY }, USER, NOW, NOW + 3 * DAY);
  assert(grace.ok && grace.update.plan === "pro");
  assertEquals(grace.ok && grace.update.expires_at, new Date(NOW + 3 * DAY).toISOString());
});

Deno.test("only Murmur Pro, and only for the account it was bought for", () => {
  assertEquals(decide({ ...monthly, productId: "com.other.app.pro" }, USER, NOW),
    { ok: false, status: 400, error: "unknown_product" });
  assertEquals(decide({ ...monthly, originalTransactionId: undefined }, USER, NOW),
    { ok: false, status: 400, error: "invalid_transaction" });
  assertEquals(decide(monthly, OTHER, NOW), { ok: false, status: 409, error: "other_account" });
  // A token in capitals is the same account.
  assert(decide({ ...monthly, appAccountToken: USER.toUpperCase() }, USER, NOW).ok);
  // Without a token (bought before Murmur set one), the subscription isn't tied to an account yet.
  assert(decide({ ...monthly, appAccountToken: undefined }, OTHER, NOW).ok);
});

/** Hands back `transaction` for any JWS, or throws like an unverifiable one. */
function fakeVerifier(transaction: TransactionInfo | Error, notification?: Record<string, unknown>): Verifier {
  return {
    transaction: (jws) => jws === "bad" || transaction instanceof Error
      ? Promise.reject(new Error("verification failed")) : Promise.resolve(transaction as TransactionInfo),
    renewal: () => Promise.resolve({ gracePeriodExpiresDate: undefined }),
    notification: (payload) => payload === "bad"
      ? Promise.reject(new Error("verification failed"))
      : Promise.resolve(notification ?? { notificationType: "TEST" }) as never,
  };
}

function purchaseHandler(options: {
  transaction?: TransactionInfo | Error; owner?: string | null; caller?: string | null;
  applied?: [string, EntitlementUpdate][];
} = {}) {
  return createPurchaseHandler({
    authenticate: () => Promise.resolve(
      options.caller === null ? null : { userId: options.caller ?? USER, isAnonymous: false }),
    verifier: fakeVerifier(options.transaction ?? monthly),
    ownerOf: () => Promise.resolve(options.owner ?? null),
    apply: (userId, update) => {
      options.applied?.push([userId, update]);
      return Promise.resolve({ plan: update.plan, on_trial: false, weekly_limit: null });
    },
    now: () => NOW,
  });
}

const post = (body: unknown) =>
  new Request("http://localhost/verify-purchase", { method: "POST", body: JSON.stringify(body) });

Deno.test("a verified purchase grants Pro and answers with the quota", async () => {
  const applied: [string, EntitlementUpdate][] = [];
  const response = await purchaseHandler({ applied })(post({ transaction: "jws" }));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { plan: "pro", on_trial: false, weekly_limit: null });
  assertEquals(applied.map(([user, update]) => [user, update.plan]), [[USER, "pro"]]);
});

Deno.test("the purchase endpoint refuses what it can't trust", async () => {
  assertEquals((await purchaseHandler({ caller: null })(post({ transaction: "jws" }))).status, 401);
  assertEquals((await purchaseHandler()(post({ nope: 1 }))).status, 400);
  const unverified = await purchaseHandler()(post({ transaction: "bad" }));
  assertEquals([unverified.status, (await unverified.json()).error], [400, "invalid_transaction"]);
  const taken = await purchaseHandler({ owner: OTHER })(post({ transaction: "jws" }));
  assertEquals([taken.status, (await taken.json()).error], [409, "other_account"]);
  const elsewhere = await purchaseHandler({ caller: OTHER })(post({ transaction: "jws" }));
  assertEquals(elsewhere.status, 409);
});

function notificationHandler(notification: Record<string, unknown>, transaction: TransactionInfo,
                             applied: [string, EntitlementUpdate][], owner: string | null = null) {
  return createNotificationHandler({
    verifier: fakeVerifier(transaction, notification),
    ownerOf: () => Promise.resolve(owner),
    apply: (userId, update) => {
      applied.push([userId, update]);
      return Promise.resolve({});
    },
    now: () => NOW,
  });
}

const notify = (signedPayload: string) =>
  new Request("http://localhost/app-store-notifications", { method: "POST", body: JSON.stringify({ signedPayload }) });

Deno.test("a renewal or a refund reaches the account the subscription was bought for", async () => {
  const applied: [string, EntitlementUpdate][] = [];
  const renewal = { notificationType: "DID_RENEW", data: { signedTransactionInfo: "t" } };
  assertEquals((await notificationHandler(renewal, monthly, applied)(notify("n"))).status, 200);
  const refund = { notificationType: "REFUND", data: { signedTransactionInfo: "t" } };
  await notificationHandler(refund, { ...monthly, revocationDate: NOW - 1000 }, applied)(notify("n"));
  assertEquals(applied.map(([user, update]) => [user, update.plan]), [[USER, "pro"], [USER, "basic"]]);
});

Deno.test("without a token the subscription's owner is looked up; unknown ones are acknowledged", async () => {
  const applied: [string, EntitlementUpdate][] = [];
  const expired = { notificationType: "EXPIRED", data: { signedTransactionInfo: "t" } };
  const anonymous = { ...monthly, appAccountToken: undefined, expiresDate: NOW - DAY };
  await notificationHandler(expired, anonymous, applied, OTHER)(notify("n"));
  assertEquals(applied.map(([user, update]) => [user, update.plan]), [[OTHER, "basic"]]);
  const unmatched = await notificationHandler(expired, anonymous, applied, null)(notify("n"));
  assertEquals(unmatched.status, 200);
  assertEquals(applied.length, 1);
});

Deno.test("a test notification is fine and an unverifiable one is refused", async () => {
  const applied: [string, EntitlementUpdate][] = [];
  assertEquals((await notificationHandler({ notificationType: "TEST" }, monthly, applied)(notify("n"))).status, 200);
  assertEquals((await notificationHandler({}, monthly, applied)(notify("bad"))).status, 400);
  assertEquals(applied.length, 0);
});

Deno.test("Apple's verifier rejects a forged transaction without going online", async () => {
  const verifier = appleVerifier({ allowSandbox: true, onlineChecks: false });
  const forged = [btoa(JSON.stringify({ alg: "ES256", x5c: ["AA=="] })), btoa(JSON.stringify(monthly)), "sig"].join(".");
  await assertRejects(() => verifier.transaction(forged));
  const sandboxOff = appleVerifier({ allowSandbox: false, onlineChecks: false });
  await assertRejects(() => sandboxOff.transaction(forged), Error, "sandbox");
});
