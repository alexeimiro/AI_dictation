import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import {
  buildLanguageBlock,
  buildTranscriptMessage,
  buildUserContext,
  CLEANUP_RULES,
  resolveLanguage,
  type ResolvedLanguage,
} from "./prompt.ts";
import { guardOutput, tidyOutput } from "./text.ts";
import type { CleanupRequest } from "./types.ts";

/** Chosen by the user; override with the CLEANUP_MODEL secret without shipping an app update. */
export const DEFAULT_MODEL = "claude-opus-5-5";

export interface CleanupUsage {
  input: number;
  output: number;
  cacheRead: number;
  cacheCreation: number;
}

export interface CleanupOutcome {
  text: string;
  /** "raw": the model output was unusable (refusal, truncation, guard) — the transcript is returned. */
  status: "cleaned" | "raw";
  reason?: string;
  model: string;
  /** Language pack that was applied ("en", "ru"). */
  language: string;
  stopReason: string | null;
  ttftMs: number | null;
  totalMs: number;
  usage: CleanupUsage;
  /** Same as usage.cacheRead; kept because the serve log and the goldens read it. */
  cacheReadTokens: number;
}

export interface CleanupOptions {
  model: string;
  /**
   * How long Anthropic may take to send the response headers (the SDK `timeout`). The SDK clears
   * it once headers arrive and retries a timed-out request once, so wall-clock can reach 2×.
   */
  timeoutMs: number;
  /** Hard bound on the whole call including the streamed body, which the SDK timeout never covers. */
  deadlineMs: number;
  /** Replaces the `AbortSignal.timeout(deadlineMs)` default, so tests create no timers. */
  signal?: AbortSignal;
}

/**
 * The three system blocks in stability order, each a cache breakpoint (the API allows four):
 * shared rules → language pack → per-user context. Block 1 alone clears the 512-token minimum,
 * which applies to the cumulative prefix, so every block is cacheable.
 */
export function buildSystemBlocks(
  request: CleanupRequest,
  language: ResolvedLanguage,
): Anthropic.Beta.BetaTextBlockParam[] {
  return [
    { type: "text", text: CLEANUP_RULES, cache_control: { type: "ephemeral" } },
    { type: "text", text: buildLanguageBlock(language.rules), cache_control: { type: "ephemeral" } },
    { type: "text", text: buildUserContext(request, language), cache_control: { type: "ephemeral" } },
  ];
}

/**
 * One cleanup call. Streams internally so time-to-first-token can be measured, then reads the
 * final message. Thinking can't be disabled on Claude Opus 5.5, so effort "low" keeps it short.
 * A deadline abort surfaces as `Anthropic.APIUserAbortError` (see `describeCleanupError`).
 */
export async function runCleanup(
  client: Anthropic,
  request: CleanupRequest,
  options: CleanupOptions,
): Promise<CleanupOutcome> {
  const language = resolveLanguage(request.language);
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
      system: buildSystemBlocks(request, language),
      messages: [{ role: "user", content: buildTranscriptMessage(request.transcript) }],
    },
    {
      timeout: options.timeoutMs,
      maxRetries: 1,
      signal: options.signal ?? AbortSignal.timeout(options.deadlineMs),
    },
  );

  let ttftMs: number | null = null;
  stream.on("text", () => {
    if (ttftMs === null) ttftMs = Math.round(performance.now() - started);
  });
  const message = await stream.finalMessage();
  const totalMs = Math.round(performance.now() - started);
  const usage = message.usage;
  const base = {
    model: message.model,
    language: language.key,
    stopReason: message.stop_reason,
    ttftMs,
    totalMs,
    usage: {
      input: usage.input_tokens ?? 0,
      output: usage.output_tokens ?? 0,
      cacheRead: usage.cache_read_input_tokens ?? 0,
      cacheCreation: usage.cache_creation_input_tokens ?? 0,
    },
    cacheReadTokens: usage.cache_read_input_tokens ?? 0,
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
  const guard = guardOutput(request.transcript, text, language.tag ?? "en");
  if (!guard.ok) {
    return { ...base, text: request.transcript, status: "raw", reason: guard.reason };
  }
  return { ...base, text, status: "cleaned" };
}

/**
 * Log label for a failed call. Every failure maps to HTTP 502 for the app (which then inserts its
 * locally formatted text); the label is what the serve log shows. Most specific classes first:
 * the abort and timeout errors are subclasses of APIError.
 */
export function describeCleanupError(error: unknown): string {
  if (error instanceof Anthropic.APIUserAbortError) return "cleanup deadline";
  if (error instanceof Anthropic.RateLimitError) return "anthropic rate limited";
  if (error instanceof Anthropic.APIConnectionTimeoutError) return "anthropic timeout";
  if (error instanceof Anthropic.APIError) return `anthropic error ${error.status ?? "connection"}`;
  return "cleanup failed";
}
