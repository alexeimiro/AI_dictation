// The `live` function's handler; the protocol is in live/index.ts. One WebSocket per dictation: the
// app streams its audio while the user speaks, and the relay passes it to a speech service through
// that service's adapter (live/adapter.ts), sends back the words as they settle and, at the end,
// the final text. Everything the handler talks to is injected (`LiveDeps`), so the tests drive it
// offline, with fake sockets and a clock of their own.
import type { CostCall } from "./cost.ts";
import { type Caller, clientInfo, json } from "./http.ts";
import type { LiveAdapter, LiveEvent, LiveFrame, LiveProvider, LiveTarget } from "./live/adapter.ts";
import { DEFAULT_SONIOX_MODEL } from "./live/soniox.ts";
import type { Preflight } from "./preflight.ts";
import { countWords } from "./text.ts";
import { beginRequest, type RequestStart } from "./timing.ts";
import { cleanKeywords, cleanLanguageHints, isoLanguage } from "./transcribe.ts";
import { normalizeLanguageTag, type Parsed, UUID_PATTERN } from "./types.ts";

/** The part of `Deno.env` the reader uses. */
export type Env = Pick<Deno.Env, "get">;

export interface LiveConfig {
  /** Kill switch: every request gets 503 live_unavailable, and the app uploads as before. */
  disabled: boolean;
  /** The speech service new sockets stream to. */
  provider: string;
  /** The longest a socket may last, however much of the worker's time is left. */
  maxSessionMs: number;
  /**
   * How long the platform lets a worker live from its boot, its open sockets included: 150 s on
   * Supabase's Free plan, 400 s on a paid one. Null where nothing ends the process by its age (the
   * dictation server): a socket's time is then `maxSessionMs` alone.
   */
  wallClockMs: number | null;
  /** With this key on its request, a bench run may choose the service for its socket (`?provider=`). */
  benchKey: string | undefined;
  /** Each service's key and model, by the service's name. */
  providers: Record<string, { apiKey: string | undefined; model: string }>;
  /** A caller's dictations a minute: only a dictation's first socket takes from the bucket. */
  perMinute: number;
  /** Anonymous (trial) callers get the tighter limit `transcribe` and `dictate` give them. */
  anonymousPerMinute: number;
}

/** A positive number from the env; unset, zero, negative or not a number gives `fallback`. */
function envNumber(env: Env, name: string, fallback: number): number {
  const value = Number(env.get(name));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

/**
 * `live`: LIVE_DISABLED=1, LIVE_PROVIDER (soniox), LIVE_MAX_SESSION_MS (140000), LIVE_WALL_CLOCK_MS
 * (150000; 0 for a server no platform ends by its age), LIVE_BENCH_KEY, and per service its key and
 * model: SONIOX_API_KEY, LIVE_SONIOX_MODEL (stt-rt-v6). Read here and not in config.ts, which would
 * load the model SDKs into this worker.
 */
export function liveConfig(env: Env = Deno.env): LiveConfig {
  return {
    disabled: env.get("LIVE_DISABLED") === "1",
    provider: env.get("LIVE_PROVIDER")?.trim().toLowerCase() || "soniox",
    maxSessionMs: envNumber(env, "LIVE_MAX_SESSION_MS", 140_000),
    // Only a plain 0 turns the limit off: anything else that isn't a time keeps the Free plan's.
    wallClockMs: env.get("LIVE_WALL_CLOCK_MS")?.trim() === "0" ? null : envNumber(env, "LIVE_WALL_CLOCK_MS", 150_000),
    benchKey: env.get("LIVE_BENCH_KEY") || undefined,
    providers: {
      soniox: { apiKey: env.get("SONIOX_API_KEY") || undefined, model: env.get("LIVE_SONIOX_MODEL") || DEFAULT_SONIOX_MODEL },
    },
    perMinute: 40,
    anonymousPerMinute: 10,
  };
}

/** The protocol version this relay speaks. */
const PROTOCOL_VERSION = 1;
/** The preflight's scope: a dictation's sockets share its attempts there. */
const SCOPE = "live";
/** A caller's sockets on one isolate. */
const MAX_SOCKETS = 3;
/** 16 kHz mono PCM16. */
const BYTES_PER_MS = 32;
/** The longest audio frame the app should send, as `ready` tells it. */
const MAX_CHUNK_MS = 250;
/** How much audio waits for the service's socket to be open and configured: 12 s. */
const MAX_BUFFERED_BYTES = 12_000 * BYTES_PER_MS;
/** A text frame longer than this isn't read: a `start` with a hundred keywords is under 10 KB. */
const MAX_MESSAGE_CHARS = 64 * 1024;
/** A session that has had no audio for this long is closed. */
const IDLE_MS = 15_000;
/** At most one partial in this long. */
const PARTIAL_INTERVAL_MS = 100;
/** A partial carries this much of the unsettled text: its end. */
const MAX_VOLATILE_CHARS = 200;
/** How long the final text may take after the app's `finalize`. */
const FINALIZE_DEADLINE_MS = 2500;
/** When the app should start its upload beside a `finalize` still unanswered (`ready.policy`). */
const HEDGE_AFTER_MS = 1000;
/** The session's timer fires this long before the platform would end the worker. */
const WALL_CLOCK_MARGIN_MS = 5000;
/** A worker with less than this left for a socket takes none: the app uploads instead. */
const MIN_SESSION_MS = 20_000;

/**
 * How long a socket opened now may last. The platform ends a worker `wallClockMs` after it booted,
 * with every socket on it, and a new socket can land on a worker that is already old. So the
 * budget is what is left of the worker's time, less a margin, and never above `maxSessionMs`.
 * Where no platform ends the process (`wallClockMs` null), its age takes nothing from a socket.
 */
export function sessionBudgetMs(config: LiveConfig, worker: RequestStart): number {
  if (config.wallClockMs === null) return config.maxSessionMs;
  return Math.max(0, Math.min(config.maxSessionMs, config.wallClockMs - worker.workerAgeMs - WALL_CLOCK_MARGIN_MS));
}

/** The app's `start`, cleaned as `transcribe` cleans its body. */
export interface LiveStart {
  dictationId: string;
  /** ISO-639-1 code ("ru"), or null to let the service detect the language. */
  language: string | null;
  /** Without a `language`: the ISO-639-1 codes the speech is one of (the user's languages); empty for any. */
  languages: string[];
  /** Personal dictionary terms, sent to the service as keyword hints. */
  keywords: string[];
  /** The app's name for itself, logged when the upgrade carried no x-client-info. */
  client: string | null;
}

/**
 * The first message: { type: "start", v: 1, dictationId: uuid, language: BCP-47 | null,
 * languages?: BCP-47[], keywords?: string[], audio: { format: "pcm_s16le", rate: 16000, channels: 1 },
 * client?: string }. `languages`: the user's languages, which the speech is detected among.
 */
export function parseStart(raw: unknown): Parsed<LiveStart> {
  if (typeof raw !== "object" || raw === null) return { ok: false, error: "start must be a JSON object" };
  const fields = raw as Record<string, unknown>;
  if (fields.type !== "start") return { ok: false, error: "type must be start" };
  if (fields.v !== PROTOCOL_VERSION) return { ok: false, error: "v must be 1" };
  if (typeof fields.dictationId !== "string" || !UUID_PATTERN.test(fields.dictationId)) {
    return { ok: false, error: "dictationId must be a UUID" };
  }
  const language = normalizeLanguageTag(fields.language);
  if (!language.ok) return { ok: false, error: language.error };
  // The one format of version 1; the relay never converts what the app sends.
  const audio = (typeof fields.audio === "object" && fields.audio !== null ? fields.audio : {}) as Record<string, unknown>;
  if (audio.format !== "pcm_s16le" || audio.rate !== 16000 || audio.channels !== 1) {
    return { ok: false, error: "audio must be pcm_s16le at 16000 Hz with 1 channel" };
  }
  return {
    ok: true,
    value: {
      dictationId: fields.dictationId,
      // What `parseTranscribeRequest` makes of the same tag: ISO-639-1, or null to detect it.
      language: isoLanguage(language.tag),
      languages: cleanLanguageHints(fields.languages),
      keywords: cleanKeywords(fields.keywords),
      // Capped like x-client-info: the client sets it.
      client: typeof fields.client === "string" ? fields.client.slice(0, 64) || null : null,
    },
  };
}

/** Why a socket ends without a final text. */
export type LiveErrorCode =
  | "limit_reached"
  | "rate_limited"
  | "unavailable"
  | "provider"
  | "budget"
  | "idle"
  | "bad_request"
  | "unsupported_version"
  | "finalize_timeout";

/** How a session ended, for its log line. */
type Outcome = "final" | "cancelled" | LiveErrorCode;

/** The close code after each error. */
const CLOSE_CODES: Record<LiveErrorCode, number> = {
  limit_reached: 1000,
  rate_limited: 1000,
  idle: 1000,
  finalize_timeout: 1000,
  bad_request: 1008,
  unsupported_version: 1008,
  provider: 1011,
  unavailable: 1011,
  budget: 1012,
};

/**
 * The error for each reason the preflight refuses a socket for. A dictation's seventh socket is
 * a rate limit to the app; another socket can't help once the week's words are used up.
 */
const REFUSALS: Record<NonNullable<Preflight["reason"]>, { code: LiveErrorCode; retryable: boolean }> = {
  too_many_attempts: { code: "rate_limited", retryable: true },
  rate_limited: { code: "rate_limited", retryable: true },
  limit_reached: { code: "limit_reached", retryable: false },
};

export interface LiveDeps {
  config: LiveConfig;
  /** The caller of the bearer token, or null (401). */
  authenticate(request: Request): Promise<Caller | null>;
  /** `dictation_preflight` in scope "live" for the dictation; throws when the RPC fails. */
  preflight(caller: Caller, scope: string, dictationId: string, perMinute: number): Promise<Preflight>;
  /** `record_usage`, handed to `background`. */
  recordUsage(caller: Caller, dictationId: string, words: number): PromiseLike<unknown>;
  /**
   * `record_cost`, handed to `background`: the audio a session sent to the service
   * (`_shared/cost.ts`). Left out, nothing is recorded.
   */
  recordCost?(caller: Caller, dictationId: string, calls: CostCall[]): PromiseLike<unknown>;
  /** Keeps the worker alive until `work` settles (`EdgeRuntime.waitUntil`). */
  background(work: PromiseLike<unknown>): void;
  /** `Deno.upgradeWebSocket`. */
  upgrade(request: Request): { socket: WebSocket; response: Response };
  /** Opens the socket to a speech service. */
  connect(target: LiveTarget): WebSocket;
  /** The speech services, by the name `LIVE_PROVIDER` (or a bench run's `?provider=`) gives. */
  adapters: Record<string, LiveProvider>;
  /** Counts the request against the worker (`beginRequest`). */
  worker?: () => RequestStart;
  /** The handler's clock in ms (`performance.now`). */
  now?: () => number;
  /** Runs `work` after `ms`; the returned function cancels it. Every timer of a session goes through it. */
  schedule?: (ms: number, work: () => void) => () => void;
  /** Where a session's one JSON log line goes (console.log). */
  log?: (line: string) => void;
}

/**
 * An upgraded request, and what its socket is served with. Not the request itself: its headers
 * can't be read once it is upgraded (Deno 2.9 throws "Request closed"), so what the session needs
 * of them is read before.
 */
interface Session {
  worker: RequestStart;
  caller: Caller;
  /** The header's id: the preflight runs for it, and `start` must repeat it. */
  dictationId: string;
  socket: WebSocket;
  providerName: string;
  provider: LiveProvider;
  access: { apiKey: string; model: string };
  /** A bench run chose the service. */
  bench: boolean;
  /** How long the socket may last (`sessionBudgetMs`). */
  budgetMs: number;
  /** The upgrade's x-client-info, for the log line. */
  client: string | null;
}

function badRequest(detail: string): Response {
  return json({ error: "bad_request", detail }, 400);
}

/** The relay can't take a socket now: the app uploads the dictation instead. */
function unavailable(): Response {
  return json({ error: "live_unavailable" }, 503);
}

function errorName(error: unknown): string {
  return error instanceof Error ? error.name : String(error);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** A text frame from the app as a message: a JSON object with a `type`, or null. */
function readMessage(data: string): Record<string, unknown> | null {
  if (data.length > MAX_MESSAGE_CHARS) return null;
  try {
    const message = JSON.parse(data);
    return typeof message === "object" && message !== null && typeof message.type === "string" ? message : null;
  } catch {
    return null;
  }
}

/** The last `max` characters of `text`, never starting with half of a character. */
function tail(text: string, max: number): string {
  if (text.length <= max) return text;
  const cut = text.slice(-max);
  const first = cut.charCodeAt(0);
  return first >= 0xdc00 && first <= 0xdfff ? cut.slice(1) : cut;
}

/** Closes a socket with a code and a reason; a runtime that refuses the code still closes it. */
function closeWith(socket: WebSocket, code: number, reason: string): void {
  try {
    socket.close(code, reason);
  } catch {
    socket.close();
  }
}

export function createLiveHandler(deps: LiveDeps): (request: Request) => Promise<Response> {
  const { config } = deps;
  const now = deps.now ?? (() => performance.now());
  const begin = deps.worker ?? (() => beginRequest());
  const log = deps.log ?? ((line: string) => console.log(line));
  const schedule = deps.schedule ?? ((ms: number, work: () => void) => {
    const timer = setTimeout(work, ms);
    return () => clearTimeout(timer);
  });
  /** How many sockets each caller has open on this isolate. */
  const sockets = new Map<string, number>();

  /**
   * One socket, from the upgrade to its log line. The promise settles once both sockets have
   * closed: the worker must outlive the reply to the upgrade, or it can be retired with them open.
   */
  function relay(session: Session): Promise<void> {
    const { worker, caller, dictationId, socket, provider, access } = session;
    const openedAt = now();
    const counts = { frames: 0, bytes: 0, partials: 0, ignored: 0 };
    /**
     * In whole ms, null for what never happened. `preflightMs` and `upstreamMs` are how long the
     * check and the service's handshake took, `readyMs` and `firstPartialMs` count from the
     * upgrade, and `finalizeMs` from the app's `finalize` to the final text.
     */
    const marks: Record<"preflightMs" | "upstreamMs" | "readyMs" | "firstPartialMs" | "finalizeMs", number | null> = {
      preflightMs: null,
      upstreamMs: null,
      readyMs: null,
      firstPartialMs: null,
      finalizeMs: null,
    };
    /** How the session ended; null while it runs. */
    let outcome: Outcome | null = null;
    /** The close code it ended with. */
    let endCode = 1000;
    let start: LiveStart | null = null;
    /** The preflight's answer, once it allowed the socket. */
    let admitted: Preflight | null = null;
    let adapter: LiveAdapter | null = null;
    let outbound: WebSocket | null = null;
    let outboundOpen = false;
    /** The service has its configuration, and the audio goes straight through. */
    let piping = false;
    /** The service ended the stream itself: there is nothing left to end. */
    let providerDone = false;
    /** The audio that arrived before the pipe was open. */
    let waiting: ArrayBuffer[] = [];
    let waitingBytes = 0;
    /** When the app's `finalize` arrived. */
    let finalizeAt: number | null = null;
    /** The audio the app says it sent, in its `finalize`. */
    let appAudioMs: number | null = null;
    let lastAudioAt = openedAt;
    /** Everything settled so far: the final text is made of it. */
    let stable = "";
    /** The settled text no partial has carried yet. */
    let unsent = "";
    let volatile = "";
    /** The unsettled text of the last partial. */
    let shown = "";
    /** The language of the newest words. */
    let lang: string | undefined;
    /** The languages of the settled text, in the order they were first heard. */
    const languages: string[] = [];
    /** The final text's words, once it is sent. */
    let words: number | null = null;
    let lastPartialAt = -Infinity;
    // The session's timers: its budget, the wait for audio, a partial held back, the wait for the final text.
    let cancelBudget = () => {};
    let cancelIdle = () => {};
    let cancelPartial: (() => void) | null = null;
    let cancelDeadline = () => {};
    let clientClosed = false;
    /** True until a connection to the service is asked for: one that was never opened isn't waited for. */
    let providerClosed = true;
    let release = () => {};
    const closed = new Promise<void>((resolve) => release = resolve);
    const settle = () => {
      if (clientClosed && providerClosed) release();
    };

    /**
     * Runs a socket's or a timer's handler. An exception there has no request to fail: it would
     * take the worker down, and every other session on it.
     */
    function guarded(work: () => void): void {
      try {
        work();
      } catch (error) {
        if (outcome !== null) return console.error("live: failed after the session ended", errorName(error));
        fail("unavailable", true, `exception ${errorName(error)}`);
      }
    }
    const after = (ms: number, work: () => void) => schedule(ms, () => guarded(work));

    /** Sends the app a message while its socket is open; false when it no longer is. */
    function say(message: Record<string, unknown>): boolean {
      if (socket.readyState !== WebSocket.OPEN) return false;
      socket.send(JSON.stringify(message));
      return true;
    }

    /** Sends the service a frame while its socket is open. */
    function forward(frame: LiveFrame): void {
      if (outbound?.readyState === WebSocket.OPEN) outbound.send(frame);
    }

    const audioMs = () => Math.round(counts.bytes / BYTES_PER_MS);

    /** The session's one log line. Never any text or keyword: only counts, codes and timings. */
    function writeLog(closeCode: number, detail: string | null): void {
      log(JSON.stringify({
        event: "live",
        provider: session.providerName,
        model: access.model,
        outcome,
        detail,
        closeCode,
        bench: session.bench,
        language: start?.language ?? null,
        detected: languages,
        keywords: start?.keywords.length ?? null,
        // The server's count of this dictation's sockets.
        attempt: admitted?.attempt ?? null,
        isAnonymous: caller.isAnonymous,
        // Whether the app's `finalize` arrived, and the audio it had sent by its own count.
        finalize: finalizeAt !== null,
        appAudioMs,
        audioMs: audioMs(),
        sessionMs: Math.round(now() - openedAt),
        budgetMs: session.budgetMs,
        frames: counts.frames,
        bytes: counts.bytes,
        stableChars: stable.length,
        words,
        partials: counts.partials,
        ignored: counts.ignored,
        ...marks,
        ...worker,
        client: session.client ?? start?.client ?? null,
      }));
    }

    /**
     * Ends the session, once: its timers, the caller's slot, the service's socket, the log line
     * and, when the relay is the one to close, the app's socket.
     */
    function finish(result: Outcome, closeCode: number, detail: string | null = null): void {
      if (outcome !== null) return;
      outcome = result;
      endCode = closeCode;
      cancelBudget();
      cancelIdle();
      cancelPartial?.();
      cancelDeadline();
      const held = (sockets.get(caller.userId) ?? 1) - 1;
      if (held > 0) sockets.set(caller.userId, held);
      else sockets.delete(caller.userId);
      try {
        if (outbound) {
          // The stream is ended the service's own way, unless the service ended it first.
          if (piping && adapter && !providerDone) for (const frame of adapter.end()) forward(frame);
          if (outbound.readyState <= WebSocket.OPEN) outbound.close(1000);
        }
        writeLog(closeCode, detail);
        // A service bills the audio it was sent, whether or not the dictation ended in text.
        if (piping && counts.bytes > 0 && deps.recordCost) {
          deps.background(deps.recordCost(caller, dictationId, [{
            kind: "speech",
            path: "live",
            plan: admitted?.plan ?? null,
            provider: session.providerName,
            model: access.model,
            audioMs: audioMs(),
          }]));
        }
      } finally {
        // Whatever went wrong above, the app isn't left on an open socket with no timer running.
        if (socket.readyState === WebSocket.OPEN) closeWith(socket, closeCode, result);
      }
    }

    /** Tells the app why the session is over, never with any text, and ends it. */
    function fail(code: LiveErrorCode, retryable: boolean, detail: string | null = null): void {
      if (outcome !== null) return;
      say({ type: "error", code, retryable });
      finish(code, CLOSE_CODES[code], detail);
    }

    /** The final text: everything settled, sent and counted, then both sockets close. */
    function complete(): void {
      if (outcome !== null || !start || !admitted || finalizeAt === null) return;
      // An app already closing its socket has given up on the text: its close is a cancel.
      if (socket.readyState !== WebSocket.OPEN) return;
      const text = stable.trim().replace(/ {2,}/g, " ");
      // What `transcriptUsage` counts for `transcribe`: in the language asked for, else the one heard first.
      const counted = countWords(text, start.language ?? languages[0]);
      const at = now();
      marks.finalizeMs = Math.round(at - finalizeAt);
      say({
        type: "final",
        text,
        languages,
        audioMs: audioMs(),
        words: counted,
        remaining: admitted.remaining === null ? null : Math.max(0, admitted.remaining - counted),
        timings: {
          region: worker.region,
          cold: worker.cold,
          workerAgeMs: worker.workerAgeMs,
          upstreamMs: marks.upstreamMs,
          firstPartialMs: marks.firstPartialMs,
          finalizeMs: marks.finalizeMs,
          totalMs: Math.round(at - openedAt),
        },
      });
      words = counted;
      // A transcript that went back as the final text is counted, under the dictation's own id:
      // `record_usage` keeps the largest count, so the app's upload of the same dictation doesn't
      // count it again.
      if (counted > 0) deps.background(deps.recordUsage(caller, dictationId, counted));
      finish("final", 1000);
    }

    /**
     * Opens the pipe once `start` is in, the preflight has passed and the service's socket is
     * open, whichever comes last: the configuration, then the audio that waited, in order.
     */
    function pipe(): void {
      if (piping || outcome !== null || !start || !admitted || !adapter || !outbound || !outboundOpen) return;
      piping = true;
      for (const frame of adapter.configure()) outbound.send(frame);
      for (const chunk of waiting) outbound.send(adapter.audio(chunk));
      waiting = [];
      waitingBytes = 0;
      marks.readyMs = Math.round(now() - openedAt);
      say({
        type: "ready",
        v: PROTOCOL_VERSION,
        provider: session.providerName,
        audio: { rate: 16000, maxChunkMs: MAX_CHUNK_MS },
        budgetSeconds: Math.floor(session.budgetMs / 1000),
        region: worker.region,
        caps: { languageDetection: adapter.caps.languageDetection },
        policy: { hedgeAfterMs: HEDGE_AFTER_MS, finalizeDeadlineMs: FINALIZE_DEADLINE_MS },
      });
      // A `finalize` that came before the pipe was open has waited for its audio.
      if (finalizeAt !== null) for (const frame of adapter.finalize()) outbound.send(frame);
    }

    /** Opens the service's socket. The audio waits until it is open and configured. */
    function connect(target: LiveTarget): void {
      const asked = now();
      let opened: WebSocket;
      try {
        opened = deps.connect(target);
      } catch (error) {
        return fail("provider", true, `connect ${errorName(error)}`);
      }
      outbound = opened;
      providerClosed = false;
      opened.binaryType = "arraybuffer";
      opened.onopen = () =>
        guarded(() => {
          outboundOpen = true;
          marks.upstreamMs = Math.round(now() - asked);
          pipe();
        });
      opened.onmessage = (event) => guarded(() => heard(event.data));
      opened.onclose = (event) => {
        providerClosed = true;
        outboundOpen = false;
        guarded(() => {
          // After the app's `finalize`, a normal close is the end of the dictation.
          if (piping && finalizeAt !== null && event.code === 1000) complete();
          // Any other close, while the session runs, lost it.
          fail("provider", true, `socket closed ${event.code}`);
        });
        settle();
      };
    }

    /**
     * The preflight, from the headers alone. It fails closed, as `dictate` does: without the
     * checks nothing is streamed.
     */
    function admit(): void {
      const asked = now();
      const perMinute = caller.isAnonymous ? config.anonymousPerMinute : config.perMinute;
      const checking = (async () => await deps.preflight(caller, SCOPE, dictationId, perMinute))();
      checking.then(
        (checked) =>
          guarded(() => {
            marks.preflightMs = Math.round(now() - asked);
            if (checked.allowed) {
              admitted = checked;
              return pipe();
            }
            const { reason } = checked;
            const refusal = reason && Object.hasOwn(REFUSALS, reason) ? REFUSALS[reason] : null;
            if (refusal) fail(refusal.code, refusal.retryable, reason);
            else fail("unavailable", true, "preflight refused without a known reason");
          }),
        (error) =>
          guarded(() => {
            marks.preflightMs = Math.round(now() - asked);
            fail("unavailable", true, `preflight failed: ${errorMessage(error)}`.slice(0, 160));
          }),
      );
    }

    function onStart(message: Record<string, unknown>): void {
      if (start) return fail("bad_request", false, "a second start");
      // Another version of the protocol: the app is told so, whatever else its `start` holds.
      if (typeof message.v === "number" && message.v !== PROTOCOL_VERSION) return fail("unsupported_version", false);
      const parsed = parseStart(message);
      if (!parsed.ok) return fail("bad_request", false, parsed.error);
      if (parsed.value.dictationId.toLowerCase() !== dictationId.toLowerCase()) {
        return fail("bad_request", false, "dictationId must match x-murmur-dictation");
      }
      const { language, languages: hints, keywords } = parsed.value;
      const made = provider.adapter({ language, languages: hints, keywords, ...access });
      if (!made) return fail("unavailable", false, "the service can't take this dictation's language");
      start = parsed.value;
      adapter = made;
      // A service whose address depends on the dictation is connected only now.
      if (!outbound) connect(made.target());
      pipe();
    }

    function onFinalize(message: Record<string, unknown>): void {
      if (!start) return fail("bad_request", false, "finalize before start");
      if (finalizeAt !== null) return;
      finalizeAt = now();
      const claimed = message.audioMs;
      appAudioMs = typeof claimed === "number" && Number.isFinite(claimed) && claimed >= 0 ? Math.round(claimed) : null;
      // No more audio is coming: from here only the deadline runs.
      cancelIdle();
      cancelDeadline = after(FINALIZE_DEADLINE_MS, () => fail("finalize_timeout", true));
      if (piping && adapter) for (const frame of adapter.finalize()) forward(frame);
    }

    function onAudio(chunk: ArrayBuffer): void {
      // Nothing follows the app's `finalize`, and an empty frame carries nothing.
      if (finalizeAt !== null || chunk.byteLength === 0) return;
      counts.frames++;
      counts.bytes += chunk.byteLength;
      lastAudioAt = now();
      // Audio arrives as it is spoken, after what waited for the socket: more than that isn't a dictation.
      if (counts.bytes > session.budgetMs * BYTES_PER_MS + MAX_BUFFERED_BYTES) {
        return fail("bad_request", false, "more audio than the session's time holds");
      }
      if (piping && adapter) return forward(adapter.audio(chunk));
      waitingBytes += chunk.byteLength;
      if (waitingBytes > MAX_BUFFERED_BYTES) return fail("unavailable", true, "the service's socket didn't open in time");
      waiting.push(chunk);
    }

    /** One message from the service: all it means is taken in, then the app is told, at most every 100 ms. */
    function heard(data: unknown): void {
      if (outcome !== null || !adapter) return;
      for (const event of adapter.parse(data as string | ArrayBuffer)) {
        apply(event);
        if (outcome !== null) return;
      }
      if (!unsent && volatile === shown) return;
      if (cancelPartial) return;
      const wait = lastPartialAt + PARTIAL_INTERVAL_MS - now();
      if (wait <= 0) return sendPartial();
      cancelPartial = after(wait, () => {
        cancelPartial = null;
        sendPartial();
      });
    }

    function apply(event: LiveEvent): void {
      if (event.kind === "text") {
        if (event.stable) {
          stable += event.stable;
          unsent += event.stable;
          if (event.lang && event.stable.trim() && !languages.includes(event.lang)) languages.push(event.lang);
        }
        volatile = tail(event.volatile, MAX_VOLATILE_CHARS);
        if (event.lang) lang = event.lang;
      } else if (event.kind === "finalized") {
        // Only what the app's `finalize` asked for: `complete` leaves any other alone.
        complete();
      } else if (event.kind === "closed") {
        providerDone = true;
        if (finalizeAt !== null) complete();
        else fail("provider", true, "the service ended the stream");
      } else {
        providerDone = true;
        fail(event.code, event.retryable, event.detail ?? null);
      }
    }

    /** `stable` is what settled since the last partial; `volatile` replaces the one before. */
    function sendPartial(): void {
      if (outcome !== null || (!unsent && volatile === shown)) return;
      if (!say({ type: "partial", seq: counts.partials + 1, stable: unsent, volatile, ...(lang ? { lang } : {}) })) return;
      counts.partials++;
      unsent = "";
      shown = volatile;
      lastPartialAt = now();
      marks.firstPartialMs ??= Math.round(lastPartialAt - openedAt);
    }

    /** Ends a session that has had no audio for IDLE_MS, looked at whenever that long has passed. */
    function watchIdle(ms: number): void {
      cancelIdle = after(ms, () => {
        const quiet = now() - lastAudioAt;
        if (quiet >= IDLE_MS) return fail("idle", true);
        watchIdle(IDLE_MS - quiet);
      });
    }

    cancelBudget = after(session.budgetMs, () => fail("budget", true));
    watchIdle(IDLE_MS);

    socket.binaryType = "arraybuffer";
    socket.onopen = () =>
      guarded(() => {
        // A socket that took longer to open than a session may sit idle: there is none left to start.
        if (outcome !== null) return closeWith(socket, endCode, outcome);
        // Both from the headers alone, at once: the app's `start` is still on its way.
        admit();
        const early = provider.target?.(access);
        if (early) connect(early);
      });
    socket.onmessage = (event) =>
      guarded(() => {
        if (outcome !== null) return;
        const data = event.data as string | ArrayBuffer;
        if (typeof data !== "string") return onAudio(data);
        const message = readMessage(data);
        if (!message) return fail("bad_request", false, "a text frame must be a JSON message with a type");
        if (message.type === "start") return onStart(message);
        if (message.type === "finalize") return onFinalize(message);
        // A message this relay doesn't know: a newer app's, which may go unheard.
        counts.ignored++;
      });
    socket.onclose = (event) => {
      clientClosed = true;
      // A close without `finalize`, or before the final text, is a cancel: nothing is counted.
      guarded(() => finish("cancelled", event.code));
      settle();
    };
    return closed;
  }

  return async (request) => {
    const worker = begin();
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return badRequest("a WebSocket upgrade is required");
    }
    const url = new URL(request.url);
    const bench = Boolean(config.benchKey) &&
      (request.headers.get("x-murmur-bench") ?? url.searchParams.get("bench")) === config.benchKey;
    const providerName = (bench && url.searchParams.get("provider")) || config.provider;
    const provider = Object.hasOwn(deps.adapters, providerName) ? deps.adapters[providerName] : null;
    const settings = Object.hasOwn(config.providers, providerName) ? config.providers[providerName] : null;
    const apiKey = settings?.apiKey;
    const budgetMs = sessionBudgetMs(config, worker);
    // A worker near its end takes no socket: the platform would cut it mid-dictation.
    if (config.disabled || !provider || !settings || !apiKey || budgetMs < MIN_SESSION_MS) return unavailable();

    let caller: Caller | null;
    try {
      caller = await deps.authenticate(request);
    } catch (error) {
      console.error("authentication failed", errorName(error));
      return unavailable();
    }
    if (!caller) return json({ error: "unauthorized" }, 401);
    const dictationId = request.headers.get("x-murmur-dictation")?.trim() ?? "";
    if (!UUID_PATTERN.test(dictationId)) return badRequest("x-murmur-dictation must be the dictation's UUID");
    const held = sockets.get(caller.userId) ?? 0;
    if (held >= MAX_SOCKETS) return json({ error: "too_many_sockets" }, 429);

    // Read before the upgrade: afterwards the request's headers are closed.
    const client = clientInfo(request);
    let upgraded: { socket: WebSocket; response: Response };
    try {
      upgraded = deps.upgrade(request);
    } catch {
      return badRequest("a WebSocket upgrade is required");
    }
    sockets.set(caller.userId, held + 1);
    deps.background(relay({
      worker,
      caller,
      dictationId,
      socket: upgraded.socket,
      providerName,
      provider,
      access: { apiKey, model: settings.model },
      bench,
      budgetMs,
      client,
    }));
    return upgraded.response;
  };
}
