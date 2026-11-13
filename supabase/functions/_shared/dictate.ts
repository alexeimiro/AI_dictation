// The `dictate` function's handler; the contract is in dictate/index.ts. Audio mode transcribes and
// then translates it, or writes it in a style, on one worker (Word for word stops at the
// transcript); text mode translates a transcript the app
// already has, and warm mode
// opens the connections a dictation needs while the user is still speaking. Everything the handler
// talks to is injected (`DictateDeps`), so the tests drive it offline.
import { audioDurationMs } from "./audio_duration.ts";
import {
  apiKeyName,
  type CleanupOutcome,
  describeCleanupError,
  failureReason,
  isClaudeModel,
  pingClaude,
  runCleanup,
} from "./cleanup.ts";
import type { DictateConfig } from "./config.ts";
import { type CostCall, textCall } from "./cost.ts";
import { type Caller, clientInfo, corsHeaders, json } from "./http.ts";
import type { Preflight } from "./preflight.ts";
import { countWords, primarySubtag } from "./text.ts";
import { beginRequest, Phases, type RequestStart, type ServerTimings } from "./timing.ts";
import {
  cleanKeywords,
  cleanLanguageHints,
  isoLanguage,
  OpenAIError,
  TRANSCRIBE_LIMITS,
  type TranscribeRequest,
  type TranscriptionResult,
  transcribeWithOpenAI,
  transcriptUsage,
} from "./transcribe.ts";
import {
  type CleanupRequest,
  LIMITS,
  normalizeLanguageTag,
  type Parsed,
  parseCleanupRequest,
  UUID_PATTERN,
  writesWithModel,
} from "./types.ts";

/** A translation request: `cleanup`'s body, with the target it must have here. */
export type TranslationRequest = CleanupRequest & { targetLanguage: string };

/**
 * Audio mode: what the model writes from the transcript, as `cleanup` takes it (its transcript
 * still to come): a translation, or with no target a style the model writes. And the transcription as
 * `transcribe` takes it.
 */
export interface AudioBody {
  mode: "audio";
  translation: CleanupRequest;
  transcription: TranscribeRequest;
  /** Word for word with no target: nothing for the model to write, so the reply is the transcript alone. */
  transcribeOnly: boolean;
}

/** Text mode: a translation, with the app's labels for its speculative calls, which are only logged. */
export interface TextBody {
  mode: "text";
  translation: TranslationRequest;
  speculative: boolean;
  attempt: number | null;
}

export type DictateBody = AudioBody | TextBody;

export interface DictateDeps {
  config: DictateConfig;
  /** OPENAI_API_KEY. Without it, a request that passes the checks gets 503 and a warm-up skips OpenAI. */
  apiKey: string | undefined;
  /**
   * ANTHROPIC_API_KEY, for a `claude-` translation or cleanup model. Without it, a request that
   * needs that model gets 503 and a warm-up skips Anthropic.
   */
  anthropicApiKey: string | undefined;
  /** The caller of the bearer token, or null (401). */
  authenticate(request: Request): Promise<Caller | null>;
  /** `dictation_preflight` in the scope and for the dictation `preflightFor` picks; throws when the RPC fails (503). */
  preflight(caller: Caller, scope: PreflightScope, dictationId: string | null, perMinute: number): Promise<Preflight>;
  /** Warm mode's read-only `quota_status`. */
  readQuota(caller: Caller, signal: AbortSignal): Promise<void>;
  /** `record_usage`, handed to `background`. */
  recordUsage(caller: Caller, dictationId: string, words: number): PromiseLike<unknown>;
  /**
   * `record_cost`, handed to `background`: the transcription and the model call a reply was made
   * of (`_shared/cost.ts`). Left out, nothing is recorded.
   */
  recordCost?(caller: Caller, dictationId: string, calls: CostCall[]): PromiseLike<unknown>;
  /** Runs work after the reply is sent. */
  background(work: PromiseLike<unknown>): void;
  /** Replaces `fetch` for the OpenAI and Anthropic calls. */
  fetcher?: typeof fetch;
  /** The handler's clock in ms (`performance.now`): the phases, the audio budget and the warm memo. */
  now?: () => number;
  /**
   * The signal of an OpenAI call bounded by `ms`. Given the request, it also fires when the phone
   * hangs up, wherever the runtime passes that on: the local edge runtime (1.77.4) never does and
   * hosted is unchecked, so a dictation the app gives up on may run to its deadlines. Warm-ups pass
   * no request: they finish whether or not the caller waits. Tests pass signals that never fire.
   */
  signal?(ms: number, request?: Request): AbortSignal;
  /** Counts the request against the worker (`beginRequest`). */
  worker?: () => RequestStart;
  /** Where a request's one JSON log line goes (console.log). */
  log?: (line: string) => void;
}

/**
 * The whole body, audio included. Raw bytes keep the audio within `transcribe`'s 16 MB; a bigger
 * body is refused from its Content-Length before any of it is read, or cut off once it passes the
 * limit when it has none.
 */
const MAX_BODY_BYTES = TRANSCRIBE_LIMITS.maxAudioBytes;
/** Audio mode skips the model call when less than this is left of its budget. */
const MIN_MODEL_MS = 1000;
/** Without a translation, a dictation of this many words or fewer stays as it was heard, as in the app. */
const SHORT_WORDS = 3;
/** Each warm-up fetch is bounded by this, below the app's 5 s warm-up timeout. */
const WARM_FETCH_MS = 3000;
/** A warm-up round trip stays warm this long for the isolate, so the next warm-ups skip it. */
const WARM_MEMO_MS = 60_000;

/** The reply to each reason the preflight refuses a call for. */
const REFUSALS: Record<NonNullable<Preflight["reason"]>, number> = {
  too_many_attempts: 429,
  rate_limited: 429,
  limit_reached: 402,
};

type Settled<T> = { ok: true; value: T } | { ok: false; error: unknown };

/** A promise that never rejects, so work can start early and be judged later. */
function settle<T>(work: Promise<T>): Promise<Settled<T>> {
  return work.then((value) => ({ ok: true, value }), (error) => ({ ok: false, error }));
}

/**
 * Audio mode's "metadata" part: { dictationId, format: "m4a" | "wav", language: BCP-47 | null,
 * languages?, keywords?, targetLanguage?, style?, dictionary?, snippets? }, with a targetLanguage unless the
 * style is named: one the model writes, or "verbatim", which only transcribes. `cleanup`'s and
 * `transcribe`'s own validators check it; `audio` is the "audio" part's bytes.
 */
export function parseDictateMetadata(raw: unknown, audio: Uint8Array<ArrayBuffer>): Parsed<AudioBody> {
  if (typeof raw !== "object" || raw === null) return { ok: false, error: "metadata must be a JSON object" };
  const fields = raw as Record<string, unknown>;
  // The transcript comes from the audio; everything else is checked as `cleanup` checks it.
  const parsed = parseCleanupRequest({ ...fields, transcript: "" });
  if (!parsed.ok) return parsed;
  const translation = parsed.value;
  // Without a target the style says what becomes of the transcript, so it must be named. A request
  // that names neither is refused, as it always was.
  if (!translation.targetLanguage && translation.style === undefined) {
    return { ok: false, error: "targetLanguage is required" };
  }
  // Word for word has nothing for the model to write: the transcript is the whole reply.
  const transcribeOnly = !translation.targetLanguage && !writesWithModel(translation.style);
  if (fields.format !== "m4a" && fields.format !== "wav") return { ok: false, error: "format must be m4a or wav" };
  if (audio.length === 0) return { ok: false, error: "audio is empty" };
  if (audio.length > TRANSCRIBE_LIMITS.maxAudioBytes) return { ok: false, error: "audio too large" };
  return {
    ok: true,
    value: {
      mode: "audio",
      translation,
      transcription: {
        dictationId: translation.dictationId,
        audio,
        format: fields.format,
        // What `parseTranscribeRequest` makes of the same tag: ISO-639-1, or null to detect it.
        language: isoLanguage(translation.language),
        languageHints: cleanLanguageHints(fields.languages),
        keywords: cleanKeywords(fields.keywords),
      },
      transcribeOnly,
    },
  };
}

/** Text mode's JSON body: a `cleanup` request with a targetLanguage, plus speculative? and attempt?. */
export function parseDictateText(raw: unknown): Parsed<TextBody> {
  const parsed = parseCleanupRequest(raw);
  if (!parsed.ok) return parsed;
  const translation = withTarget(parsed.value);
  if (!translation) return { ok: false, error: "targetLanguage is required" };
  const fields = raw as Record<string, unknown>;
  const speculative = fields.speculative ?? false;
  if (typeof speculative !== "boolean") return { ok: false, error: "speculative must be a boolean" };
  const attempt = fields.attempt ?? null;
  if (attempt !== null && !isPositiveInteger(attempt)) return { ok: false, error: "attempt must be a positive integer" };
  return { ok: true, value: { mode: "text", translation, speculative, attempt } };
}

/** The request with its target language, or null without one ("und" is none: see `parseCleanupRequest`). */
function withTarget(request: CleanupRequest): TranslationRequest | null {
  const { targetLanguage } = request;
  return targetLanguage ? { ...request, targetLanguage } : null;
}

function isPositiveInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1;
}

/** The scopes `dictate` checks its calls in. */
export type PreflightScope = "dictate" | "transcribe";

/**
 * Where a call is checked. A text call shares its dictation's attempts in `dictate`'s scope: only
 * the dictation's first takes from the minute bucket, so speculative translations don't drain it.
 * An audio call takes from `transcribe`'s bucket every time, as a legacy transcription does, so
 * the two functions together transcribe no more for an account than `transcribe` alone would.
 */
function preflightFor(mode: DictateBody["mode"], dictationId: string): { scope: PreflightScope; dictationId: string | null } {
  return mode === "audio" ? { scope: "transcribe", dictationId: null } : { scope: "dictate", dictationId };
}

/** The mode a Content-Type selects, or null for any other type. */
function modeOf(contentType: string | null): DictateBody["mode"] | null {
  const type = contentType?.split(";")[0].trim().toLowerCase();
  return type === "multipart/form-data" ? "audio" : type === "application/json" ? "text" : null;
}

class BodyTooLarge extends RangeError {}

/** The request body behind a byte limit: past MAX_BODY_BYTES its stream errors with BodyTooLarge. */
function limitedBody(request: Request): Response {
  let received = 0;
  const body = request.body?.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        received += chunk.byteLength;
        if (received > MAX_BODY_BYTES) controller.error(new BodyTooLarge("body too large"));
        else controller.enqueue(chunk);
      },
    }),
  );
  return new Response(body ?? null, { headers: { "content-type": request.headers.get("content-type") ?? "" } });
}

/** Reads and checks an audio- or text-mode body. It never throws: anything wrong is a 400's detail. */
async function readBody(request: Request, mode: DictateBody["mode"]): Promise<Parsed<DictateBody>> {
  const body = limitedBody(request);
  try {
    if (mode === "text") return parseDictateText(await body.json());
    const form = await body.formData();
    const metadata = form.get("metadata");
    const audio = form.get("audio");
    if (metadata === null) return { ok: false, error: "metadata part is missing" };
    if (audio === null) return { ok: false, error: "audio part is missing" };
    if (typeof audio === "string") return { ok: false, error: "audio must be a file part" };
    let raw: unknown;
    try {
      // A part without a filename arrives as a string, one with a filename as a file.
      raw = JSON.parse(typeof metadata === "string" ? metadata : await metadata.text());
    } catch {
      return { ok: false, error: "metadata must be JSON" };
    }
    return parseDictateMetadata(raw, new Uint8Array(await audio.arrayBuffer()));
  } catch (error) {
    if (error instanceof BodyTooLarge) return { ok: false, error: "body too large" };
    return {
      ok: false,
      error: mode === "text" ? "body must be a JSON object" : "body must be multipart/form-data with metadata and audio parts",
    };
  }
}

/** The first language the transcription heard, sanitized like a client tag before it reaches the prompt. */
function detectedLanguage(languages: string[]): string | undefined {
  const tag = normalizeLanguageTag(languages[0]);
  return tag.ok ? tag.tag : undefined;
}

/** The longest transcript a caller may have translated, as `cleanup` allows it. */
function transcriptLimit(caller: Caller): number {
  return caller.isAnonymous ? LIMITS.anonymousTranscriptChars : LIMITS.transcriptChars;
}

function isAbort(error: unknown): boolean {
  return error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError");
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : String(error);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Log label for a failed transcription, like `describeCleanupError`'s for the model call. */
function describeTranscriptionError(error: unknown, request: Request): string {
  if (request.signal.aborted) return "client disconnected";
  if (isAbort(error)) return "transcription deadline";
  if (error instanceof OpenAIError) return error.status === 429 ? "openai rate limited" : `openai error ${error.status}`;
  if (error instanceof TypeError) return "openai connection";
  return "transcription failed";
}

function badRequest(detail: string): Response {
  return json({ error: "bad_request", detail }, 400);
}

/** A failure on the server's side, which the app treats like an outage: 503. */
function unavailable(): Response {
  return json({ error: "dictate_unavailable" }, 503);
}

/** A request that passed every check: what its reply and log line are built from. */
interface Dictation {
  request: Request;
  worker: RequestStart;
  phases: Phases;
  /** The handler's start, on its clock. */
  startedAt: number;
  caller: Caller;
  body: DictateBody;
  preflight: Preflight;
  /** What the model is asked. In audio mode it gets the transcript, and the detected source if automatic. */
  translation: CleanupRequest;
  /** Audio mode, once transcribed. */
  heard?: TranscriptionResult;
}

/** What a dictation's translation came to. */
interface Translated {
  status: "cleaned" | "raw" | "unavailable";
  reason: string | null;
  /** The text to insert; "" unless cleaned. */
  text: string;
  /** The words recorded against the quota, or null when nothing is recorded. */
  usage: number | null;
  /** The model's answer, when it gave one. */
  outcome: CleanupOutcome | null;
}

/** An empty transcript: nothing to translate and nothing to count, as in `cleanup`. */
const EMPTY: Translated = { status: "raw", reason: "empty", text: "", usage: null, outcome: null };

function unavailableResult(reason: string): Translated {
  return { status: "unavailable", reason, text: "", usage: null, outcome: null };
}

/**
 * The model's answer, or the transcript it kept as "raw" when the output was unusable. `written`:
 * the language the output is in (the target, else the spoken language).
 */
function translated(outcome: CleanupOutcome, written: string | undefined): Translated {
  return {
    status: outcome.status,
    reason: outcome.reason ?? null,
    text: outcome.status === "cleaned" ? outcome.text : "",
    // What `cleanup` counts: the output, or the transcript it fell back to.
    usage: countWords(outcome.text, written),
    outcome,
  };
}

export function createDictateHandler(deps: DictateDeps): (request: Request) => Promise<Response> {
  const { config, apiKey, anthropicApiKey } = deps;
  const now = deps.now ?? (() => performance.now());
  const fetcher = deps.fetcher ?? fetch;
  const begin = deps.worker ?? (() => beginRequest());
  const log = deps.log ?? ((line: string) => console.log(line));
  const signal = deps.signal ??
    ((ms: number, request?: Request) =>
      request ? AbortSignal.any([request.signal, AbortSignal.timeout(ms)]) : AbortSignal.timeout(ms));
  /** When this isolate last made each warm-up round trip. */
  const warmedAt = { openai: -Infinity, anthropic: -Infinity, database: -Infinity };
  /** The Claude model a dictation may call, which a warm-up looks up; none while both models are OpenAI's. */
  const claudeModel = [config.translation.model, config.cleanup.model].find(isClaudeModel);

  const perMinute = (caller: Caller) => caller.isAnonymous ? config.anonymousPerMinute : config.perMinute;
  /** A translation runs as `cleanup` translates; a style as it cleans up. */
  const modelConfig = (request: CleanupRequest) => request.targetLanguage ? config.translation : config.cleanup;
  /** The key of `model`'s provider. */
  const keyFor = (model: string) => isClaudeModel(model) ? anthropicApiKey : apiKey;

  /**
   * Everything before OpenAI. The token is checked from the headers; once it names a caller, the
   * preflight runs while the body is read, and the request is admitted only once all three are
   * through. A request without a caller never has its body read.
   */
  async function admit(
    request: Request,
    phases: Phases,
    auth: Promise<Settled<Caller | null>>,
  ): Promise<Response | Pick<Dictation, "caller" | "body" | "preflight">> {
    const dictationId = request.headers.get("x-murmur-dictation")?.trim() ?? "";
    const mode = modeOf(request.headers.get("content-type"));
    const headerError = !UUID_PATTERN.test(dictationId)
      ? "x-murmur-dictation must be the dictation's UUID"
      : !mode
      ? "content-type must be multipart/form-data (audio) or application/json (text)"
      : Number(request.headers.get("content-length")) > MAX_BODY_BYTES
      ? "body too large"
      : null;

    const caller = await auth;
    if (!caller.ok) {
      console.error("authentication failed", errorName(caller.error));
      return unavailable();
    }
    if (!caller.value) return json({ error: "unauthorized" }, 401);
    if (headerError || !mode) return badRequest(headerError ?? "bad request");
    const user = caller.value;

    const checks = preflightFor(mode, dictationId);
    const preflight = settle(
      phases.mark("preflightMs", deps.preflight(user, checks.scope, checks.dictationId, perMinute(user))),
    );
    const parsed = await phases.mark("bodyMs", readBody(request, mode));
    if (!parsed.ok) return badRequest(parsed.error);
    const { translation } = parsed.value;
    if (translation.dictationId.toLowerCase() !== dictationId.toLowerCase()) {
      return badRequest("dictationId must match x-murmur-dictation");
    }
    if (parsed.value.mode === "text" && translation.transcript.length > transcriptLimit(user)) {
      return badRequest("transcript too long");
    }

    // Fail closed, as `cleanup` does: without the checks nothing is spent.
    const checked = await preflight;
    if (!checked.ok) {
      console.error("preflight failed", errorMessage(checked.error));
      return unavailable();
    }
    const { allowed, reason } = checked.value;
    if (!allowed) {
      if (reason && Object.hasOwn(REFUSALS, reason)) return json({ error: reason }, REFUSALS[reason]);
      console.error("preflight refused without a known reason", reason);
      return unavailable();
    }
    return { caller: user, body: parsed.value, preflight: checked.value };
  }

  function noKey(name: string): Response {
    // Like an outage: the app falls back on the device (audio) or fails the translation (text).
    console.error(`${name} is not set`);
    return unavailable();
  }

  /** The one JSON log line of an admitted request. Never any text: only its shape and timings. */
  function writeLog(
    d: Dictation,
    status: string,
    reason: string | null,
    timings: ServerTimings,
    extra: Record<string, unknown> = {},
  ): void {
    const { body, translation, heard, preflight, caller } = d;
    // No model is asked for a dictation that stops at the transcript.
    const asked = body.mode === "audio" && body.transcribeOnly ? null : modelConfig(body.translation);
    log(JSON.stringify({
      event: "dictate",
      mode: body.mode,
      status,
      reason,
      model: asked?.model ?? null,
      effort: asked?.effort ?? null,
      transcribeModel: body.mode === "audio" ? config.transcribe.model : null,
      languageTag: body.translation.language ?? null,
      sourceTag: translation.language ?? null,
      targetLanguageTag: body.translation.targetLanguage ?? null,
      detected: heard?.languages ?? null,
      style: body.translation.style ?? "verbatim",
      speculative: body.mode === "text" && body.speculative,
      // The server's count of this dictation's calls, and the app's own number for a text call.
      attempt: preflight.attempt,
      clientAttempt: body.mode === "text" ? body.attempt : null,
      isAnonymous: caller.isAnonymous,
      format: body.mode === "audio" ? body.transcription.format : null,
      bytes: body.mode === "audio" ? body.transcription.audio.length : null,
      keywords: body.mode === "audio" ? body.transcription.keywords.length : null,
      inChars: body.mode === "text" || heard ? translation.transcript.length : null,
      ...extra,
      ...d.worker,
      client: clientInfo(d.request),
      timings,
    }));
  }

  /**
   * What a reply's calls are billed for: the transcription by its audio's length, and the model's
   * answer by its tokens. A model call that failed left no count to record.
   */
  function costCalls(d: Dictation, outcome: CleanupOutcome | null): CostCall[] {
    const { body, heard, preflight } = d;
    const shared = { path: "upload" as const, plan: preflight.plan };
    const calls: CostCall[] = [];
    if (body.mode === "audio" && heard) {
      calls.push({
        kind: "speech",
        ...shared,
        provider: "openai",
        model: config.transcribe.model,
        audioMs: audioDurationMs(body.transcription.audio, body.transcription.format),
      });
    }
    if (outcome) calls.push(textCall(outcome, shared, modelConfig(body.translation).model));
    return calls;
  }

  /** The 200 reply, `cleanup`'s fields plus the transcription's. Records the usage and writes the log line. */
  function reply(d: Dictation, result: Translated, extra: Record<string, unknown> = {}): Response {
    const { body, caller, preflight, heard, translation } = d;
    const { outcome } = result;
    if (result.usage !== null) {
      deps.background(deps.recordUsage(caller, body.translation.dictationId, result.usage));
    }
    if (deps.recordCost) {
      // Whatever the reply's status: an empty or unusable transcript was still transcribed.
      const calls = costCalls(d, outcome);
      if (calls.length > 0) deps.background(deps.recordCost(caller, body.translation.dictationId, calls));
    }
    const words = result.usage ?? 0;
    const timings = d.phases.toJSON();
    writeLog(d, result.status, result.reason, timings, {
      ...extra,
      replyModel: outcome?.model ?? null,
      language: outcome?.language ?? null,
      stopReason: outcome?.stopReason ?? null,
      ttftMs: outcome?.ttftMs ?? null,
      totalMs: outcome?.totalMs ?? null,
      inWords: countWords(translation.transcript, translation.language),
      outWords: words,
      inputTokens: outcome?.usage.input ?? null,
      outputTokens: outcome?.usage.output ?? null,
      cachedTokens: outcome?.usage.cacheRead ?? null,
      cacheWriteTokens: outcome?.usage.cacheWrite ?? null,
    });
    return json({
      transcript: heard?.text ?? null,
      languages: heard?.languages ?? [],
      transcribeModel: heard ? config.transcribe.model : null,
      text: result.text,
      status: result.status,
      reason: result.reason,
      targetLanguage: body.translation.targetLanguage ?? null,
      words,
      model: outcome?.model ?? null,
      ttftMs: outcome?.ttftMs ?? null,
      // As in `cleanup`: the model call alone; `timings` splits the whole request.
      totalMs: outcome?.totalMs ?? 0,
      remaining: preflight.remaining === null ? null : Math.max(0, preflight.remaining - words),
      timings,
    });
  }

  /**
   * Audio mode: transcribe, then translate or write in the style in what is left of the 26 s
   * budget (the app waits 30 s). Word for word ends at the transcript.
   */
  async function dictateAudio(d: Dictation & { body: AudioBody }): Promise<Response> {
    // Both keys before the transcription, so a missing one costs no audio upload to OpenAI.
    if (!apiKey) return noKey("OPENAI_API_KEY");
    const { request, phases, body } = d;
    const model = modelConfig(body.translation);
    // Null for Word for word: it asks no model, so it needs no model's key.
    const modelKey = body.transcribeOnly ? null : keyFor(model.model);
    if (modelKey === undefined) return noKey(apiKeyName(model.model));
    const transcribe = config.transcribe;
    phases.ready();
    try {
      d.heard = await phases.mark(
        "transcribeMs",
        transcribeWithOpenAI(body.transcription, {
          apiKey,
          model: transcribe.model,
          deadlineMs: transcribe.deadlineMs,
          signal: signal(transcribe.deadlineMs, request),
          fetcher,
        }),
      );
    } catch (error) {
      const label = describeTranscriptionError(error, request);
      console.error(label);
      writeLog(d, "transcription_unavailable", label, phases.toJSON());
      return json({ error: "transcription_unavailable" }, 502);
    }

    // With an automatic source (none, or "und" as the app's Auto-detect sends it), the language the
    // transcription heard first is the source: the prompt names it, and the guard checks the
    // output against it.
    const transcript = d.heard.text;
    const declared = body.translation.language;
    const automatic = !declared || primarySubtag(declared) === "und";
    d.translation = {
      ...body.translation,
      transcript,
      language: automatic ? detectedLanguage(d.heard.languages) ?? declared : declared,
    };
    // Words are counted in the language the output is written in.
    const written = body.translation.targetLanguage ?? d.translation.language;
    const words = countWords(transcript, d.translation.language);
    if (words === 0) return reply(d, EMPTY);
    if (modelKey === null) {
      // The transcript is the text, whatever its length, and is counted as `transcribe` counts it.
      const usage = transcriptUsage(body.transcription, request.headers.get("x-murmur-dictation"), d.heard)?.words ?? null;
      return reply(d, { status: "raw", reason: "transcribed", text: "", usage, outcome: null });
    }
    if (transcript.length > transcriptLimit(d.caller)) {
      // Longer than `cleanup` would take for this caller; the app keeps the transcript.
      const usage = countWords(transcript, written);
      return reply(d, { status: "raw", reason: "transcript_too_long", text: "", usage, outcome: null });
    }
    if (!body.translation.targetLanguage && words <= SHORT_WORDS) {
      return reply(d, { status: "raw", reason: "short", text: "", usage: words, outcome: null });
    }

    const budgetMs = Math.min(model.deadlineMs, config.deadlineMs - (now() - d.startedAt));
    if (budgetMs < MIN_MODEL_MS) return reply(d, unavailableResult("deadline"), { budgetMs });
    try {
      const outcome = await phases.mark(
        "modelMs",
        runCleanup(d.translation, {
          ...model,
          deadlineMs: budgetMs,
          apiKey: modelKey,
          signal: signal(budgetMs, request),
          fetcher,
        }),
      );
      return reply(d, translated(outcome, written), { budgetMs });
    } catch (error) {
      // The transcript is kept, so the app can retry the translation alone; nothing is counted.
      const label = describeCleanupError(error);
      console.error(label, errorName(error));
      return reply(d, unavailableResult(failureReason(error)), { budgetMs, error: label });
    }
  }

  /** Text mode: one translation within the translation deadline (9 s; the app waits 11 s). */
  async function dictateText(d: Dictation & { body: TextBody }): Promise<Response> {
    const { request, phases, translation, body } = d;
    if (countWords(translation.transcript, translation.language) === 0) return reply(d, EMPTY);
    const settings = config.translation;
    const modelKey = keyFor(settings.model);
    if (!modelKey) return noKey(apiKeyName(settings.model));
    phases.ready();
    try {
      const outcome = await phases.mark(
        "modelMs",
        runCleanup(translation, {
          ...settings,
          apiKey: modelKey,
          signal: signal(settings.deadlineMs, request),
          fetcher,
        }),
      );
      return reply(d, translated(outcome, body.translation.targetLanguage));
    } catch (error) {
      const label = describeCleanupError(error);
      if (label === "cleanup failed") console.error(label, errorName(error));
      else console.error(label, errorMessage(error));
      writeLog(d, "translation_unavailable", label, phases.toJSON());
      return json({ error: "translation_unavailable" }, 502);
    }
  }

  /**
   * Warm mode: the token, then OpenAI, Anthropic (with a Claude model configured) and the database,
   * each skipped while this isolate is warm.
   */
  async function warm(
    request: Request,
    worker: RequestStart,
    phases: Phases,
    auth: Promise<Settled<Caller | null>>,
  ): Promise<Response> {
    const caller = await auth;
    if (!caller.ok) {
      console.error("authentication failed", errorName(caller.error));
      return unavailable();
    }
    if (!caller.value) return json({ error: "unauthorized" }, 401);
    const user = caller.value;

    const [openai, anthropic, database] = await Promise.all([
      // Free: it opens TLS and HTTP/2 to OpenAI in the isolate's pool, and a misconfigured
      // translation model shows in the log before a dictation needs it.
      warmUp("openai", apiKey ? () => pingOpenAI(apiKey) : null),
      // The same for Anthropic, only when a Claude model is configured.
      claudeModel
        ? warmUp("anthropic", anthropicApiKey ? () => pingAnthropic(claudeModel, anthropicApiKey) : null)
        : null,
      // Read only: it opens the isolate's connection to the database API. No writes.
      warmUp("database", () => pingDatabase(user)),
    ]);
    const { authMs, totalMs } = phases.toJSON();
    const timings = {
      authMs,
      ...(openai.ms === undefined ? {} : { openaiMs: openai.ms }),
      ...(anthropic?.ms === undefined ? {} : { anthropicMs: anthropic.ms }),
      ...(database.ms === undefined ? {} : { dbMs: database.ms }),
      totalMs,
    };
    log(JSON.stringify({
      event: "dictate_warm",
      openai: openai.state,
      ...(anthropic ? { anthropic: anthropic.state } : {}),
      database: database.state,
      isAnonymous: user.isAnonymous,
      ...worker,
      client: clientInfo(request),
      timings,
    }));
    const { cold, region, workerAgeMs, executionId } = worker;
    return json({ warm: true, cold, region, workerAgeMs, executionId, timings });
  }

  /** Makes a warm-up round trip unless the isolate made it within the last minute, and times it. */
  async function warmUp(
    key: keyof typeof warmedAt,
    work: (() => Promise<boolean>) | null,
  ): Promise<{ state: "ok" | "failed" | "memoized" | "no_key"; ms?: number }> {
    if (!work) return { state: "no_key" };
    if (now() - warmedAt[key] < WARM_MEMO_MS) return { state: "memoized" };
    warmedAt[key] = now();
    const started = now();
    const ok = await work();
    // A round trip that didn't get through is tried again by the next warm-up.
    if (!ok) warmedAt[key] = -Infinity;
    return { state: ok ? "ok" : "failed", ms: Math.round(now() - started) };
  }

  // The pings' signals leave out the request: a caller hanging up would fail them, and a failed
  // round trip clears the memo, so each hung-up warm-up could make them again.
  async function pingOpenAI(key: string): Promise<boolean> {
    // With a Claude translation model, OpenAI still transcribes: its model is looked up instead.
    const model = isClaudeModel(config.translation.model) ? config.transcribe.model : config.translation.model;
    try {
      const response = await fetcher(`https://api.openai.com/v1/models/${encodeURIComponent(model)}`, {
        headers: { Authorization: `Bearer ${key}` },
        signal: signal(WARM_FETCH_MS),
      });
      // Read to the end, so the connection goes back to the pool.
      await response.arrayBuffer();
      if (!response.ok) console.error(`warm-up: OpenAI answered ${response.status} for the model ${model}`);
      return true;
    } catch (error) {
      console.error("warm-up: OpenAI unreachable", errorName(error));
      return false;
    }
  }

  function pingAnthropic(model: string, key: string): Promise<boolean> {
    return pingClaude(model, { apiKey: key, signal: signal(WARM_FETCH_MS), fetcher });
  }

  async function pingDatabase(caller: Caller): Promise<boolean> {
    try {
      await deps.readQuota(caller, signal(WARM_FETCH_MS));
      return true;
    } catch (error) {
      console.error("warm-up: quota_status failed", errorMessage(error));
      return false;
    }
  }

  return async (request) => {
    const worker = begin();
    const phases = new Phases(worker, now);
    const startedAt = now();
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    if (config.disabled) return json({ error: "dictate_disabled" }, 404);

    // Every mode starts with the token, from the headers alone.
    const auth = settle(phases.mark("authMs", deps.authenticate(request)));
    if (request.headers.get("x-murmur-warm") === "1") return await warm(request, worker, phases, auth);

    const admitted = await admit(request, phases, auth);
    if (admitted instanceof Response) return admitted;
    const { body } = admitted;
    const base = { request, worker, phases, startedAt, ...admitted, translation: body.translation };
    return body.mode === "audio" ? await dictateAudio({ ...base, body }) : await dictateText({ ...base, body });
  };
}
