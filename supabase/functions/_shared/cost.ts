// What a dictation cost to serve, for `record_cost` (the `dictation_costs` table): one entry per
// billable call, with what its bill is counted in. Counts only, never text or audio. Recording is
// best effort and runs after the reply: a failure here is logged and never reaches the dictation.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import type { CleanupOutcome } from "./cleanup.ts";
import type { Env } from "./config.ts";
import type { Caller } from "./http.ts";

/** 'upload': the recording sent after the user stopped. 'live': streamed while speaking. */
export type CostPath = "upload" | "live";

interface CallBase {
  path: CostPath;
  /** The caller's plan, where the check before the call said so. */
  plan?: string | null;
  provider: string;
  model: string;
  /** The backup answered because the first choice failed. */
  backup?: boolean;
}

/** A transcription: billed by the audio's length. Null when the file didn't say how long it is. */
export interface SpeechCall extends CallBase {
  kind: "speech";
  audioMs: number | null;
}

/** A model call that wrote text: billed by tokens. `inputTokens` is every input token, cached ones included. */
export interface TextCall extends CallBase {
  kind: "text";
  inputTokens: number;
  cachedTokens: number;
  cacheWriteTokens: number;
  outputTokens: number;
}

export type CostCall = SpeechCall | TextCall;

/** Whose bill a text model is on: the rule `isClaudeModel` (cleanup.ts) routes the call by. */
export function textProvider(model: string): string {
  return model.startsWith("claude-") ? "anthropic" : "openai";
}

/** The model's answer as a billable call. `asked` is the configured model, when the reply names none. */
export function textCall(
  outcome: Pick<CleanupOutcome, "model" | "usage">,
  shared: { path: CostPath; plan?: string | null },
  asked?: string,
): TextCall {
  const model = outcome.model || asked || "unknown";
  return {
    kind: "text",
    ...shared,
    provider: textProvider(model),
    model,
    inputTokens: outcome.usage.input,
    cachedTokens: outcome.usage.cacheRead,
    cacheWriteTokens: outcome.usage.cacheWrite,
    outputTokens: outcome.usage.output,
  };
}

/**
 * The dictation's own id when the request vouches for it with `x-murmur-dictation`, as
 * `transcriptUsage` requires; else null. Builds before the header sent a random id in the body.
 */
export function vouchedDictationId(dictationId: string | null, header: string | null): string | null {
  return dictationId && header?.trim().toLowerCase() === dictationId.toLowerCase() ? dictationId : null;
}

/** Which home of the code is serving: MURMUR_HOST, which only the dictation server sets. */
export function costHost(env: Env = Deno.env): string {
  return env.get("MURMUR_HOST")?.trim() || "supabase";
}

export type CostRecorder = (caller: Caller, dictationId: string | null, calls: CostCall[]) => Promise<void>;

/** How long recording is skipped after the database said it has no `record_cost` (not migrated yet). */
const MISSING_RETRY_MS = 10 * 60_000;
/** PostgREST's and Postgres's codes for a function that doesn't exist. */
const MISSING_CODES = new Set(["PGRST202", "42883"]);

/**
 * `record_cost` with this home's name on every call. Hand its promise to `background`. `admin` is
 * asked for on each call, so a function that makes its client lazily keeps doing so.
 */
export function createCostRecorder(
  admin: () => SupabaseClient,
  options: { host?: string; now?: () => number; warn?: (message: string) => void } = {},
): CostRecorder {
  const host = options.host ?? costHost();
  const now = options.now ?? (() => Date.now());
  const warn = options.warn ?? ((message: string) => console.error(message));
  let missingSince = -Infinity;

  return async (caller, dictationId, calls) => {
    if (calls.length === 0) return;
    // Deployed ahead of its migration: say so once, then leave the database alone for a while.
    if (now() - missingSince < MISSING_RETRY_MS) return;
    const { error } = await admin().rpc("record_cost", {
      p_user: caller.userId,
      p_dictation: dictationId,
      p_calls: calls.map((call) => ({ ...call, host })),
    });
    if (!error) return;
    if (error.code && MISSING_CODES.has(error.code)) {
      missingSince = now();
      warn("record_cost is not in the database yet: costs are not recorded");
      return;
    }
    throw new Error(`record_cost failed: ${error.code ?? "unknown"}`);
  };
}
