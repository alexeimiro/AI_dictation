// POST /functions/v1/paddle-webhook — Paddle's notifications (the destination set in Paddle,
// subscription.* events). Each signed event turns its account Pro until the paid period ends, or
// back to Basic once it's over. Deployed with --no-verify-jwt: Paddle signs, it has no JWT.
// Env: PADDLE_WEBHOOK_SECRET (the destination's secret key).
import { adminClient, json } from "../_shared/http.ts";
import { paddleConfig, subscriptionChange, verifySignature } from "../_shared/paddle.ts";

const admin = adminClient();
const config = paddleConfig();

Deno.serve(async (request) => {
  if (request.method !== "POST") return json({ error: "bad_request" }, 400);
  if (!config.webhookSecret) return json({ error: "paddle_unavailable" }, 503);
  const raw = await request.text();
  if (!await verifySignature(request.headers.get("Paddle-Signature"), raw, config.webhookSecret)) {
    return json({ error: "bad_signature" }, 401);
  }
  let event: unknown;
  try {
    event = JSON.parse(raw);
  } catch {
    return json({ error: "bad_request" }, 400);
  }
  const change = subscriptionChange(event);
  // Other events (transactions, customers) are acknowledged and ignored.
  if (!change) return json({ ok: true, ignored: true });
  const { error } = await admin.rpc("apply_paddle_subscription", {
    p_user: change.userId,
    p_subscription: change.subscriptionId,
    p_customer: change.customerId,
    p_active: change.active,
    p_ends_at: change.endsAt,
  });
  // A 5xx makes Paddle retry the event later.
  if (error) return json({ error: "apply_failed" }, 500);
  return json({ ok: true, active: change.active });
});
