import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import { buildTranscriptMessage, buildUserContext, CLEANUP_RULES } from "./prompt.ts";
import { guardOutput, tidyOutput } from "./text.ts";
import type { CleanupRequest } from "./types.ts";

/** Chosen by the user; override with the CLEANUP_MODEL secret without shipping an app update. */
export const DEFAULT_MODEL = "claude-opus-5-5";

export interface CleanupOutcome {
  text: string;
  /** "raw": the model output was unusable (refusal, truncation, guard) — the transcript is returned. */
  status: "cleaned" | "raw";
  reason?: string;
  model: string;
  ttftMs: number | null;
  totalMs: number;
  cacheReadTokens: number;
}

export interface CleanupOptions {
  model: string;
  timeoutMs: number;
}

/**
 * One cleanup call. Streams internally so time-to-first-token can be measured, then reads the
 * final message. Thinking can't be disabled on Claude Opus 5.5, so effort "low" keeps it short.
 */
export async function runCleanup(
  client: Anthropic,
  request: CleanupRequest,
  options: CleanupOptions,
): Promise<CleanupOutcome> {
  const started = performance.now();
  const stream = client.beta.messages.stream(
    {
      model: options.model,
      max_tokens: 16000,
      // Server-side refusal fallback: a declined request is retried on Anthropic's
      // recommended fallback model inside the same call.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      output_config: { effort: "low" },
      system: [
        { type: "text", text: CLEANUP_RULES, cache_control: { type: "ephemeral" } },
        { type: "text", text: buildUserContext(request), cache_control: { type: "ephemeral" } },
      ],
      messages: [{ role: "user", content: buildTranscriptMessage(request.transcript) }],
    },
    { timeout: options.timeoutMs, maxRetries: 1 },
  );

  let ttftMs: number | null = null;
  stream.on("text", () => {
    if (ttftMs === null) ttftMs = Math.round(performance.now() - started);
  });
  const message = await stream.finalMessage();
  const totalMs = Math.round(performance.now() - started);
  const base = {
    model: message.model,
    ttftMs,
    totalMs,
    cacheReadTokens: message.usage.cache_read_input_tokens ?? 0,
  };

  // A refusal can arrive with partial or no content; a truncated reply is incomplete.
  if (message.stop_reason === "refusal" || message.stop_reason === "max_tokens") {
    return { ...base, text: request.transcript, status: "raw", reason: message.stop_reason };
  }

  const text = tidyOutput(
    message.content
      .filter((block): block is Anthropic.Beta.BetaTextBlock => block.type === "text")
      .map((block) => block.text)
      .join(""),
  );
  const guard = guardOutput(request.transcript, text, request.language);
  if (!guard.ok) {
    return { ...base, text: request.transcript, status: "raw", reason: guard.reason };
  }
  return { ...base, text, status: "cleaned" };
}
