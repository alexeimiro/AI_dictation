import Anthropic from "npm:@anthropic-ai/sdk@1.2.0";
import {
  buildLanguageBlock,
  buildTranscriptMessage,
  buildTranslationContext,
  buildTranslationMessage,
  buildUserContext,
  CLEANUP_RULES,
  resolveLanguage,
  type ResolvedLanguage,
  TRANSLATION_RULES,
} from "./prompt.ts";
import { guardOutput, guardTranslation, tidyOutput } from "./text.ts";
import type { CleanupRequest } from "./types.ts";

/** OpenAI's flagship; override with the CLEANUP_MODEL secret without shipping an app update. */
export const DEFAULT_MODEL = "gpt-6-astra";
/** Reasoning effort: "low" keeps a short rewrite quick on a reasoning model. */
export const DEFAULT_EFFORT = "low";

/**
 * A `claude-` model runs on Anthropic's Messages API with ANTHROPIC_API_KEY; any other model on
 * OpenAI's Responses API with OPENAI_API_KEY. The model secrets alone pick the provider.
 */
export function isClaudeModel(model: string): boolean {
  return model.startsWith("claude-");
}

/** The secret that holds the key for `model`'s provider. */
export function apiKeyName(model: string): "ANTHROPIC_API_KEY" | "OPENAI_API_KEY" {
  return isClaudeModel(model) ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY";
}

export interface CleanupUsage {
  input: number;
  output: number;
  cacheRead: number;
  /** Input tokens written to the prompt cache, 0 when the reply doesn't say. Writes are billed. */
  cacheWrite: number;
}

export interface CleanupOutcome {
  text: string;
  /** "raw": the model output was unusable (refusal, truncation, guard) — the transcript is returned. */
  status: "cleaned" | "raw";
  reason?: string;
  model: string;
  /** Language pack that was applied ("en", "ru", "tr", "auto"); for a translation, the source's. */
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
  /**
   * Reasoning effort: none, minimal, low, medium, high, xhigh or max (model-dependent). On Claude,
   * none and minimal mean low effort with thinking off (`claudeThinking`).
   */
  effort?: string;
  /** The key of the model's provider (`apiKeyName`). */
  apiKey: string;
  /** Hard bound on the whole call. */
  deadlineMs: number;
  /** Replaces the `AbortSignal.timeout(deadlineMs)` default, so tests create no timers. */
  signal?: AbortSignal;
  /** Replaces `fetch` in tests (for Claude, the SDK's). */
  fetcher?: typeof fetch;
}

/** An HTTP error from the model's provider. Only the status and error code are kept: the body can echo input. */
export class CleanupAPIError extends Error {
  constructor(
    readonly status: number,
    readonly code: string | null,
    readonly provider: "openai" | "anthropic" = "openai",
  ) {
    super(
      `${provider === "openai" ? "OpenAI" : "Anthropic"} cleanup failed with HTTP ${status}${code ? ` (${code})` : ""}`,
    );
  }
}

/**
 * The system prompt in stability order. A cleanup: shared rules → language pack → per-user context.
 * A translation (`targetLanguage` set): translation rules → per-user context with the language
 * pair. OpenAI caches the longest identical prefix (from 1,024 tokens), so the parts every user
 * shares come first and the per-user context last.
 */
export function buildInstructionParts(request: CleanupRequest, language: ResolvedLanguage): string[] {
  if (request.targetLanguage) return [TRANSLATION_RULES, buildTranslationContext(request, language)];
  return [CLEANUP_RULES, buildLanguageBlock(language.rules), buildUserContext(request, language)];
}

/** The Responses API request body. */
export function buildResponsesRequest(
  request: CleanupRequest,
  language: ResolvedLanguage,
  options: Pick<CleanupOptions, "model" | "effort">,
): Record<string, unknown> {
  const target = request.targetLanguage;
  return {
    model: options.model,
    instructions: buildInstructionParts(request, language).join("\n\n"),
    input: [{
      role: "user",
      content: target ? buildTranslationMessage(request.transcript, target) : buildTranscriptMessage(request.transcript),
    }],
    reasoning: { effort: options.effort ?? DEFAULT_EFFORT },
    // Includes reasoning tokens; a 20,000-character transcript needs most of it.
    max_output_tokens: 16000,
    // Dictations are never kept on OpenAI's side as stored responses.
    store: false,
    // Routes requests that share a prefix to the same cache: one per cleanup language, and one
    // for every translation (the language pair is in the per-user context, after the prefix).
    prompt_cache_key: target ? "murmur-translate" : `murmur-cleanup-${language.key}`,
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
    input_tokens_details?: { cached_tokens?: number; cache_write_tokens?: number };
  };
}

/**
 * One cleanup call, on the provider `options.model` names. A deadline abort surfaces as a
 * DOMException from OpenAI and as the SDK's abort or timeout error from Anthropic (see
 * `isCleanupDeadline`).
 */
export async function runCleanup(request: CleanupRequest, options: CleanupOptions): Promise<CleanupOutcome> {
  return isClaudeModel(options.model) ? await runClaude(request, options) : await runOpenAI(request, options);
}

async function runOpenAI(request: CleanupRequest, options: CleanupOptions): Promise<CleanupOutcome> {
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
      cacheWrite: reply.usage?.input_tokens_details?.cache_write_tokens ?? 0,
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

  const text = content.filter((part) => part.type === "output_text").map((part) => part.text ?? "").join("");
  return judged(request, language, base, text);
}

/** Claude's effort levels; any other value (OpenAI's none and minimal) means low effort with thinking off. */
const CLAUDE_EFFORTS = new Set(["low", "medium", "high", "xhigh", "max"]);

/**
 * Thinking and effort for a Claude model, from an effort secret that may be written for OpenAI.
 * Claude's own levels leave thinking adaptive. Otherwise thinking is off at low effort where the
 * model allows it: Claude Sonnet 5.5 turns it off with "between_tools", Claude Opus 5.5 and Fable
 * always think, and the rest (Claude Haiku 5.5 among them) take "disabled".
 */
export function claudeThinking(
  model: string,
  effort: string,
): Pick<Anthropic.MessageCreateParamsNonStreaming, "thinking" | "output_config"> {
  if (CLAUDE_EFFORTS.has(effort)) {
    return { output_config: { effort: effort as NonNullable<Anthropic.OutputConfig["effort"]> } };
  }
  const output_config = { effort: "low" as const };
  if (model.startsWith("claude-sonnet-5-5")) return { thinking: { type: "between_tools" }, output_config };
  if (model.startsWith("claude-opus-5-5") || model.startsWith("claude-fable")) return { output_config };
  return { thinking: { type: "disabled" }, output_config };
}

/**
 * The Messages API request body: the instructions `buildInstructionParts` gives OpenAI, as system
 * blocks that are each a cache breakpoint (three at most of the four allowed), shared rules first
 * and the per-user context last.
 */
export function buildMessagesRequest(
  request: CleanupRequest,
  language: ResolvedLanguage,
  options: Pick<CleanupOptions, "model" | "effort">,
): Anthropic.MessageCreateParamsNonStreaming {
  const target = request.targetLanguage;
  return {
    model: options.model,
    // Includes thinking, when the model thinks; a 20,000-character transcript needs most of it.
    max_tokens: 16000,
    ...claudeThinking(options.model, options.effort ?? DEFAULT_EFFORT),
    system: buildInstructionParts(request, language).map((text) => ({
      type: "text" as const,
      text,
      cache_control: { type: "ephemeral" as const },
    })),
    messages: [{
      role: "user",
      content: target ? buildTranslationMessage(request.transcript, target) : buildTranscriptMessage(request.transcript),
    }],
  };
}

async function runClaude(request: CleanupRequest, options: CleanupOptions): Promise<CleanupOutcome> {
  const language = resolveLanguage(request.language);
  const started = performance.now();
  // One retry (429, 5xx, connection) if the deadline leaves room for it.
  const client = new Anthropic({
    apiKey: options.apiKey,
    fetch: options.fetcher,
    maxRetries: 1,
    timeout: options.deadlineMs,
  });
  let message: Anthropic.Message;
  try {
    message = await client.messages.create(buildMessagesRequest(request, language, options), {
      signal: options.signal ?? AbortSignal.timeout(options.deadlineMs),
    });
  } catch (error) {
    // As for OpenAI, an HTTP error keeps only its status and type: the SDK's message carries the body.
    if (error instanceof Anthropic.APIError && error.status !== undefined) {
      const body = error.error as { error?: { type?: string } } | undefined;
      throw new CleanupAPIError(error.status, body?.error?.type ?? null, "anthropic");
    }
    throw error;
  }
  const totalMs = Math.round(performance.now() - started);
  const cacheRead = message.usage.cache_read_input_tokens ?? 0;
  const cacheWrite = message.usage.cache_creation_input_tokens ?? 0;
  const base = {
    model: message.model,
    language: language.key,
    stopReason: message.stop_reason,
    ttftMs: null,
    totalMs,
    usage: {
      // Every input token, as OpenAI counts them: Anthropic's input_tokens leaves out the cached ones.
      input: message.usage.input_tokens + cacheRead + cacheWrite,
      output: message.usage.output_tokens,
      cacheRead,
      cacheWrite,
    },
    cacheReadTokens: cacheRead,
  };

  // A refusal has no usable text (Claude Haiku 5.5 has no refusal fallback); a truncated reply is incomplete.
  if (message.stop_reason === "refusal" || message.stop_reason === "max_tokens") {
    return { ...base, text: request.transcript, status: "raw", reason: message.stop_reason };
  }
  const text = message.content.flatMap((block) => block.type === "text" ? [block.text] : []).join("");
  return judged(request, language, base, text);
}

/** Either provider's reply text through the output guards: one that fails them keeps the transcript. */
function judged(
  request: CleanupRequest,
  language: ResolvedLanguage,
  base: Omit<CleanupOutcome, "text" | "status" | "reason">,
  reply: string,
): CleanupOutcome {
  const text = tidyOutput(reply);
  const guard = request.targetLanguage
    ? guardTranslation(request.transcript, text, { source: language.tag, target: request.targetLanguage })
    : guardOutput(request.transcript, text, language.tag ?? "en");
  if (!guard.ok) {
    return { ...base, text: request.transcript, status: "raw", reason: guard.reason };
  }
  return { ...base, text, status: "cleaned" };
}

/**
 * A warm-up's free model lookup: it opens the isolate's connection to Anthropic, and a
 * misconfigured model shows in the log before a dictation needs it. True once Anthropic answered.
 */
export async function pingClaude(
  model: string,
  options: { apiKey: string; signal: AbortSignal; fetcher?: typeof fetch },
): Promise<boolean> {
  try {
    const client = new Anthropic({ apiKey: options.apiKey, fetch: options.fetcher, maxRetries: 0 });
    await client.models.retrieve(model, undefined, { signal: options.signal });
    return true;
  } catch (error) {
    if (error instanceof Anthropic.APIError && error.status !== undefined) {
      console.error(`warm-up: Anthropic answered ${error.status} for the model ${model}`);
      return true;
    }
    console.error("warm-up: Anthropic unreachable", error instanceof Error ? error.name : String(error));
    return false;
  }
}

/** A call its deadline cut off: fetch's abort (OpenAI), or the SDK's abort or timeout (Anthropic). */
export function isCleanupDeadline(error: unknown): boolean {
  return (error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError")) ||
    error instanceof Anthropic.APIUserAbortError ||
    error instanceof Anthropic.APIConnectionTimeoutError;
}

/**
 * Log label for a failed call. Every failure maps to HTTP 502 for the app (which then inserts its
 * locally formatted text); the label is what the serve log shows. The SDK's timeout is a
 * connection error too, so the deadline is checked first.
 */
export function describeCleanupError(error: unknown): string {
  if (isCleanupDeadline(error)) return "cleanup deadline";
  if (error instanceof CleanupAPIError) {
    return error.status === 429 ? `${error.provider} rate limited` : `${error.provider} error ${error.status}`;
  }
  if (error instanceof Anthropic.APIConnectionError) return "anthropic connection";
  if (error instanceof TypeError) return "openai connection";
  return "cleanup failed";
}

/** Why a failed call left a dictation without its text, for `dictate`'s reply. */
export function failureReason(
  error: unknown,
): "deadline" | "openai_connection" | "openai_error" | "anthropic_connection" | "anthropic_error" {
  if (isCleanupDeadline(error)) return "deadline";
  if (error instanceof CleanupAPIError) return `${error.provider}_error`;
  if (error instanceof Anthropic.APIConnectionError) return "anthropic_connection";
  if (error instanceof TypeError) return "openai_connection";
  return "openai_error";
}
