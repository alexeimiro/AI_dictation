// POST /functions/v1/cleanup
// Turns an on-device transcript into the text the user meant to type, using Claude.
// Body: CleanupRequest (see _shared/types.ts). Responses:
//   200 { text, status: "cleaned" | "raw", words, model, ttftMs, totalMs, remaining }
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited
//   502/503 cleanup_unavailable → the app inserts its locally formatted transcript instead.
// Env: ANTHROPIC_API_KEY (required), CLEANUP_MODEL, CLEANUP_TIMEOUT_MS (response headers, default
// 5000), CLEANUP_DEADLINE_MS (whole call incl. streamed body, default 9000), CLEANUP_DISABLED=1.
import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import { DEFAULT_MODEL, describeCleanupError, runCleanup } from "../_shared/cleanup.ts";
import { adminClient, authenticate, background, corsHeaders, json } from "../_shared/http.ts";
import { countWords } from "../_shared/text.ts";
import { LIMITS, parseCleanupRequest } from "../_shared/types.ts";

const admin = adminClient();
// Created on first use: without the ANTHROPIC_API_KEY secret the constructor throws, which should
// surface as `cleanup_unavailable` (the app falls back to local formatting), not a boot failure.
let anthropic: Anthropic | null = null;
const model = Deno.env.get("CLEANUP_MODEL") ?? DEFAULT_MODEL;
/** Time allowed for Anthropic's response headers; the SDK retries a timeout once. */
const timeoutMs = envNumber("CLEANUP_TIMEOUT_MS", 5000);
/** Hard bound on the whole call including the streamed body; must stay below the app's request timeout. */
const deadlineMs = envNumber("CLEANUP_DEADLINE_MS", 9000);
/** Kill switch: answers 503 before any database or model call. */
const disabled = Deno.env.get("CLEANUP_DISABLED") === "1";
/** Anonymous (trial) callers get a tighter per-minute limit; signed-in users keep the SQL default (40). */
const ANONYMOUS_PER_MINUTE = 10;

function envNumber(name: string, fallback: number): number {
  const value = Number(Deno.env.get(name));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

interface Preflight {
  allowed: boolean;
  reason: "rate_limited" | "limit_reached" | null;
  plan: string;
  remaining: number | null;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (disabled) return json({ error: "cleanup_unavailable" }, 503);

  const caller = await authenticate(request, admin);
  if (!caller) return json({ error: "unauthorized" }, 401);

  const parsed = parseCleanupRequest(await request.json().catch(() => null));
  if (!parsed.ok) return json({ error: "bad_request", detail: parsed.error }, 400);
  const body = parsed.value;
  if (caller.isAnonymous && body.transcript.length > LIMITS.anonymousTranscriptChars) {
    return json({ error: "bad_request", detail: "transcript too long" }, 400);
  }

  const { data: preflight, error: preflightError } = await admin
    .rpc(
      "cleanup_preflight",
      caller.isAnonymous
        ? { p_user: caller.userId, p_per_minute: ANONYMOUS_PER_MINUTE }
        : { p_user: caller.userId },
    )
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
    return json({
      text: "",
      status: "raw",
      words: 0,
      model: null,
      ttftMs: null,
      totalMs: 0,
      remaining: preflight.remaining,
    });
  }

  try {
    anthropic ??= new Anthropic();
    const outcome = await runCleanup(anthropic, body, { model, timeoutMs, deadlineMs });
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
      language: outcome.language,
      languageTag: body.language ?? null,
      style: body.style ?? "casual",
      isAnonymous: caller.isAnonymous,
      stopReason: outcome.stopReason,
      ttftMs: outcome.ttftMs,
      totalMs: outcome.totalMs,
      inChars: body.transcript.length,
      inWords: transcriptWords,
      outWords: words,
      inputTokens: outcome.usage.input,
      outputTokens: outcome.usage.output,
      cacheReadTokens: outcome.usage.cacheRead,
      cacheCreationTokens: outcome.usage.cacheCreation,
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
    const label = describeCleanupError(error);
    if (label === "cleanup failed") console.error(label, error);
    else console.error(label, error instanceof Error ? error.message : String(error));
    return json({ error: "cleanup_unavailable" }, 502);
  }
});
