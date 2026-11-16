// POST /functions/v1/command — Command mode (Murmur for Mac). The handler is _shared/command.ts.
// multipart/form-data: a "metadata" JSON part { commandId: uuid, format: "m4a" | "wav",
// language?: BCP-47 | null, languages?: BCP-47[], selection: string (≤ 8,000 characters) } and an
// "audio" file part (the spoken instruction; it needs a filename). Header x-murmur-dictation:
// <commandId>, as `dictate` asks, so the preflight (attempts, rate limit, plan) runs first.
// Pro and trial only.
// Responses:
//   200 { instruction, text, status: "rewritten" | "unchanged", reason?, model, words, timings }
//       `text` replaces the selection; "unchanged" gives the selection back (nothing heard, or an
//       instruction the model couldn't apply). `words` counts toward usage.
//   400 bad_request · 401 unauthorized · 402 pro_required | limit_reached · 429 rate_limited | too_many_attempts
//   502 transcription_unavailable | command_unavailable · 503 command_unavailable (keys, preflight)
// Env: OPENAI_API_KEY (required), ANTHROPIC_API_KEY (for a claude- model), COMMAND_MODEL and
// COMMAND_EFFORT (default to CLEANUP_MODEL / CLEANUP_EFFORT), COMMAND_DEADLINE_MS (15000),
// TRANSCRIBE_MODEL, TRANSCRIBE_DEADLINE_MS.
import { audioDurationMs } from "../_shared/audio_duration.ts";
import { commandConfig, createCommandHandler } from "../_shared/command.ts";
import { createCostRecorder } from "../_shared/cost.ts";
import { adminClient, authenticate, background } from "../_shared/http.ts";
import { dictationPreflight, recordUsage } from "../_shared/preflight.ts";
import { transcribeWithOpenAI } from "../_shared/transcribe.ts";

const admin = adminClient();
const config = commandConfig();
const openAIKey = Deno.env.get("OPENAI_API_KEY");

Deno.serve(createCommandHandler({
  config,
  openAIKey,
  anthropicKey: Deno.env.get("ANTHROPIC_API_KEY"),
  authenticate: (request) => authenticate(request, admin),
  preflight: (caller, commandId, perMinute) => dictationPreflight(admin, caller, "command", commandId, perMinute),
  transcribe: (request, signal) => transcribeWithOpenAI({
    dictationId: request.commandId,
    audio: request.audio,
    format: request.format,
    language: request.language,
    languageHints: request.languageHints,
    keywords: [],
  }, { apiKey: openAIKey ?? "", model: config.transcribeModel, deadlineMs: config.transcribeDeadlineMs, signal }),
  recordUsage: (caller, commandId, words) => recordUsage(admin, caller, commandId, words),
  recordCost: createCostRecorder(() => admin),
  background,
  audioMs: audioDurationMs,
}));
