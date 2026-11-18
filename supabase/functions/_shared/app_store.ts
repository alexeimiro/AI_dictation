// App Store subscriptions: StoreKit 2's signed transactions and Apple's server notifications are
// verified against Apple's pinned root certificates (apple_jws.ts), and each one decides the
// account's entitlement: Pro until the subscription expires, Basic once it's expired, refunded or
// revoked. The handlers take their dependencies (`PurchaseDeps`, `NotificationDeps`) so the tests
// drive them offline.
import { appleJwsVerifier, VerificationError } from "./apple_jws.ts";
import { APPLE_ROOT_CERTIFICATES } from "./apple_roots.ts";
import { type Caller, corsHeaders, json } from "./http.ts";

export const APP_STORE = {
  bundleId: "com.antonmironenko.murmur",
  /** The app's Apple ID in App Store Connect ("Murmur: Voice Keyboard"). */
  appAppleId: 6829429992,
  /** Murmur Pro, monthly and annual, in one subscription group. */
  products: ["com.antonmironenko.murmur.pro.monthly", "com.antonmironenko.murmur.pro.annual"] as readonly string[],
};

/** What a verified transaction carries that matters here. */
export interface TransactionInfo {
  originalTransactionId?: string;
  transactionId?: string;
  productId?: string;
  bundleId?: string;
  /** Milliseconds since 1970. */
  expiresDate?: number;
  revocationDate?: number;
  /** The Murmur account the app bought it for (`Product.PurchaseOption.appAccountToken`). */
  appAccountToken?: string;
  environment?: string;
}

/** The `entitlements` columns a transaction sets. */
export interface EntitlementUpdate {
  plan: "pro" | "basic";
  source: "app_store";
  expires_at: string | null;
  original_transaction_id: string;
  product_id: string;
  environment: string | null;
  revoked_at: string | null;
}

export type Decision =
  | { ok: true; update: EntitlementUpdate }
  | { ok: false; status: number; error: string };

/**
 * What `transaction` means for an entitlement at `now` (ms). `graceUntil`: the end of a billing
 * grace period from the renewal info, during which Pro continues. Whose entitlement it is, the
 * handlers decide.
 */
export function decide(transaction: TransactionInfo, now: number, graceUntil?: number): Decision {
  const productId = transaction.productId;
  if (!productId || !APP_STORE.products.includes(productId)) return { ok: false, status: 400, error: "unknown_product" };
  const original = transaction.originalTransactionId;
  if (!original) return { ok: false, status: 400, error: "invalid_transaction" };
  const revoked = transaction.revocationDate ?? null;
  const until = Math.max(transaction.expiresDate ?? 0, graceUntil ?? 0) || null;
  const active = revoked === null && until !== null && until > now;
  return {
    ok: true,
    update: {
      plan: active ? "pro" : "basic",
      source: "app_store",
      expires_at: until === null ? null : new Date(until).toISOString(),
      original_transaction_id: original,
      product_id: productId,
      environment: transaction.environment ?? null,
      revoked_at: revoked === null ? null : new Date(revoked).toISOString(),
    },
  };
}

// MARK: - Verification

/** Apple's renewal info (its JWSRenewalInfoDecodedPayload): the part used here. */
export interface RenewalInfo {
  /** Milliseconds since 1970: the end of a billing grace period. */
  gracePeriodExpiresDate?: number;
  environment?: string;
}

/** Whose app a notification is about: in its `data`, or in the `summary` of a bulk one. */
interface NotificationApp {
  bundleId?: unknown;
  appAppleId?: unknown;
  environment?: unknown;
}

/** An App Store Server Notification V2 (Apple's ResponseBodyV2DecodedPayload): the parts used here. */
export interface NotificationPayload {
  notificationType?: string;
  subtype?: string;
  notificationUUID?: string;
  data?: NotificationApp & { signedTransactionInfo?: string; signedRenewalInfo?: string };
  summary?: NotificationApp;
  /** RESCIND_CONSENT's app. */
  appData?: NotificationApp;
  externalPurchaseToken?: { bundleId?: unknown; appAppleId?: unknown; externalPurchaseId?: unknown };
}

export interface Verifier {
  transaction(jws: string): Promise<TransactionInfo>;
  renewal(jws: string): Promise<RenewalInfo>;
  notification(signedPayload: string): Promise<NotificationPayload>;
}

/**
 * Apple's signed data for this app, Production and, unless `allowSandbox` is false, Sandbox
 * (TestFlight and development purchases, which the same backend serves). The signature and the
 * chain to Apple's roots are apple_jws.ts's; then what Apple's SignedDataVerifier checks after
 * them: a transaction's bundle ID and environment, a renewal's environment, and a notification's
 * bundle ID, environment and, in Production, the app's Apple ID. There's no online revocation
 * check: Apple's can't run on the edge runtime, and it never did. `roots` and `now` are for tests.
 */
export function appleVerifier(options: {
  allowSandbox: boolean;
  roots?: readonly string[];
  now?: () => number;
}): Verifier {
  const verify = appleJwsVerifier(options.roots ?? APPLE_ROOT_CERTIFICATES, options.now);
  const environment = (value: unknown): "Production" | "Sandbox" => {
    if (value === "Production") return value;
    if (value !== "Sandbox") throw new VerificationError("environment");
    if (!options.allowSandbox) throw new VerificationError("sandbox purchases are not accepted");
    return value;
  };
  return {
    async transaction(jws) {
      const payload = await verify(jws);
      const signedFor = environment(payload.environment);
      if (payload.bundleId !== APP_STORE.bundleId) throw new VerificationError("bundle_id");
      return {
        originalTransactionId: text(payload.originalTransactionId),
        transactionId: text(payload.transactionId),
        productId: text(payload.productId),
        bundleId: text(payload.bundleId),
        expiresDate: number(payload.expiresDate),
        revocationDate: number(payload.revocationDate),
        appAccountToken: text(payload.appAccountToken),
        environment: signedFor,
      };
    },
    async renewal(jws) {
      const payload = await verify(jws);
      return {
        environment: environment(payload.environment),
        gracePeriodExpiresDate: number(payload.gracePeriodExpiresDate),
      };
    },
    async notification(signedPayload) {
      const payload = await verify(signedPayload);
      // Where Apple's library looks, in its order; an external purchase token's environment is in its ID.
      const token = record(payload.externalPurchaseToken);
      const app = record(payload.data) ?? record(payload.summary) ??
        (token && {
          ...token,
          environment: String(token.externalPurchaseId ?? "").startsWith("SANDBOX") ? "Sandbox" : "Production",
        }) ??
        record(payload.appData);
      const signedFor = environment(app?.environment);
      if (app?.bundleId !== APP_STORE.bundleId) throw new VerificationError("bundle_id");
      if (signedFor === "Production" && app?.appAppleId !== APP_STORE.appAppleId) {
        throw new VerificationError("app_apple_id");
      }
      return payload as NotificationPayload;
    },
  };
}

function text(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function number(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

/** The request's JSON body, or null when it isn't JSON or is longer than `limit` bytes (not read further). */
async function readJson(request: Request, limit: number): Promise<unknown> {
  if (Number(request.headers.get("content-length") ?? 0) > limit || !request.body) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let at = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, at);
      at += chunk.length;
    }
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

// MARK: - The app's purchases

/**
 * What became of a Murmur account: a member's can be signed in to again; a guest's can't once
 * it's signed out or its app is deleted; a deleted one is gone.
 */
export type AccountKind = "member" | "guest" | "gone";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** The account a transaction was bought for, as a lowercase UUID; nothing else is an account. */
function boughtFor(transaction: TransactionInfo): string | null {
  const token = transaction.appAccountToken?.toLowerCase();
  return token && UUID_PATTERN.test(token) ? token : null;
}

export interface PurchaseDeps {
  authenticate(request: Request): Promise<Caller | null>;
  verifier: Verifier;
  /** The account whose entitlement holds the subscription, if any. */
  ownerOf(originalTransactionId: string): Promise<string | null>;
  /** Whether `userId` is an account someone can still sign in to. */
  accountKind(userId: string): Promise<AccountKind>;
  /** Takes the subscription off `userId`'s entitlement, which is Basic again. */
  release(userId: string, originalTransactionId: string): Promise<void>;
  /** Writes the entitlement and returns `quota_status` for the account. */
  apply(userId: string, update: EntitlementUpdate): Promise<Record<string, unknown>>;
  now?: () => number;
}

/**
 * POST { transaction: JWS } from the app after a purchase, a renewal or Restore. 200 with the
 * account's quota; 400 for something that isn't a Murmur Pro transaction; 409 other_account when
 * the subscription belongs to another Murmur account that can still be signed in to.
 *
 * A subscription is tied to one account: the one holding it, else the one it was bought for. One
 * tied to a guest's account, or to a deleted one, would be lost with it (nobody can sign in there
 * again), so it moves to the account that now shows its transaction, which only the Apple
 * Account that pays for it has.
 */
export function createPurchaseHandler(deps: PurchaseDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const caller = await deps.authenticate(request);
    if (!caller) return json({ error: "unauthorized" }, 401);
    const body = await readJson(request, 64 * 1024) as { transaction?: unknown } | null;
    if (typeof body?.transaction !== "string" || body.transaction.length > 20_000) {
      return json({ error: "bad_request" }, 400);
    }
    let transaction: TransactionInfo;
    try {
      transaction = await deps.verifier.transaction(body.transaction);
    } catch (error) {
      console.error(JSON.stringify({ event: "purchase_unverified", reason: String(error) }));
      return json({ error: "invalid_transaction" }, 400);
    }
    const decision = decide(transaction, (deps.now ?? Date.now)());
    if (!decision.ok) return json({ error: decision.error }, decision.status);
    const original = decision.update.original_transaction_id;
    try {
      const owner = (await deps.ownerOf(original))?.toLowerCase() ?? null;
      const tiedTo = owner ?? boughtFor(transaction);
      if (tiedTo && tiedTo !== caller.userId.toLowerCase()) {
        const kind = await deps.accountKind(tiedTo);
        if (kind === "member") return json({ error: "other_account" }, 409);
        // Before it is written for the caller: one subscription, one account.
        if (owner) await deps.release(owner, original);
        console.log(JSON.stringify({ event: "purchase_moved", from: kind }));
      }
      const quota = await deps.apply(caller.userId, decision.update);
      console.log(JSON.stringify({
        event: "purchase_applied", plan: decision.update.plan, product: decision.update.product_id,
        environment: decision.update.environment,
      }));
      return json(quota);
    } catch (error) {
      console.error("purchase apply failed", error);
      return json({ error: "unavailable" }, 503);
    }
  };
}

// MARK: - Apple's server notifications

export interface NotificationDeps {
  verifier: Verifier;
  ownerOf(originalTransactionId: string): Promise<string | null>;
  /** Rejects with Postgres's foreign-key error (23503) when the account no longer exists. */
  apply(userId: string, update: EntitlementUpdate): Promise<unknown>;
  now?: () => number;
}

/** Postgres refused a row for an account that isn't there: it was deleted. */
function isMissingAccount(error: unknown): boolean {
  return typeof error === "object" && error !== null && (error as { code?: unknown }).code === "23503";
}

/**
 * POST { signedPayload } from App Store Server Notifications V2: renewals, expiries, refunds and
 * revocations reach the account even when the app isn't opened. That is the account holding the
 * subscription (it may have moved, see `createPurchaseHandler`); until one does, the account it
 * was bought for. Answers 200 once handled (or when there's nothing to do), so Apple doesn't
 * retry; 400 when it can't be verified.
 */
export function createNotificationHandler(deps: NotificationDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    // Anyone can post here: Apple's own notification is about 20 KB.
    const body = await readJson(request, 256 * 1024) as { signedPayload?: unknown } | null;
    if (typeof body?.signedPayload !== "string") return json({ error: "bad_request" }, 400);
    let notification: NotificationPayload;
    let transaction: TransactionInfo | null = null;
    let graceUntil: number | undefined;
    try {
      notification = await deps.verifier.notification(body.signedPayload);
      const signedTransaction = notification.data?.signedTransactionInfo;
      if (signedTransaction) transaction = await deps.verifier.transaction(signedTransaction);
      const signedRenewal = notification.data?.signedRenewalInfo;
      if (signedRenewal) graceUntil = (await deps.verifier.renewal(signedRenewal)).gracePeriodExpiresDate;
    } catch (error) {
      console.error(JSON.stringify({ event: "notification_unverified", reason: String(error) }));
      return json({ error: "invalid_notification" }, 400);
    }
    const type = notification.notificationType;
    if (!transaction?.originalTransactionId) {
      console.log(JSON.stringify({ event: "notification_ignored", type, subtype: notification.subtype ?? null }));
      return json({ ok: true });
    }
    try {
      const owner = await deps.ownerOf(transaction.originalTransactionId) ?? boughtFor(transaction);
      if (!owner) {
        console.log(JSON.stringify({ event: "notification_unmatched", type }));
        return json({ ok: true });
      }
      const decision = decide(transaction, (deps.now ?? Date.now)(), graceUntil);
      if (!decision.ok) {
        console.log(JSON.stringify({ event: "notification_skipped", type, reason: decision.error }));
        return json({ ok: true });
      }
      try {
        await deps.apply(owner, decision.update);
      } catch (error) {
        if (!isMissingAccount(error)) throw error;
        // Bought for an account that was deleted since: nothing to update, and no use retrying.
        console.log(JSON.stringify({ event: "notification_unmatched", type, reason: "account_gone" }));
        return json({ ok: true });
      }
      console.log(JSON.stringify({ event: "notification_applied", type, subtype: notification.subtype ?? null,
        plan: decision.update.plan }));
      return json({ ok: true });
    } catch (error) {
      // Apple retries a failed delivery, so a database outage isn't lost.
      console.error("notification apply failed", error);
      return json({ error: "unavailable" }, 503);
    }
  };
}
