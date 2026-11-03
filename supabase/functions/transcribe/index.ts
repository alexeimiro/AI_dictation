// POST /functions/v1/transcribe
// Turns a dictation's audio into text with OpenAI. The audio is passed through, never stored.
// Body: { dictationId?, audio (base64), format: "m4a" | "wav", language? (BCP-47), keywords? }.
// Responses:
//   200 { text, languages, model, totalMs }
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited
//   502/503 transcription_unavailable → the app falls back to on-device recognition if it can.
// Env: OPENAI_API_KEY (required), TRANSCRIBE_MODEL (default gpt-transcribe),
// TRANSCRIBE_DEADLINE_MS (whole OpenAI call, default 20000), TRANSCRIBE_DISABLED=1.
import { adminClient, authenticate, corsHeaders, json } from "../_shared/http.ts";
import {
  DEFAULT_TRANSCRIBE_MODEL,
  OpenAIError,
  parseTranscribeRequest,
  transcribeWithOpenAI,
} from "../_shared/transcribe.ts";

const admin = adminClient();
const model = Deno.env.get("TRANSCRIBE_MODEL") ?? DEFAULT_TRANSCRIBE_MODEL;
/** Must stay below the app's request timeout (25 s). */
const deadlineMs = envNumber("TRANSCRIBE_DEADLINE_MS", 20000);
/** Kill switch: answers 503 before any database or model call. */
const disabled = Deno.env.get("TRANSCRIBE_DISABLED") === "1";
const PER_MINUTE = 40;
const ANONYMOUS_PER_MINUTE = 10;

function envNumber(name: string, fallback: number): number {
  const value = Number(Deno.env.get(name));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

interface Quota {
  plan: string;
  remaining: number | null;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (disabled) return json({ error: "transcription_unavailable" }, 503);

  const caller = await authenticate(request, admin);
  if (!caller) return json({ error: "unauthorized" }, 401);

  const parsed = parseTranscribeRequest(await request.json().catch(() => null));
  if (!parsed.ok) return json({ error: "bad_request", detail: parsed.error }, 400);
  const body = parsed.value;

  const { data: withinLimit, error: limitError } = await admin.rpc("consume_bucket", {
    p_key: `transcribe:${caller.userId}`,
    p_limit: caller.isAnonymous ? ANONYMOUS_PER_MINUTE : PER_MINUTE,
    p_window_seconds: 60,
  });
  if (limitError) console.error("rate limit check failed", limitError);
  else if (withinLimit !== true) return json({ error: "rate_limited" }, 429);

  // The free plan's weekly words are counted by `cleanup`; once they're used up, stop paying for
  // transcription too.
  const { data: quota, error: quotaError } = await admin
    .rpc("quota_status", { p_user: caller.userId })
    .single<Quota>();
  if (quotaError) console.error("quota check failed", quotaError);
  else if (quota && quota.remaining !== null && quota.remaining <= 0) {
    return json({ error: "limit_reached" }, 402);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    console.error("OPENAI_API_KEY is not set");
    return json({ error: "transcription_unavailable" }, 503);
  }

  const started = Date.now();
  try {
    const result = await transcribeWithOpenAI(body, { apiKey, model, deadlineMs });
    const totalMs = Date.now() - started;
    console.log(JSON.stringify({
      event: "transcribe",
      model,
      format: body.format,
      bytes: body.audio.length,
      language: body.language,
      detected: result.languages,
      keywords: body.keywords.length,
      outChars: result.text.length,
      isAnonymous: caller.isAnonymous,
      totalMs,
    }));
    return json({ text: result.text, languages: result.languages, model, totalMs });
  } catch (error) {
    if (error instanceof OpenAIError) console.error(error.message);
    else console.error("transcription failed", error instanceof Error ? error.name : String(error));
    return json({ error: "transcription_unavailable" }, 502);
  }
});
