// POST /functions/v1/paddle-checkout — a Paddle checkout for the signed-in account (Murmur for Mac).
// Body: { plan: "monthly" | "annual" }. 200 { url } · 400 · 401 · 503 paddle_unavailable.
// Env: PADDLE_API_KEY, PADDLE_PRICE_MONTHLY, PADDLE_PRICE_ANNUAL, PADDLE_ENV=sandbox for tests.
import { adminClient, authenticate, json } from "../_shared/http.ts";
import { createCheckout, paddleConfig } from "../_shared/paddle.ts";

const admin = adminClient();
const config = paddleConfig();

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok");
  if (request.method !== "POST") return json({ error: "bad_request" }, 400);
  const caller = await authenticate(request, admin).catch(() => null);
  if (!caller || caller.isAnonymous) return json({ error: "unauthorized" }, 401);
  const body = await request.json().catch(() => null) as { plan?: unknown } | null;
  const plan = body?.plan === "monthly" || body?.plan === "annual" ? body.plan : null;
  if (!plan) return json({ error: "bad_request", message: "plan must be monthly or annual" }, 400);
  try {
    return json({ url: await createCheckout(config, plan, caller.userId) });
  } catch (error) {
    console.error("paddle checkout failed", (error as Error).message);
    return json({ error: "paddle_unavailable" }, 503);
  }
});
