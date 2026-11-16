import { assertEquals } from "jsr:@std/assert@1";
import { createCheckout, subscriptionChange, verifySignature } from "./paddle.ts";

async function sign(secret: string, ts: number, body: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}:${body}`)));
  return Array.from(mac, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

Deno.test("a signature over ts:body is accepted, a tampered or stale one refused", async () => {
  const body = '{"event_type":"subscription.created"}';
  const ts = 1_795_000_000;
  const h1 = await sign("pdl_secret", ts, body);
  assertEquals(await verifySignature(`ts=${ts};h1=${h1}`, body, "pdl_secret", ts * 1000), true);
  assertEquals(await verifySignature(`ts=${ts};h1=${h1}`, body + " ", "pdl_secret", ts * 1000), false);
  assertEquals(await verifySignature(`ts=${ts};h1=${h1}`, body, "other", ts * 1000), false);
  assertEquals(await verifySignature(`ts=${ts};h1=${h1}`, body, "pdl_secret", (ts + 600) * 1000), false);
  assertEquals(await verifySignature(null, body, "pdl_secret"), false);
});

const USER = "6f1b8c2e-1a2b-4c3d-8e9f-0a1b2c3d4e5f";
const now = new Date("2026-11-20T00:00:00Z");
function event(status: string, endsAt = "2026-12-20T00:00:00Z", type = "subscription.updated", user: string | null = USER) {
  return { event_type: type, data: { id: "sub_1", customer_id: "ctm_1", status, custom_data: user ? { user_id: user } : null,
    current_billing_period: { starts_at: "2026-11-20T00:00:00Z", ends_at: endsAt } } };
}

Deno.test("billed subscriptions are Pro until the period ends, with a day's grace", () => {
  for (const status of ["active", "trialing", "past_due"]) {
    const change = subscriptionChange(event(status), now);
    assertEquals([change?.active, change?.endsAt, change?.userId], [true, "2026-12-21T00:00:00.000Z", USER]);
  }
});

Deno.test("canceled, paused or lapsed subscriptions are not", () => {
  assertEquals(subscriptionChange(event("canceled", "2026-12-20T00:00:00Z", "subscription.canceled"), now)?.active, false);
  assertEquals(subscriptionChange(event("paused"), now)?.active, false);
  assertEquals(subscriptionChange(event("active", "2026-11-19T00:00:00Z"), now)?.active, false);
});

Deno.test("events without an account or not about subscriptions are skipped", () => {
  assertEquals(subscriptionChange(event("active", undefined, "subscription.created", null), now), null);
  assertEquals(subscriptionChange(event("active", undefined, "subscription.created", "not-a-uuid"), now), null);
  assertEquals(subscriptionChange({ event_type: "transaction.completed", data: {} }, now), null);
});

Deno.test("a checkout carries the price and the account", async () => {
  let sent: { url: string; body: string } | null = null;
  const fetcher = ((url: string, init: RequestInit) => {
    sent = { url, body: String(init.body) };
    return Promise.resolve(new Response(JSON.stringify({ data: { checkout: { url: "https://simplymurmur.com/pay/?_ptxn=txn_1" } } })));
  }) as unknown as typeof fetch;
  const config = { apiBase: "https://sandbox-api.paddle.com", apiKey: "k", prices: { annual: "pri_year" } };
  assertEquals(await createCheckout(config, "annual", USER, fetcher), "https://simplymurmur.com/pay/?_ptxn=txn_1");
  assertEquals(sent!.url, "https://sandbox-api.paddle.com/transactions");
  assertEquals(JSON.parse(sent!.body), { items: [{ price_id: "pri_year", quantity: 1 }], custom_data: { user_id: USER } });
});
