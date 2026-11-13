// The `cleanup` function's handler; the contract is in cleanup/index.ts. What it talks to is
// injected (`CleanupDeps`), so the Supabase function and the dictation server serve the same code,
// and the tests drive it offline.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { apiKeyName, countedWords, describeCleanupError, runCleanup } from "./cleanup.ts";
import type { ModelConfig } from "./config.ts";
import { type CostCall, textCall } from "./cost.ts";
import { type Caller, clientInfo, corsHeaders, json } from "./http.ts";
import { countWords } from "./text.ts";
import { beginRequest, Phases, type RequestStart } from "./timing.ts";
import { LIMITS, parseCleanupRequest } from "./types.ts";

/** Anonymous (trial) callers get a tighter per-minute limit; signed-in users keep the SQL default (40). */
const ANONYMOUS_PER_MINUTE = 10;

interface Preflight {
  allowed: boolean;
  reason: "rate_limited" | "limit_reached" | null;
  plan: string;
  remaining: number | null;
}

export interface CleanupDeps {
  /** The service-role client: `cleanup_preflight` and `record_usage`. */
  admin: Pick<SupabaseClient, "rpc">;
  /** A cleanup's model, effort and deadline: a hard bound on the whole call, below the app's timeout (11 s). */
  cleanup: ModelConfig;
  /** A translation's; with no TRANSLATE_* secret set, the cleanup settings, as it always was. */
  translation: ModelConfig;
  /** Kill switch (CLEANUP_DISABLED=1): answers 503 before any database or model call. */
  disabled: boolean;
  /** The secret of that name: OPENAI_API_KEY, or ANTHROPIC_API_KEY for a Claude model. */
  key(name: string): string | undefined;
  /** The caller of the bearer token, or null (401). */
  authenticate(request: Request): Promise<Caller | null>;
  /** `record_cost`, handed to `background` (`_shared/cost.ts`). Left out, nothing is recorded. */
  recordCost?(caller: Caller, dictationId: string, calls: CostCall[]): PromiseLike<unknown>;
  /** Runs work after the reply is sent. */
  background(work: PromiseLike<unknown>): void;
  /** Replaces `fetch` for the model call. */
  fetcher?: typeof fetch;
  /** Counts the request against the worker (`beginRequest`). */
  worker?: () => RequestStart;
  /** Where a request's one JSON log line goes (console.log). */
  log?: (line: string) => void;
}

export function createCleanupHandler(deps: CleanupDeps): (request: Request) => Promise<Response> {
  const { admin, disabled } = deps;
  const fetcher = deps.fetcher ?? fetch;
  const begin = deps.worker ?? (() => beginRequest());
  const log = deps.log ?? ((line: string) => console.log(line));

  return async (request) => {
    const worker = begin();
    const phases = new Phases(worker);
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    if (disabled) return json({ error: "cleanup_unavailable" }, 503);

    const caller = await phases.mark("authMs", deps.authenticate(request));
    if (!caller) return json({ error: "unauthorized" }, 401);

    const parsed = parseCleanupRequest(await phases.mark("bodyMs", request.json().catch(() => null)));
    if (!parsed.ok) return json({ error: "bad_request", detail: parsed.error }, 400);
    const body = parsed.value;
    if (caller.isAnonymous && body.transcript.length > LIMITS.anonymousTranscriptChars) {
      return json({ error: "bad_request", detail: "transcript too long" }, 400);
    }

    const { data: preflight, error: preflightError } = await phases.mark("preflightMs", admin
      .rpc(
        "cleanup_preflight",
        caller.isAnonymous
          ? { p_user: caller.userId, p_per_minute: ANONYMOUS_PER_MINUTE }
          : { p_user: caller.userId },
      )
      .single<Preflight>());
    if (preflightError || !preflight) {
      console.error("preflight failed", preflightError);
      return json({ error: "cleanup_unavailable" }, 503);
    }
    if (!preflight.allowed) {
      return json({ error: preflight.reason }, preflight.reason === "rate_limited" ? 429 : 402);
    }

    const transcriptWords = countWords(body.transcript, body.language);
    if (transcriptWords === 0) {
      return json({
        text: "",
        status: "raw",
        reason: "empty",
        targetLanguage: body.targetLanguage ?? null,
        words: 0,
        model: null,
        ttftMs: null,
        totalMs: 0,
        remaining: preflight.remaining,
        timings: phases.toJSON(),
      });
    }

    // With no TRANSLATE_* secret set, a translation runs with the cleanup settings, as it always has.
    const { model, effort, deadlineMs } = body.targetLanguage ? deps.translation : deps.cleanup;
    // Without the model's key, answer like an outage: the app inserts its locally formatted text.
    const keyName = apiKeyName(model);
    const apiKey = deps.key(keyName);
    if (!apiKey) {
      console.error(`${keyName} is not set`);
      return json({ error: "cleanup_unavailable" }, 503);
    }
    phases.ready();
    try {
      const outcome = await phases.mark("modelMs", runCleanup(body, { model, effort, apiKey, deadlineMs, fetcher }));
      // What the app inserts: a raw translation is nothing, so it isn't counted.
      const counted = countedWords(outcome, body);
      const words = counted ?? 0;
      if (counted !== null) {
        deps.background(admin.rpc("record_usage", {
          p_user: caller.userId,
          p_dictation: body.dictationId,
          p_words: counted,
        }));
      }
      if (deps.recordCost) {
        // What the model call cost, by its tokens.
        deps.background(
          deps.recordCost(caller, body.dictationId, [textCall(outcome, { path: "upload", plan: preflight.plan }, model)]),
        );
      }
      const timings = phases.toJSON();
      log(JSON.stringify({
        event: "cleanup",
        status: outcome.status,
        reason: outcome.reason,
        model: outcome.model,
        language: outcome.language,
        languageTag: body.language ?? null,
        targetLanguageTag: body.targetLanguage ?? null,
        style: body.style ?? "verbatim",
        isAnonymous: caller.isAnonymous,
        stopReason: outcome.stopReason,
        ttftMs: outcome.ttftMs,
        totalMs: outcome.totalMs,
        inChars: body.transcript.length,
        inWords: transcriptWords,
        outWords: words,
        inputTokens: outcome.usage.input,
        outputTokens: outcome.usage.output,
        cachedTokens: outcome.usage.cacheRead,
        cacheWriteTokens: outcome.usage.cacheWrite,
        ...worker,
        client: clientInfo(request),
        timings,
      }));
      return json({
        text: outcome.text,
        status: outcome.status,
        reason: outcome.reason ?? null,
        targetLanguage: body.targetLanguage ?? null,
        words,
        model: outcome.model,
        ttftMs: outcome.ttftMs,
        totalMs: outcome.totalMs,
        remaining: preflight.remaining === null ? null : Math.max(0, preflight.remaining - words),
        timings,
      });
    } catch (error) {
      const label = describeCleanupError(error);
      if (label === "cleanup failed") console.error(label, error instanceof Error ? error.name : String(error));
      else console.error(label, error instanceof Error ? error.message : String(error));
      return json({ error: "cleanup_unavailable" }, 502);
    }
  };
}
