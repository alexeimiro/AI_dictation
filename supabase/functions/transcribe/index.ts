// POST /functions/v1/transcribe
// Turns a dictation's audio into text with OpenAI. The audio is passed through, never stored.
// Body: { dictationId?, audio (base64), format: "m4a" | "wav", language? (BCP-47), keywords? }.
// Header x-murmur-dictation: <dictationId> vouches that the id is the dictation's own; its words
// then count toward the free plan's week (`transcriptUsage`). Without it nothing is counted here.
// Responses:
//   200 { text, languages, model, words, remaining, totalMs, timings }
//       `words` is what was counted (0 when nothing was) and `remaining` the free plan's words left
//       after it (null when unlimited or unknown). `totalMs` is the OpenAI call alone; `timings`
//       splits the whole request (_shared/timing.ts).
//   400 bad_request · 401 unauthorized · 402 limit_reached · 429 rate_limited
//   502/503 transcription_unavailable → the app falls back to on-device recognition if it can.
// Env: OPENAI_API_KEY (required), TRANSCRIBE_MODEL (default gpt-transcribe),
// TRANSCRIBE_DEADLINE_MS (whole OpenAI call, default 20000), TRANSCRIBE_DISABLED=1,
// TRANSCRIBE_FAIL_CLOSED=1 (a limit or quota check that can't run answers 503; off, the dictation
// goes through unchecked while the database is out).
// The handler is _shared/transcribe_handler.ts.
import { transcribeConfig } from "../_shared/config.ts";
import { createCostRecorder } from "../_shared/cost.ts";
import { adminClient, authenticate, background } from "../_shared/http.ts";
import { createTranscribeHandler } from "../_shared/transcribe_handler.ts";

const admin = adminClient();

Deno.serve(createTranscribeHandler({
  admin,
  config: transcribeConfig(),
  apiKey: Deno.env.get("OPENAI_API_KEY"),
  disabled: Deno.env.get("TRANSCRIBE_DISABLED") === "1",
  failClosed: Deno.env.get("TRANSCRIBE_FAIL_CLOSED") === "1",
  authenticate: (request) => authenticate(request, admin),
  recordCost: createCostRecorder(() => admin),
  background,
}));
