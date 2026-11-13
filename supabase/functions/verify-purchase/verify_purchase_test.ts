import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  type AccountKind,
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
  const decision = decide(monthly, NOW);
  assert(decision.ok);
  assertEquals(decision.update, {
    plan: "pro", source: "app_store", expires_at: new Date(NOW + 30 * DAY).toISOString(),
    original_transaction_id: "2000000123456789", product_id: APP_STORE.products[0], environment: "Sandbox",
    revoked_at: null,
  });
});

Deno.test("expired, refunded or revoked is Basic; a billing grace period keeps Pro", () => {
  const expired = decide({ ...monthly, expiresDate: NOW - DAY }, NOW);
  assert(expired.ok && expired.update.plan === "basic");
  const refunded = decide({ ...monthly, revocationDate: NOW - 60_000 }, NOW);
  assert(refunded.ok && refunded.update.plan === "basic" && refunded.update.revoked_at !== null);
  const grace = decide({ ...monthly, expiresDate: NOW - DAY }, NOW, NOW + 3 * DAY);
  assert(grace.ok && grace.update.plan === "pro");
  assertEquals(grace.ok && grace.update.expires_at, new Date(NOW + 3 * DAY).toISOString());
});

Deno.test("only a Murmur Pro transaction decides anything", () => {
  assertEquals(decide({ ...monthly, productId: "com.other.app.pro" }, NOW),
    { ok: false, status: 400, error: "unknown_product" });
  assertEquals(decide({ ...monthly, originalTransactionId: undefined }, NOW),
    { ok: false, status: 400, error: "invalid_transaction" });
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

/**
 * `owner`: the account whose entitlement holds the subscription. `kinds`: what became of an
 * account (a member unless said otherwise). `steps` records the writes in order.
 */
function purchaseHandler(options: {
  transaction?: TransactionInfo | Error; owner?: string | null; caller?: string | null;
  kinds?: Record<string, AccountKind>; steps?: string[]; asked?: string[];
  applied?: [string, EntitlementUpdate][];
} = {}) {
  return createPurchaseHandler({
    authenticate: () => Promise.resolve(
      options.caller === null ? null : { userId: options.caller ?? USER, isAnonymous: false }),
    verifier: fakeVerifier(options.transaction ?? monthly),
    ownerOf: () => Promise.resolve(options.owner ?? null),
    accountKind: (userId) => {
      options.asked?.push(userId);
      return Promise.resolve(options.kinds?.[userId] ?? "member");
    },
    release: (userId, original) => {
      options.steps?.push(`release ${userId} ${original}`);
      return Promise.resolve();
    },
    apply: (userId, update) => {
      options.steps?.push(`apply ${userId} ${update.plan}`);
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
  const asked: string[] = [];
  const response = await purchaseHandler({ applied, asked })(post({ transaction: "jws" }));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { plan: "pro", on_trial: false, weekly_limit: null });
  assertEquals(applied.map(([user, update]) => [user, update.plan]), [[USER, "pro"]]);
  // A token in capitals is the same account, and one's own subscription needs no looking up.
  const capitals = await purchaseHandler({ transaction: { ...monthly, appAccountToken: USER.toUpperCase() }, asked })(
    post({ transaction: "jws" }),
  );
  assertEquals(capitals.status, 200);
  // Without a token (bought before Murmur set one) and with no holder, it isn't tied to anyone yet.
  const untied = await purchaseHandler({ caller: OTHER, transaction: { ...monthly, appAccountToken: undefined }, asked })(
    post({ transaction: "jws" }),
  );
  assertEquals(untied.status, 200);
  assertEquals(asked, []);
});

Deno.test("the purchase endpoint refuses what it can't trust", async () => {
  assertEquals((await purchaseHandler({ caller: null })(post({ transaction: "jws" }))).status, 401);
  assertEquals((await purchaseHandler()(post({ nope: 1 }))).status, 400);
  const unverified = await purchaseHandler()(post({ transaction: "bad" }));
  assertEquals([unverified.status, (await unverified.json()).error], [400, "invalid_transaction"]);
});

Deno.test("a subscription stays with another account that can still be signed in to", async () => {
  const steps: string[] = [];
  // Held by another member's entitlement.
  const taken = await purchaseHandler({ owner: OTHER, steps })(post({ transaction: "jws" }));
  assertEquals([taken.status, (await taken.json()).error], [409, "other_account"]);
  // Held by nobody yet, but bought for another member.
  const elsewhere = await purchaseHandler({ caller: OTHER, steps })(post({ transaction: "jws" }));
  assertEquals([elsewhere.status, (await elsewhere.json()).error], [409, "other_account"]);
  assertEquals(steps, []);
});

Deno.test("one tied to a guest's account moves to the account that shows its transaction", async () => {
  // Bought as a guest, who then signed in: the guest's account can't be reached again.
  const steps: string[] = [];
  const guestToken = { ...monthly, appAccountToken: OTHER };
  const moved = await purchaseHandler({ owner: OTHER, kinds: { [OTHER]: "guest" }, transaction: guestToken, steps })(
    post({ transaction: "jws" }),
  );
  assertEquals(moved.status, 200);
  assertEquals((await moved.json()).plan, "pro");
  // Released first: the table allows a subscription on one account only.
  assertEquals(steps, [`release ${OTHER} 2000000123456789`, `apply ${USER} pro`]);

  // The guest's purchase never reached the server: nothing to release.
  const unrecorded: string[] = [];
  const first = await purchaseHandler({ kinds: { [OTHER]: "guest" }, transaction: guestToken, steps: unrecorded })(
    post({ transaction: "jws" }),
  );
  assertEquals(first.status, 200);
  assertEquals(unrecorded, [`apply ${USER} pro`]);
});

Deno.test("one bought for an account that was deleted since goes to the caller", async () => {
  const steps: string[] = [];
  const asked: string[] = [];
  const response = await purchaseHandler({
    kinds: { [OTHER]: "gone" }, transaction: { ...monthly, appAccountToken: OTHER.toUpperCase() }, steps, asked,
  })(post({ transaction: "jws" }));
  assertEquals(response.status, 200);
  assertEquals(steps, [`apply ${USER} pro`]);
  assertEquals(asked, [OTHER]);
  // A token that isn't an account id ties it to nobody.
  const odd = await purchaseHandler({ transaction: { ...monthly, appAccountToken: "not-a-uuid" }, asked })(
    post({ transaction: "jws" }),
  );
  assertEquals(odd.status, 200);
  assertEquals(asked, [OTHER]);
});

function notificationHandler(notification: Record<string, unknown>, transaction: TransactionInfo,
                             applied: [string, EntitlementUpdate][], owner: string | null = null,
                             failure?: unknown) {
  return createNotificationHandler({
    verifier: fakeVerifier(transaction, notification),
    ownerOf: () => Promise.resolve(owner),
    apply: (userId, update) => {
      if (failure) return Promise.reject(failure);
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

Deno.test("once a subscription has moved, its renewals reach the account that holds it", async () => {
  const applied: [string, EntitlementUpdate][] = [];
  const renewal = { notificationType: "DID_RENEW", data: { signedTransactionInfo: "t" } };
  // Bought for USER (the token never changes), held by OTHER since.
  assertEquals((await notificationHandler(renewal, monthly, applied, OTHER)(notify("n"))).status, 200);
  assertEquals(applied.map(([user, update]) => [user, update.plan]), [[OTHER, "pro"]]);
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

Deno.test("a notification for a deleted account is acknowledged; a database failure is retried", async () => {
  const applied: [string, EntitlementUpdate][] = [];
  const renewal = { notificationType: "DID_RENEW", data: { signedTransactionInfo: "t" } };
  // Postgres refuses the row: the account it was bought for is gone, and retrying can't help.
  const gone = await notificationHandler(renewal, monthly, applied, null, { code: "23503", message: "fk" })(notify("n"));
  assertEquals(gone.status, 200);
  // Anything else is Apple's to send again.
  const outage = await notificationHandler(renewal, monthly, applied, null, new Error("connection reset"))(notify("n"));
  assertEquals(outage.status, 503);
  assertEquals(applied.length, 0);
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
