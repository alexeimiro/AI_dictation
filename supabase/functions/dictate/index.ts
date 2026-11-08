// POST /functions/v1/dictate
// One request per translated dictation; the handler is _shared/dictate.ts. Three modes:
//   audio: multipart/form-data with a "metadata" JSON part { dictationId, format: "m4a" | "wav",
//          language: BCP-47 | null, keywords?, targetLanguage, style?, dictionary?, snippets? } and an
//          "audio" file part of raw bytes. Transcribes, then translates on the same worker.
//   text:  application/json, a CleanupRequest with targetLanguage (see _shared/types.ts), plus
//          speculative?: boolean and attempt?: integer, which are only logged.
//   warm:  the header x-murmur-warm: 1 and no body. Checks the token and opens the connections to
//          OpenAI and the database while the user speaks; no writes.
// Audio and text mode need x-murmur-dictation: <the body's dictationId>, so the token and the
// preflight (attempts, rate limit, quota) are checked from the headers while the body uploads.
// Responses:
//   200 { transcript, languages, transcribeModel, text, status: "cleaned" | "raw" | "unavailable",
//         reason, targetLanguage, words, model, ttftMs, totalMs, remaining, timings }
//       `cleanup`'s reply plus the transcription (`transcript` is null in text mode). `text` is ""
//       unless "cleaned"; "unavailable" (the translation failed or ran out of time) keeps the
//       transcript, and nothing is counted for it.
//   200 { warm: true, cold, region, workerAgeMs, executionId, timings: { authMs, openaiMs?, dbMs?, totalMs } }
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited | too_many_attempts
//   404 dictate_disabled (kill switch) → the app goes back to transcribe + cleanup.
//   502 transcription_unavailable (audio) | translation_unavailable (text)
//   503 dictate_unavailable: no OpenAI key, or the preflight RPC (or the token check itself) failed.
// Each server bound stays below the app's timeout for the mode: audio 26 s, with transcription 20 s
// and the translation min(9 s, what is left) (app 30 s); text 9 s (app 11 s); warm 3 s per fetch
// (app 5 s).
// Env: OPENAI_API_KEY (required), TRANSCRIBE_MODEL and TRANSCRIBE_DEADLINE_MS (as `transcribe`),
// TRANSLATE_MODEL and TRANSLATE_EFFORT (each defaults to its CLEANUP_* value; the translation
// deadline is CLEANUP_DEADLINE_MS), DICTATE_DEADLINE_MS (default 26000), DICTATE_DISABLED=1.
import { dictateConfig } from "../_shared/config.ts";
import { createDictateHandler } from "../_shared/dictate.ts";
import { adminClient, authenticate, background } from "../_shared/http.ts";
import { dictationPreflight, readQuota, recordUsage } from "../_shared/preflight.ts";

const admin = adminClient();

Deno.serve(createDictateHandler({
  config: dictateConfig(),
  apiKey: Deno.env.get("OPENAI_API_KEY"),
  authenticate: (request) => authenticate(request, admin),
  preflight: (caller, dictationId, perMinute) => dictationPreflight(admin, caller, "dictate", dictationId, perMinute),
  readQuota: (caller, signal) => readQuota(admin, caller, signal),
  recordUsage: (caller, dictationId, words) => recordUsage(admin, caller, dictationId, words),
  background,
}));
