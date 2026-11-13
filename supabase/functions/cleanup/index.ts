// POST /functions/v1/cleanup
// Turns a transcript into the text the user meant to type, using an OpenAI or a Claude model.
// Body: CleanupRequest (see _shared/types.ts). With `targetLanguage` set it translates instead.
// Responses:
//   200 { text, status: "cleaned" | "raw", reason, targetLanguage, words, model, ttftMs, totalMs, remaining, timings }
//       `reason` says why a reply is "raw" (refusal, guard such as "untranslated"); `targetLanguage`
//       echoes the language a translation was written in, null for a cleanup. `totalMs` is the
//       model call alone; `timings` splits the whole request (_shared/timing.ts).
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited
//   502/503 cleanup_unavailable → the app inserts its locally formatted transcript instead.
// Env: CLEANUP_MODEL (default gpt-6-astra; a `claude-` model runs on Anthropic), CLEANUP_EFFORT
// (reasoning effort, default low; none means thinking off on Claude), CLEANUP_DEADLINE_MS (whole
// call, default 9000), CLEANUP_DISABLED=1, and the model's key: OPENAI_API_KEY, or
// ANTHROPIC_API_KEY for a Claude model.
// Translations take TRANSLATE_MODEL and TRANSLATE_EFFORT instead, each defaulting to its CLEANUP_*
// value (_shared/config.ts).
// The handler is _shared/cleanup_handler.ts.
import { cleanupConfig, translationConfig } from "../_shared/config.ts";
import { createCleanupHandler } from "../_shared/cleanup_handler.ts";
import { createCostRecorder } from "../_shared/cost.ts";
import { adminClient, authenticate, background } from "../_shared/http.ts";

const admin = adminClient();

Deno.serve(createCleanupHandler({
  admin,
  cleanup: cleanupConfig(),
  translation: translationConfig(),
  disabled: Deno.env.get("CLEANUP_DISABLED") === "1",
  key: (name) => Deno.env.get(name),
  authenticate: (request) => authenticate(request, admin),
  recordCost: createCostRecorder(() => admin),
  background,
}));
