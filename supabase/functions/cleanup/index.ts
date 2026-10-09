// POST /functions/v1/cleanup
// Turns an on-device transcript into the text the user meant to type, using Claude.
// Body: CleanupRequest (see _shared/types.ts). Responses:
//   200 { text, status: "cleaned" | "raw", words, model, ttftMs, totalMs, remaining }
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited
//   502/503 cleanup_unavailable → the app inserts its locally formatted transcript instead.
import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import { DEFAULT_MODEL, runCleanup } from "../_shared/cleanup.ts";
import { adminClient, authenticate, background, corsHeaders, json } from "../_shared/http.ts";
import { countWords } from "../_shared/text.ts";
import { parseCleanupRequest } from "../_shared/types.ts";

const admin = adminClient();
// Created on first use: without the ANTHROPIC_API_KEY secret the constructor throws, which should
// surface as `cleanup_unavailable` (the app falls back to local formatting), not a boot failure.
let anthropic: Anthropic | null = null;
const model = Deno.env.get("CLEANUP_MODEL") ?? DEFAULT_MODEL;
const timeoutMs = Number(Deno.env.get("CLEANUP_TIMEOUT_MS") ?? 6000);

interface Preflight {
  allowed: boolean;
  reason: "rate_limited" | "limit_reached" | null;
  plan: string;
  remaining: number | null;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const caller = await authenticate(request, admin);
  if (!caller) return json({ error: "unauthorized" }, 401);

  const parsed = parseCleanupRequest(await request.json().catch(() => null));
  if (!parsed.ok) return json({ error: "bad_request", detail: parsed.error }, 400);
  const body = parsed.value;

  const { data: preflight, error: preflightError } = await admin
    .rpc("cleanup_preflight", { p_user: caller.userId })
    .single<Preflight>();
  if (preflightError || !preflight) {
    console.error("preflight failed", preflightError);
    return json({ error: "cleanup_unavailable" }, 503);
  }
  if (!preflight.allowed) {
    return json({ error: preflight.reason }, preflight.reason === "rate_limited" ? 429 : 402);
  }

  const transcriptWords = countWords(body.transcript, body.language);
  if (transcriptWords === 0) {
    return json({ text: "", status: "raw", words: 0, model: null, ttftMs: null, totalMs: 0 });
  }

  try {
    anthropic ??= new Anthropic();
    const outcome = await runCleanup(anthropic, body, { model, timeoutMs });
    const words = countWords(outcome.text, body.language);
    background(admin.rpc("record_usage", {
      p_user: caller.userId,
      p_dictation: body.dictationId,
      p_words: words,
    }));
    console.log(JSON.stringify({
      event: "cleanup",
      status: outcome.status,
      reason: outcome.reason,
      model: outcome.model,
      ttftMs: outcome.ttftMs,
      totalMs: outcome.totalMs,
      cacheReadTokens: outcome.cacheReadTokens,
      inWords: transcriptWords,
      outWords: words,
    }));
    return json({
      text: outcome.text,
      status: outcome.status,
      words,
      model: outcome.model,
      ttftMs: outcome.ttftMs,
      totalMs: outcome.totalMs,
      remaining: preflight.remaining === null ? null : Math.max(0, preflight.remaining - words),
    });
  } catch (error) {
    if (error instanceof Anthropic.RateLimitError) {
      console.error("anthropic rate limited", error.message);
    } else if (error instanceof Anthropic.APIConnectionTimeoutError) {
      console.error("anthropic timeout", error.message);
    } else if (error instanceof Anthropic.APIError) {
      console.error("anthropic error", error.status, error.message);
    } else {
      console.error("cleanup failed", error);
    }
    return json({ error: "cleanup_unavailable" }, 502);
  }
});
