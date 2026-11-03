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

/** OpenAI's flagship; override with the CLEANUP_MODEL secret without shipping an app update. */
export const DEFAULT_MODEL = "gpt-6-astra";
/** Reasoning effort: "low" keeps a short rewrite quick on a reasoning model. */
export const DEFAULT_EFFORT = "low";

export interface CleanupUsage {
  input: number;
  output: number;
  cacheRead: number;
  /** Always 0: OpenAI doesn't charge for writing its prompt cache. Kept for the logs' shape. */
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
  /** Not measured: the reply isn't streamed, so it's null. */
  ttftMs: number | null;
  totalMs: number;
  usage: CleanupUsage;
  /** Same as usage.cacheRead; kept because the serve log and the goldens read it. */
  cacheReadTokens: number;
}

export interface CleanupOptions {
  model: string;
  /** OpenAI reasoning effort: none, minimal, low, medium, high, xhigh or max (model-dependent). */
  effort?: string;
  apiKey: string;
  /** Hard bound on the whole call. */
  deadlineMs: number;
  /** Replaces the `AbortSignal.timeout(deadlineMs)` default, so tests create no timers. */
  signal?: AbortSignal;
  /** Replaces `fetch` in tests. */
  fetcher?: typeof fetch;
}

/** An HTTP error from OpenAI. Only the status and error code are kept: the body can echo input. */
export class CleanupAPIError extends Error {
  constructor(readonly status: number, readonly code: string | null) {
    super(`OpenAI cleanup failed with HTTP ${status}${code ? ` (${code})` : ""}`);
  }
}

/**
 * The system prompt in stability order: shared rules → language pack → per-user context. OpenAI
 * caches the longest identical prefix (from 1,024 tokens), so the parts every user of a language
 * shares come first and the per-user context last.
 */
export function buildInstructionParts(request: CleanupRequest, language: ResolvedLanguage): string[] {
  return [CLEANUP_RULES, buildLanguageBlock(language.rules), buildUserContext(request, language)];
}

/** The Responses API request body. */
export function buildResponsesRequest(
  request: CleanupRequest,
  language: ResolvedLanguage,
  options: Pick<CleanupOptions, "model" | "effort">,
): Record<string, unknown> {
  return {
    model: options.model,
    instructions: buildInstructionParts(request, language).join("\n\n"),
    input: [{ role: "user", content: buildTranscriptMessage(request.transcript) }],
    reasoning: { effort: options.effort ?? DEFAULT_EFFORT },
    // Includes reasoning tokens; a 20,000-character transcript needs most of it.
    max_output_tokens: 16000,
    // Dictations are never kept on OpenAI's side as stored responses.
    store: false,
    // Routes requests that share the language's prefix to the same cache.
    prompt_cache_key: `murmur-cleanup-${language.key}`,
  };
}

interface ResponsesReply {
  model?: string;
  status?: string;
  incomplete_details?: { reason?: string } | null;
  output?: Array<{ type?: string; content?: Array<{ type?: string; text?: string; refusal?: string }> }>;
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    input_tokens_details?: { cached_tokens?: number };
  };
}

/** One cleanup call. A deadline abort surfaces as a DOMException (see `describeCleanupError`). */
export async function runCleanup(request: CleanupRequest, options: CleanupOptions): Promise<CleanupOutcome> {
  const language = resolveLanguage(request.language);
  const started = performance.now();
  const fetcher = options.fetcher ?? fetch;
  const response = await fetcher("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { Authorization: `Bearer ${options.apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(buildResponsesRequest(request, language, options)),
    signal: options.signal ?? AbortSignal.timeout(options.deadlineMs),
  });
  if (!response.ok) {
    const detail = await response.json().catch(() => null) as { error?: { code?: string; type?: string } } | null;
    throw new CleanupAPIError(response.status, detail?.error?.code ?? detail?.error?.type ?? null);
  }
  const reply = await response.json() as ResponsesReply;
  const totalMs = Math.round(performance.now() - started);
  const cacheRead = reply.usage?.input_tokens_details?.cached_tokens ?? 0;
  const base = {
    model: reply.model ?? options.model,
    language: language.key,
    stopReason: reply.incomplete_details?.reason ?? reply.status ?? null,
    ttftMs: null,
    totalMs,
    usage: {
      input: reply.usage?.input_tokens ?? 0,
      output: reply.usage?.output_tokens ?? 0,
      cacheRead,
      cacheCreation: 0,
    },
    cacheReadTokens: cacheRead,
  };

  // A truncated or filtered reply is incomplete; a refusal has no usable text.
  if (reply.status === "incomplete") {
    return { ...base, text: request.transcript, status: "raw", reason: reply.incomplete_details?.reason ?? "incomplete" };
  }
  const content = (reply.output ?? [])
    .filter((item) => item.type === "message")
    .flatMap((item) => item.content ?? []);
  if (content.some((part) => part.type === "refusal")) {
    return { ...base, text: request.transcript, status: "raw", reason: "refusal" };
  }

  const text = tidyOutput(
    content.filter((part) => part.type === "output_text").map((part) => part.text ?? "").join(""),
  );
  const guard = guardOutput(request.transcript, text, language.tag ?? "en");
  if (!guard.ok) {
    return { ...base, text: request.transcript, status: "raw", reason: guard.reason };
  }
  return { ...base, text, status: "cleaned" };
}

/**
 * Log label for a failed call. Every failure maps to HTTP 502 for the app (which then inserts its
 * locally formatted text); the label is what the serve log shows.
 */
export function describeCleanupError(error: unknown): string {
  if (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError")) {
    return "cleanup deadline";
  }
  if (error instanceof CleanupAPIError) {
    return error.status === 429 ? "openai rate limited" : `openai error ${error.status}`;
  }
  if (error instanceof TypeError) return "openai connection";
  return "cleanup failed";
}
