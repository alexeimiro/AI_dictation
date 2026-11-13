// POST /functions/v1/dictate
// One request per dictation: transcribed, then translated or written in its style by the model;
// Word for word stops at the transcript. The handler is _shared/dictate.ts.
// Three modes:
//   audio: multipart/form-data with a "metadata" JSON part { dictationId, format: "m4a" | "wav",
//          language: BCP-47 | null, keywords?, targetLanguage?, style?, dictionary?, snippets? } and
//          an "audio" file part of raw bytes. targetLanguage is required unless the style is named:
//          one the model writes ("grammar", "professional", "chat", "concise"), or "verbatim".
//          The audio part needs a filename (any) in its Content-Disposition: without one it arrives
//          as text, and gets 400. Transcribes, then translates (or, with no target, writes in
//          the style) on the same worker; a null or "und" language is the one it hears first.
//          Without a target, 3 words or fewer stay as heard: "raw", reason "short". "verbatim"
//          without a target is the transcript alone, of any length, with no model call: "raw",
//          reason "transcribed", its words counted as `transcribe` counts them.
//   text:  application/json, a CleanupRequest with targetLanguage (see _shared/types.ts), plus
//          speculative?: boolean and attempt?: integer, which are only logged.
//   warm:  the header x-murmur-warm: 1 and no body. Checks the token and opens the connections to
//          OpenAI, Anthropic (with a Claude model configured) and the database while the user
//          speaks; no writes.
// Audio and text mode need x-murmur-dictation: <the body's dictationId>, so the preflight
// (attempts, rate limit, quota) is checked from the headers while the body uploads. Every audio
// call takes from `transcribe`'s rate limit, as a legacy transcription does; a dictation's text
// calls take one slot of dictate's, for up to 6 calls in 10 minutes.
// Responses:
//   200 { transcript, languages, transcribeModel, text, status: "cleaned" | "raw" | "unavailable",
//         reason, targetLanguage, words, model, ttftMs, totalMs, remaining, timings }
//       `cleanup`'s reply plus the transcription (`transcript` is null in text mode). `text` is ""
//       unless "cleaned"; "unavailable" (the translation failed or ran out of time) keeps the
//       transcript, and nothing is counted for it.
//   200 { warm: true, cold, region, workerAgeMs, executionId, timings: { authMs, openaiMs?, anthropicMs?, dbMs?, totalMs } }
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited | too_many_attempts
//   404 dictate_disabled (kill switch) → the app goes back to transcribe + cleanup.
//   502 transcription_unavailable (audio) | translation_unavailable (text)
//   503 dictate_unavailable: no OpenAI key, no Anthropic key for a Claude model, or the preflight
//       RPC (or the token check itself) failed.
// Each server bound stays below the app's timeout for the mode: audio 26 s, with transcription 20 s
// and the translation min(9 s, what is left) (app 30 s); text 9 s (app 11 s); warm 3 s per fetch
// (app 5 s).
// Env: OPENAI_API_KEY (required), ANTHROPIC_API_KEY (required when a model below is a `claude-`
// one), TRANSCRIBE_MODEL and TRANSCRIBE_DEADLINE_MS (as `transcribe`), TRANSLATE_MODEL and
// TRANSLATE_EFFORT (each defaults to its CLEANUP_* value; the translation deadline is
// CLEANUP_DEADLINE_MS), DICTATE_DEADLINE_MS (default 26000), DICTATE_DISABLED=1.
import { dictateConfig } from "../_shared/config.ts";
import { createCostRecorder } from "../_shared/cost.ts";
import { createDictateHandler } from "../_shared/dictate.ts";
import { adminClient, authenticate, background } from "../_shared/http.ts";
import { dictationPreflight, readQuota, recordUsage } from "../_shared/preflight.ts";

const admin = adminClient();

Deno.serve(createDictateHandler({
  config: dictateConfig(),
  apiKey: Deno.env.get("OPENAI_API_KEY"),
  anthropicApiKey: Deno.env.get("ANTHROPIC_API_KEY"),
  authenticate: (request) => authenticate(request, admin),
  preflight: (caller, scope, dictationId, perMinute) => dictationPreflight(admin, caller, scope, dictationId, perMinute),
  readQuota: (caller, signal) => readQuota(admin, caller, signal),
  recordUsage: (caller, dictationId, words) => recordUsage(admin, caller, dictationId, words),
  recordCost: createCostRecorder(() => admin),
  background,
}));
