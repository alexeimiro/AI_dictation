// Paddle Billing, for Pro bought on the web (Murmur for Mac). Paddle is the merchant of record: it
// charges, handles sales tax and invoices; Murmur only learns, through signed webhooks, which
// account is subscribed until when. Entry points: paddle-checkout/index.ts, paddle-webhook/index.ts.
import type { Env } from "./config.ts";

export interface PaddleConfig {
  apiBase: string;
  apiKey?: string;
  webhookSecret?: string;
  prices: { monthly?: string; annual?: string };
}

export function paddleConfig(env: Env = Deno.env): PaddleConfig {
  const sandbox = env.get("PADDLE_ENV") === "sandbox";
  return {
    apiBase: sandbox ? "https://sandbox-api.paddle.com" : "https://api.paddle.com",
    apiKey: env.get("PADDLE_API_KEY") || undefined,
    webhookSecret: env.get("PADDLE_WEBHOOK_SECRET") || undefined,
    prices: { monthly: env.get("PADDLE_PRICE_MONTHLY") || undefined, annual: env.get("PADDLE_PRICE_ANNUAL") || undefined },
  };
}

/** A webhook's `Paddle-Signature: ts=…;h1=…` checked against the raw body (HMAC-SHA256 of `ts:body`). */
export async function verifySignature(
  header: string | null,
  rawBody: string,
  secret: string,
  now: number = Date.now(),
  toleranceSeconds = 300,
): Promise<boolean> {
  if (!header) return false;
  const parts = Object.fromEntries(header.split(";").map((part) => part.split("=", 2) as [string, string]));
  const ts = Number(parts.ts);
  const signatures = header.split(";").filter((part) => part.startsWith("h1=")).map((part) => part.slice(3));
  if (!Number.isFinite(ts) || signatures.length === 0) return false;
  if (Math.abs(now / 1000 - ts) > toleranceSeconds) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${parts.ts}:${rawBody}`)));
  const expected = Array.from(mac, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return signatures.some((signature) => constantTimeEqual(signature, expected));
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index++) difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  return difference === 0;
}

/** What a subscription event means for the account it was bought for. */
export interface SubscriptionChange {
  userId: string;
  subscriptionId: string;
  customerId: string | null;
  active: boolean;
  /** The end of the paid period (a day's grace added), or now for a subscription that ended. */
  endsAt: string;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** Statuses Paddle still bills: Pro stays on. */
const BILLED = new Set(["active", "trialing", "past_due"]);

/** Null for an event that isn't about a subscription, or one bought without a Murmur account. */
export function subscriptionChange(event: unknown, now: Date = new Date()): SubscriptionChange | null {
  if (typeof event !== "object" || event === null) return null;
  const { event_type: type, data } = event as { event_type?: unknown; data?: Record<string, unknown> };
  if (typeof type !== "string" || !type.startsWith("subscription.") || !data) return null;
  const custom = data.custom_data as Record<string, unknown> | null | undefined;
  const userId = typeof custom?.user_id === "string" && UUID_PATTERN.test(custom.user_id) ? custom.user_id : null;
  if (!userId || typeof data.id !== "string") return null;
  const status = typeof data.status === "string" ? data.status : "";
  const period = data.current_billing_period as { ends_at?: unknown } | null | undefined;
  const periodEnd = typeof period?.ends_at === "string" ? Date.parse(period.ends_at) : NaN;
  const active = BILLED.has(status) && Number.isFinite(periodEnd) && periodEnd > now.getTime();
  return {
    userId,
    subscriptionId: data.id,
    customerId: typeof data.customer_id === "string" ? data.customer_id : null,
    active,
    endsAt: active ? new Date(periodEnd + 86_400_000).toISOString() : now.toISOString(),
  };
}

/** A checkout for `plan`, tied to the account through custom_data; Paddle answers with its link. */
export async function createCheckout(
  config: PaddleConfig,
  plan: "monthly" | "annual",
  userId: string,
  fetcher: typeof fetch = fetch,
): Promise<string> {
  const priceId = config.prices[plan];
  if (!config.apiKey || !priceId) throw new Error("Paddle is not configured");
  const response = await fetcher(`${config.apiBase}/transactions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({ items: [{ price_id: priceId, quantity: 1 }], custom_data: { user_id: userId } }),
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error(`Paddle answered ${response.status}`);
  const body = await response.json() as { data?: { checkout?: { url?: string } } };
  const url = body.data?.checkout?.url;
  if (!url) throw new Error("Paddle gave no checkout link (set a default payment link in Paddle)");
  return url;
}
