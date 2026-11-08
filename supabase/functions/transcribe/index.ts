// POST /functions/v1/transcribe
// Turns a dictation's audio into text with OpenAI. The audio is passed through, never stored.
// Body: { dictationId?, audio (base64), format: "m4a" | "wav", language? (BCP-47), keywords? }.
// Responses:
//   200 { text, languages, model, totalMs, timings }
//       `totalMs` is the OpenAI call alone; `timings` splits the whole request (_shared/timing.ts).
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited
//   502/503 transcription_unavailable → the app falls back to on-device recognition if it can.
// Env: OPENAI_API_KEY (required), TRANSCRIBE_MODEL (default gpt-transcribe),
// TRANSCRIBE_DEADLINE_MS (whole OpenAI call, default 20000), TRANSCRIBE_DISABLED=1.
import { transcribeConfig } from "../_shared/config.ts";
import { adminClient, authenticate, clientInfo, corsHeaders, json } from "../_shared/http.ts";
import { beginRequest, Phases } from "../_shared/timing.ts";
import { OpenAIError, parseTranscribeRequest, transcribeWithOpenAI } from "../_shared/transcribe.ts";

const admin = adminClient();
/** The deadline must stay below the app's request timeout (25 s). */
const { model, deadlineMs } = transcribeConfig();
/** Kill switch: answers 503 before any database or model call. */
const disabled = Deno.env.get("TRANSCRIBE_DISABLED") === "1";
const PER_MINUTE = 40;
const ANONYMOUS_PER_MINUTE = 10;

interface Quota {
  plan: string;
  remaining: number | null;
}

Deno.serve(async (request) => {
  const worker = beginRequest();
  const phases = new Phases(worker);
  if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (disabled) return json({ error: "transcription_unavailable" }, 503);

  const caller = await phases.mark("authMs", authenticate(request, admin));
  if (!caller) return json({ error: "unauthorized" }, 401);

  const parsed = parseTranscribeRequest(await phases.mark("bodyMs", request.json().catch(() => null)));
  if (!parsed.ok) return json({ error: "bad_request", detail: parsed.error }, 400);
  const body = parsed.value;

  const { data: withinLimit, error: limitError } = await phases.mark("preflightMs", admin.rpc("consume_bucket", {
    p_key: `transcribe:${caller.userId}`,
    p_limit: caller.isAnonymous ? ANONYMOUS_PER_MINUTE : PER_MINUTE,
    p_window_seconds: 60,
  }));
  if (limitError) console.error("rate limit check failed", limitError);
  else if (withinLimit !== true) return json({ error: "rate_limited" }, 429);

  // The free plan's weekly words are counted by `cleanup`; once they're used up, stop paying for
  // transcription too.
  const { data: quota, error: quotaError } = await phases.mark("preflightMs", admin
    .rpc("quota_status", { p_user: caller.userId })
    .single<Quota>());
  if (quotaError) console.error("quota check failed", quotaError);
  else if (quota && quota.remaining !== null && quota.remaining <= 0) {
    return json({ error: "limit_reached" }, 402);
  }

  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    console.error("OPENAI_API_KEY is not set");
    return json({ error: "transcription_unavailable" }, 503);
  }

  phases.ready();
  const started = Date.now();
  try {
    const result = await phases.mark("transcribeMs", transcribeWithOpenAI(body, { apiKey, model, deadlineMs }));
    const totalMs = Date.now() - started;
    const timings = phases.toJSON();
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
      ...worker,
      client: clientInfo(request),
      timings,
    }));
    return json({ text: result.text, languages: result.languages, model, totalMs, timings });
  } catch (error) {
    if (error instanceof OpenAIError) console.error(error.message);
    else console.error("transcription failed", error instanceof Error ? error.name : String(error));
    return json({ error: "transcription_unavailable" }, 502);
  }
});
