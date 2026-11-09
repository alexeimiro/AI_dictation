// App Store subscriptions: StoreKit 2's signed transactions and Apple's server notifications are
// verified with Apple's own library against the pinned root certificates, and each one decides
// the account's entitlement: Pro until the subscription expires, Basic once it's expired, refunded
// or revoked. The handlers take their dependencies (`PurchaseDeps`, `NotificationDeps`) so the
// tests drive them offline.
import { Buffer } from "node:buffer";
import {
  Environment,
  type JWSRenewalInfoDecodedPayload,
  type JWSTransactionDecodedPayload,
  type ResponseBodyV2DecodedPayload,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@3.1.0";
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
 * What `transaction` means for `userId`'s entitlement at `now` (ms). `graceUntil`: the end of a
 * billing grace period from the renewal info, during which Pro continues.
 */
export function decide(transaction: TransactionInfo, userId: string, now: number, graceUntil?: number): Decision {
  const productId = transaction.productId;
  if (!productId || !APP_STORE.products.includes(productId)) return { ok: false, status: 400, error: "unknown_product" };
  const original = transaction.originalTransactionId;
  if (!original) return { ok: false, status: 400, error: "invalid_transaction" };
  const token = transaction.appAccountToken?.toLowerCase();
  if (token && token !== userId.toLowerCase()) return { ok: false, status: 409, error: "other_account" };
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

export interface Verifier {
  transaction(jws: string): Promise<TransactionInfo>;
  renewal(jws: string): Promise<JWSRenewalInfoDecodedPayload>;
  notification(signedPayload: string): Promise<ResponseBodyV2DecodedPayload>;
}

/**
 * Apple's verifiers for Production and, unless `allowSandbox` is false, Sandbox (TestFlight and
 * development purchases, which the same backend serves). The JWS names its environment; the
 * matching verifier then checks the signature, the chain to Apple's roots (online, with
 * `onlineChecks`), the bundle ID and that environment.
 */
export function appleVerifier(options: { allowSandbox: boolean; onlineChecks: boolean }): Verifier {
  const roots = APPLE_ROOT_CERTIFICATES.map((certificate) => Buffer.from(certificate, "base64"));
  const production = new SignedDataVerifier(
    roots, options.onlineChecks, Environment.PRODUCTION, APP_STORE.bundleId, APP_STORE.appAppleId);
  const sandbox = new SignedDataVerifier(roots, options.onlineChecks, Environment.SANDBOX, APP_STORE.bundleId);
  const pick = (environment: unknown) => {
    if (environment !== "Sandbox") return production;
    if (!options.allowSandbox) throw new Error("sandbox purchases are not accepted");
    return sandbox;
  };
  return {
    async transaction(jws) {
      const payload: JWSTransactionDecodedPayload = await pick(peek(jws)?.environment).verifyAndDecodeTransaction(jws);
      return {
        originalTransactionId: payload.originalTransactionId,
        transactionId: payload.transactionId,
        productId: payload.productId,
        bundleId: payload.bundleId,
        expiresDate: payload.expiresDate,
        revocationDate: payload.revocationDate,
        appAccountToken: payload.appAccountToken,
        environment: payload.environment,
      };
    },
    renewal: (jws) => pick(peek(jws)?.environment).verifyAndDecodeRenewalInfo(jws),
    notification: (signedPayload) => {
      const data = peek(signedPayload)?.data as Record<string, unknown> | undefined;
      return pick(data?.environment).verifyAndDecodeNotification(signedPayload);
    },
  };
}

/** A JWS payload read without verifying it, only to pick the verifier that then checks it. */
function peek(jws: string): Record<string, unknown> | null {
  const part = jws.split(".")[1];
  if (!part) return null;
  try {
    const base64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
    return JSON.parse(atob(base64)) as Record<string, unknown>;
  } catch {
    return null;
  }
}

// MARK: - The app's purchases

export interface PurchaseDeps {
  authenticate(request: Request): Promise<Caller | null>;
  verifier: Verifier;
  /** The account the subscription already belongs to, if any. */
  ownerOf(originalTransactionId: string): Promise<string | null>;
  /** Writes the entitlement and returns `quota_status` for the account. */
  apply(userId: string, update: EntitlementUpdate): Promise<Record<string, unknown>>;
  now?: () => number;
}

/**
 * POST { transaction: JWS } from the app after a purchase, a renewal or Restore. 200 with the
 * account's quota; 400 for something that isn't a Murmur Pro transaction; 409 other_account when
 * the subscription belongs to another Murmur account.
 */
export function createPurchaseHandler(deps: PurchaseDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const caller = await deps.authenticate(request);
    if (!caller) return json({ error: "unauthorized" }, 401);
    const body = await request.json().catch(() => null) as { transaction?: unknown } | null;
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
    const decision = decide(transaction, caller.userId, (deps.now ?? Date.now)());
    if (!decision.ok) return json({ error: decision.error }, decision.status);
    try {
      const owner = await deps.ownerOf(decision.update.original_transaction_id);
      if (owner && owner !== caller.userId) return json({ error: "other_account" }, 409);
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
  apply(userId: string, update: EntitlementUpdate): Promise<unknown>;
  now?: () => number;
}

/**
 * POST { signedPayload } from App Store Server Notifications V2: renewals, expiries, refunds and
 * revocations reach the account even when the app isn't opened. Answers 200 once handled (or
 * when there's nothing to do), so Apple doesn't retry; 400 when it can't be verified.
 */
export function createNotificationHandler(deps: NotificationDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const body = await request.json().catch(() => null) as { signedPayload?: unknown } | null;
    if (typeof body?.signedPayload !== "string") return json({ error: "bad_request" }, 400);
    let notification: ResponseBodyV2DecodedPayload;
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
      const owner = transaction.appAccountToken ?? await deps.ownerOf(transaction.originalTransactionId);
      if (!owner) {
        console.log(JSON.stringify({ event: "notification_unmatched", type }));
        return json({ ok: true });
      }
      const decision = decide(transaction, owner, (deps.now ?? Date.now)(), graceUntil);
      if (!decision.ok) {
        console.log(JSON.stringify({ event: "notification_skipped", type, reason: decision.error }));
        return json({ ok: true });
      }
      await deps.apply(owner, decision.update);
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
