// The `transcribe` function's handler; the contract is in transcribe/index.ts. What it talks to
// is injected (`TranscribeDeps`), so the Supabase function and the dictation server serve the same
// code, and the tests drive it offline.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { audioDurationMs } from "./audio_duration.ts";
import type { TranscribeConfig } from "./config.ts";
import { type CostCall, vouchedDictationId } from "./cost.ts";
import { type Caller, clientInfo, corsHeaders, json } from "./http.ts";
import { beginRequest, Phases, type RequestStart } from "./timing.ts";
import { OpenAIError, parseTranscribeRequest, transcribeWithOpenAI, transcriptUsage } from "./transcribe.ts";

const PER_MINUTE = 40;
const ANONYMOUS_PER_MINUTE = 10;

interface Quota {
  plan: string;
  remaining: number | null;
}

export interface TranscribeDeps {
  /** The service-role client: `consume_bucket`, `quota_status` and `record_usage`. */
  admin: Pick<SupabaseClient, "rpc">;
  /** The model, and the deadline of the whole OpenAI call: below the app's request timeout (25 s). */
  config: TranscribeConfig;
  /** OPENAI_API_KEY. Without it, a request that passes the checks gets 503. */
  apiKey: string | undefined;
  /** Kill switch (TRANSCRIBE_DISABLED=1): answers 503 before any database or model call. */
  disabled: boolean;
  /**
   * TRANSCRIBE_FAIL_CLOSED=1: a limit or quota check that can't run answers 503. Off, as it always
   * was, the dictation goes through unchecked while the database is out.
   */
  failClosed?: boolean;
  /** The caller of the bearer token, or null (401). */
  authenticate(request: Request): Promise<Caller | null>;
  /** `record_cost`, handed to `background` (`_shared/cost.ts`). Left out, nothing is recorded. */
  recordCost?(caller: Caller, dictationId: string | null, calls: CostCall[]): PromiseLike<unknown>;
  /** Runs work after the reply is sent. */
  background(work: PromiseLike<unknown>): void;
  /** Replaces `fetch` for the OpenAI call. */
  fetcher?: typeof fetch;
  /** Counts the request against the worker (`beginRequest`). */
  worker?: () => RequestStart;
  /** Where a request's one JSON log line goes (console.log). */
  log?: (line: string) => void;
}

export function createTranscribeHandler(deps: TranscribeDeps): (request: Request) => Promise<Response> {
  const { admin, apiKey, disabled } = deps;
  const { model, deadlineMs } = deps.config;
  const fetcher = deps.fetcher ?? fetch;
  const begin = deps.worker ?? (() => beginRequest());
  const log = deps.log ?? ((line: string) => console.log(line));

  return async (request) => {
    const worker = begin();
    const phases = new Phases(worker);
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    if (disabled) return json({ error: "transcription_unavailable" }, 503);

    const caller = await phases.mark("authMs", deps.authenticate(request));
    if (!caller) return json({ error: "unauthorized" }, 401);

    const parsed = parseTranscribeRequest(await phases.mark("bodyMs", request.json().catch(() => null)));
    if (!parsed.ok) return json({ error: "bad_request", detail: parsed.error }, 400);
    const body = parsed.value;

    const { data: withinLimit, error: limitError } = await phases.mark("preflightMs", admin.rpc("consume_bucket", {
      p_key: `transcribe:${caller.userId}`,
      p_limit: caller.isAnonymous ? ANONYMOUS_PER_MINUTE : PER_MINUTE,
      p_window_seconds: 60,
    }));
    if (limitError) {
      console.error("rate limit check failed", limitError);
      if (deps.failClosed) return json({ error: "transcription_unavailable" }, 503);
    } else if (withinLimit !== true) return json({ error: "rate_limited" }, 429);

    // Once the free plan's weekly words are used up, stop paying for transcription.
    const { data: quota, error: quotaError } = await phases.mark("preflightMs", admin
      .rpc("quota_status", { p_user: caller.userId })
      .single<Quota>());
    if (quotaError) {
      console.error("quota check failed", quotaError);
      if (deps.failClosed) return json({ error: "transcription_unavailable" }, 503);
    } else if (quota && quota.remaining !== null && quota.remaining <= 0) {
      return json({ error: "limit_reached" }, 402);
    }

    if (!apiKey) {
      console.error("OPENAI_API_KEY is not set");
      return json({ error: "transcription_unavailable" }, 503);
    }

    phases.ready();
    const started = Date.now();
    try {
      const result = await phases.mark("transcribeMs", transcribeWithOpenAI(body, { apiKey, model, deadlineMs, fetcher }));
      const totalMs = Date.now() - started;
      const dictationHeader = request.headers.get("x-murmur-dictation");
      const usage = transcriptUsage(body, dictationHeader, result);
      if (usage) {
        deps.background(admin.rpc("record_usage", {
          p_user: caller.userId,
          p_dictation: usage.dictationId,
          p_words: usage.words,
        }));
      }
      if (deps.recordCost) {
        // What the transcription cost, by the audio's length, whether or not its words were counted.
        deps.background(deps.recordCost(caller, vouchedDictationId(body.dictationId, dictationHeader), [{
          kind: "speech",
          path: "upload",
          plan: quota?.plan ?? null,
          provider: "openai",
          model,
          audioMs: audioDurationMs(body.audio, body.format),
        }]));
      }
      const words = usage?.words ?? 0;
      const left = quota?.remaining ?? null;
      const timings = phases.toJSON();
      log(JSON.stringify({
        event: "transcribe",
        model,
        format: body.format,
        bytes: body.audio.length,
        language: body.language,
        detected: result.languages,
        keywords: body.keywords.length,
        outChars: result.text.length,
        outWords: words,
        isAnonymous: caller.isAnonymous,
        totalMs,
        ...worker,
        client: clientInfo(request),
        timings,
      }));
      return json({
        text: result.text,
        languages: result.languages,
        model,
        words,
        remaining: left === null ? null : Math.max(0, left - words),
        totalMs,
        timings,
      });
    } catch (error) {
      if (error instanceof OpenAIError) console.error(error.message);
      else console.error("transcription failed", error instanceof Error ? error.name : String(error));
      return json({ error: "transcription_unavailable" }, 502);
    }
  };
}
