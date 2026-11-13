// How the runner asks each kind of candidate for one clip's text. Every adapter takes the clip as
// the app would send it and gives back the text, the language when the candidate says it, and the
// candidate's own processing time when it reports one. Nothing here keeps or logs the audio or the
// text: the runner writes the result to the private work folder only.
import { type AudioFormat, openAIForm, type TranscribeRequest } from "../../supabase/functions/_shared/transcribe.ts";
import { soniox } from "../../supabase/functions/_shared/live/soniox.ts";
import type { LiveEvent } from "../../supabase/functions/_shared/live/adapter.ts";
import { audioType, decodePcm16, wavOf } from "./clips.ts";
import type { Candidate } from "./candidates.ts";

/** One clip, as the runner hands it to an adapter. */
export interface ClipAudio {
  id: string;
  path: string;
  /** The file's bytes. */
  bytes: Uint8Array<ArrayBuffer>;
  /** PCM16 mono 16 kHz, decoded on first use (the WebSocket kinds, and files that aren't m4a or wav). */
  pcm(): Promise<Uint8Array>;
}

export interface Transcription {
  text: string;
  /** ISO-639-1, when the candidate reports the language it heard. */
  language: string | null;
  /** The candidate's own time for the request, when it reports it (a header); null otherwise. */
  serverMs: number | null;
  /** Kind-specific timings: `finalizeMs` for the WebSocket kinds (done → text). */
  detail?: Record<string, number>;
}

export interface AdapterContext {
  languageHints: string[];
  keywords: string[];
  env(name: string): string | undefined;
  fetcher?: typeof fetch;
  /** Opens a WebSocket with request headers (Deno's constructor takes them). */
  connect?(url: string, headers: Record<string, string>): WebSocket;
}

export type Transcriber = (clip: ClipAudio, signal: AbortSignal) => Promise<Transcription>;

/** A failure the report shows: a status and an error type, never a service's message (it can repeat what it was sent). */
export class CandidateError extends Error {
  constructor(readonly short: string) {
    super(short);
  }
}

/** Deno takes request headers for a WebSocket, which the web's constructor can't. */
type HeaderSocket = new (url: string, options: { headers: Record<string, string> }) => WebSocket;

function defaultConnect(url: string, headers: Record<string, string>): WebSocket {
  return new (WebSocket as unknown as HeaderSocket)(url, { headers });
}

export function transcriberFor(candidate: Candidate, context: AdapterContext): Transcriber {
  const key = candidate.keyEnv ? context.env(candidate.keyEnv) : undefined;
  if (candidate.keyEnv && !key) throw new CandidateError(`no ${candidate.keyEnv} in the environment`);
  const fetcher = context.fetcher ?? fetch;
  const connect = context.connect ?? defaultConnect;
  switch (candidate.kind) {
    case "openai":
    case "openai-compatible":
      return (clip, signal) => openAICompatible(candidate, key, clip, context, fetcher, signal);
    case "elevenlabs":
      return (clip, signal) => elevenLabs(candidate, key!, clip, context, fetcher, signal);
    case "soniox":
      return (clip, signal) => sonioxSocket(candidate, key!, clip, context, connect, signal);
    case "vllm-realtime":
      return (clip, signal) => vllmRealtime(candidate, clip, connect, signal);
  }
}

// MARK: Upload kinds

/** The file as the request carries it: m4a and wav as they are, anything else as wav. */
async function uploadable(clip: ClipAudio): Promise<{ bytes: Uint8Array<ArrayBuffer>; format: AudioFormat }> {
  const extension = clip.path.split(".").pop()?.toLowerCase();
  if (extension === "m4a" || extension === "wav") return { bytes: clip.bytes, format: extension };
  return { bytes: wavOf(await clip.pcm()) as Uint8Array<ArrayBuffer>, format: "wav" };
}

function trimSlash(url: string): string {
  return url.replace(/\/+$/, "");
}

async function failure(response: Response, who: string): Promise<CandidateError> {
  const body = await response.json().catch(() => null) as Record<string, unknown> | null;
  const error = body?.error as Record<string, unknown> | string | undefined;
  const type = typeof error === "object" && error ? error.code ?? error.type : body?.detail && typeof body.detail === "object"
    ? (body.detail as Record<string, unknown>).status
    : undefined;
  const label = typeof type === "string" && /^[\w.-]{1,48}$/.test(type) ? ` ${type}` : "";
  return new CandidateError(`${who} HTTP ${response.status}${label}`);
}

/** A number from a response header: OpenAI's `openai-processing-ms`, or model_server.py's `x-processing-ms`. */
function headerMs(response: Response): number | null {
  const value = response.headers.get("x-processing-ms") ?? response.headers.get("openai-processing-ms");
  const number = value === null ? NaN : Number(value);
  return Number.isFinite(number) ? Math.round(number) : null;
}

async function openAICompatible(
  candidate: Candidate,
  key: string | undefined,
  clip: ClipAudio,
  context: AdapterContext,
  fetcher: typeof fetch,
  signal: AbortSignal,
): Promise<Transcription> {
  const { bytes, format } = await uploadable(clip);
  // The very form the `transcribe` function sends: languages[] and keywords[] for gpt-transcribe,
  // `language` (only when there is one) and the terms as a `prompt` for every other model.
  const request: TranscribeRequest = {
    dictationId: null,
    audio: bytes,
    format,
    language: null,
    languageHints: context.languageHints,
    keywords: context.keywords,
  };
  const base = trimSlash(candidate.url ?? "https://api.openai.com");
  const response = await fetcher(`${base}/v1/audio/transcriptions`, {
    method: "POST",
    headers: key ? { Authorization: `Bearer ${key}` } : {},
    body: openAIForm(request, candidate.model),
    signal,
  });
  if (!response.ok) throw await failure(response, candidate.kind === "openai" ? "OpenAI" : "server");
  const payload = await response.json() as { text?: unknown; language?: unknown; languages?: unknown };
  const reported = Array.isArray(payload.languages)
    ? payload.languages.flatMap((item) => typeof item?.code === "string" ? [item.code] : [])[0]
    : payload.language;
  const { text, language } = withoutLanguageTag(typeof payload.text === "string" ? payload.text : "");
  return {
    text,
    language: typeof reported === "string" && reported ? reported.split("-")[0].toLowerCase() : language,
    serverMs: headerMs(response),
  };
}

const LANGUAGE_NAMES: Record<string, string> = { russian: "ru", english: "en", ukrainian: "uk", german: "de", french: "fr", spanish: "es" };

/**
 * Some open models write the language they heard before the text ("language Russian<asr_text>Привет."
 * from Qwen3-ASR's own format). That tag is the server's to strip; when it doesn't, it goes here, so
 * it never counts as words.
 */
export function withoutLanguageTag(raw: string): { text: string; language: string | null } {
  const match = raw.match(/^\s*language\s+([A-Za-z]+)\s*<asr_text>/);
  if (!match) return { text: raw.trim(), language: null };
  return { text: raw.slice(match[0].length).trim(), language: LANGUAGE_NAMES[match[1].toLowerCase()] ?? null };
}

async function elevenLabs(
  candidate: Candidate,
  key: string,
  clip: ClipAudio,
  context: AdapterContext,
  fetcher: typeof fetch,
  signal: AbortSignal,
): Promise<Transcription> {
  const { bytes, format } = await uploadable(clip);
  const form = new FormData();
  form.append("model_id", candidate.model);
  form.append("file", new Blob([bytes], { type: audioType(`x.${format}`) }), `dictation.${format}`);
  // As a dictation: no sound tags, one speaker. The language is detected (the app's Auto).
  form.append("tag_audio_events", "false");
  form.append("diarize", "false");
  const numbers = candidate.options?.numbersFormat ?? (candidate.model.startsWith("scribe_v3") ? "digits" : undefined);
  if (typeof numbers === "string") form.append("numbers_format", numbers);
  // Key terms cost 20% more there; sent only when the candidates file lists your dictionary's terms.
  for (const term of context.keywords) form.append("keyterms", term);
  const response = await fetcher(`${trimSlash(candidate.url ?? "https://api.elevenlabs.io")}/v1/speech-to-text`, {
    method: "POST",
    headers: { "xi-api-key": key },
    body: form,
    signal,
  });
  if (!response.ok) throw await failure(response, "ElevenLabs");
  const payload = await response.json() as { text?: unknown; language_code?: unknown };
  const language = typeof payload.language_code === "string" ? payload.language_code.toLowerCase() : null;
  return {
    text: typeof payload.text === "string" ? payload.text.trim() : "",
    // ISO-639-3 for some languages: "rus" and "eng" become "ru" and "en".
    language: language ? ({ rus: "ru", eng: "en" } as Record<string, string>)[language] ?? language.slice(0, 2) : null,
    serverMs: headerMs(response),
  };
}

// MARK: WebSocket kinds

/** 100 ms of 16 kHz PCM16: the frame the app streams. */
const FRAME_BYTES = 3200;

function frames(pcm: Uint8Array, size: number): ArrayBuffer[] {
  const chunks: ArrayBuffer[] = [];
  for (let at = 0; at < pcm.byteLength; at += size) chunks.push(pcm.slice(at, at + size).buffer as ArrayBuffer);
  return chunks;
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, Math.max(0, ms));
    signal.addEventListener("abort", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
  });
}

/** A socket's messages as a queue the adapter can wait on, ended by its close or the deadline. */
class SocketSession {
  private queue: (string | ArrayBuffer)[] = [];
  private waiting: ((message: string | ArrayBuffer | null) => void) | null = null;
  closed = false;
  closeCode: number | null = null;
  opened: Promise<void>;

  constructor(readonly socket: WebSocket, signal: AbortSignal) {
    socket.binaryType = "arraybuffer";
    let isOpen = false;
    let failOpen: (error: CandidateError) => void = () => {};
    this.opened = new Promise((resolve, reject) => {
      failOpen = reject;
      socket.onopen = () => {
        isOpen = true;
        resolve();
      };
    });
    // A failed open is reported by `opened`; a later failure shows as the close.
    this.opened.catch(() => {});
    socket.onerror = (event) => {
      if (!isOpen) failOpen(new CandidateError(`couldn't connect: ${(event as ErrorEvent).message || "no detail"}`));
    };
    socket.onmessage = (event) => this.push(event.data as string | ArrayBuffer);
    socket.onclose = (event) => {
      this.closed = true;
      this.closeCode = event.code;
      if (!isOpen) failOpen(new CandidateError(signal.aborted ? "timed out" : `closed before it opened (${event.code})`));
      this.push(null);
    };
    if (signal.aborted) this.close();
    signal.addEventListener("abort", () => this.close(), { once: true });
  }

  private push(message: string | ArrayBuffer | null) {
    if (this.waiting) {
      const resolve = this.waiting;
      this.waiting = null;
      resolve(message);
    } else if (message !== null) {
      this.queue.push(message);
    }
  }

  /** The next message; null once the socket has closed and nothing is left. */
  next(): Promise<string | ArrayBuffer | null> {
    if (this.queue.length > 0) return Promise.resolve(this.queue.shift()!);
    if (this.closed) return Promise.resolve(null);
    return new Promise((resolve) => this.waiting = resolve);
  }

  send(message: string | ArrayBuffer) {
    if (this.socket.readyState === WebSocket.OPEN) this.socket.send(message);
  }

  close() {
    if (this.socket.readyState <= WebSocket.OPEN) this.socket.close(1000);
  }
}

/**
 * Soniox: the clip streamed through the same adapter the live relay uses, then `finalize`. By default
 * the audio goes out as fast as the socket takes it (the upload path); `options.pace: "realtime"`
 * sends it at the pace it was spoken, as the live path does. `finalizeMs` is done → text.
 */
async function sonioxSocket(
  candidate: Candidate,
  key: string,
  clip: ClipAudio,
  context: AdapterContext,
  connect: NonNullable<AdapterContext["connect"]>,
  signal: AbortSignal,
): Promise<Transcription> {
  const adapter = soniox.adapter({
    language: null,
    languages: context.languageHints,
    keywords: context.keywords,
    model: candidate.model,
    apiKey: key,
  });
  if (!adapter) throw new CandidateError("Soniox doesn't take one of the language hints");
  const target = adapter.target();
  const url = candidate.url ?? target.url;
  const session = new SocketSession(connect(url, target.headers ?? {}), signal);
  await session.opened;
  for (const frame of adapter.configure()) session.send(frame);
  const realtime = candidate.options?.pace === "realtime";
  const started = performance.now();
  for (const [index, chunk] of frames(await clip.pcm(), FRAME_BYTES).entries()) {
    if (realtime) await sleep(started + index * 100 - performance.now(), signal);
    session.send(adapter.audio(chunk));
  }
  const finalizedAt = performance.now();
  for (const frame of adapter.finalize()) session.send(frame);
  let text = "";
  let language: string | null = null;
  while (true) {
    const message = await session.next();
    if (message === null) break;
    const events: LiveEvent[] = adapter.parse(message);
    for (const event of events) {
      if (event.kind === "text") {
        text += event.stable;
        language ??= event.lang ?? null;
      } else if (event.kind === "error") {
        session.close();
        throw new CandidateError(event.detail ?? `Soniox ${event.code}`);
      } else if (event.kind === "finalized") {
        // Everything sent before `finalize` is settled now: the text is whole. End the stream politely.
        const finalizeMs = Math.round(performance.now() - finalizedAt);
        for (const frame of adapter.end()) session.send(frame);
        session.close();
        return { text: text.trim(), language, serverMs: null, detail: { finalizeMs } };
      }
    }
  }
  throw new CandidateError(signal.aborted ? "timed out" : `Soniox closed before the final text (${session.closeCode})`);
}

/** The base64 of bytes, in pieces small enough for String.fromCharCode. */
function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let at = 0; at < bytes.byteLength; at += 0x8000) binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
  return btoa(binary);
}

/**
 * vLLM's /v1/realtime (Voxtral Realtime), as vLLM's own example client speaks it: wait for
 * session.created, name the model, commit once to start, append base64 PCM16 at 16 kHz, then a
 * final commit; the text arrives as transcription.delta and, whole, in transcription.done.
 */
async function vllmRealtime(
  candidate: Candidate,
  clip: ClipAudio,
  connect: NonNullable<AdapterContext["connect"]>,
  signal: AbortSignal,
): Promise<Transcription> {
  const session = new SocketSession(connect(candidate.url!, {}), signal);
  await session.opened;
  const parse = (message: string | ArrayBuffer) => {
    if (typeof message !== "string") return null;
    try {
      return JSON.parse(message) as Record<string, unknown>;
    } catch {
      return null;
    }
  };
  // The server speaks first.
  while (true) {
    const message = await session.next();
    if (message === null) throw new CandidateError(signal.aborted ? "timed out" : "closed before session.created");
    const event = parse(message);
    if (event?.type === "session.created") break;
    if (event?.type === "error") throw new CandidateError("vLLM error before the session");
  }
  session.send(JSON.stringify({ type: "session.update", model: candidate.model }));
  session.send(JSON.stringify({ type: "input_audio_buffer.commit" }));
  const realtime = candidate.options?.pace === "realtime";
  const started = performance.now();
  // 4096 bytes a message, as vLLM's file client sends: 128 ms of audio.
  for (const [index, chunk] of frames(await clip.pcm(), 4096).entries()) {
    if (realtime) await sleep(started + index * 128 - performance.now(), signal);
    session.send(JSON.stringify({ type: "input_audio_buffer.append", audio: base64(new Uint8Array(chunk)) }));
  }
  const finalizedAt = performance.now();
  session.send(JSON.stringify({ type: "input_audio_buffer.commit", final: true }));
  let deltas = "";
  while (true) {
    const message = await session.next();
    if (message === null) break;
    const event = parse(message);
    if (event?.type === "transcription.delta" && typeof event.delta === "string") deltas += event.delta;
    else if (event?.type === "transcription.done") {
      session.close();
      const text = typeof event.text === "string" ? event.text : deltas;
      return { text: text.trim(), language: null, serverMs: null, detail: { finalizeMs: Math.round(performance.now() - finalizedAt) } };
    } else if (event?.type === "error") {
      session.close();
      throw new CandidateError("vLLM error");
    }
  }
  throw new CandidateError(signal.aborted ? "timed out" : `closed before transcription.done (${session.closeCode})`);
}

/** A clip read from disk, its samples decoded only when an adapter asks. */
export async function clipAudio(id: string, path: string): Promise<ClipAudio> {
  const bytes = await Deno.readFile(path) as Uint8Array<ArrayBuffer>;
  let pcm: Promise<Uint8Array> | null = null;
  return { id, path, bytes, pcm: () => pcm ??= decodePcm16(path) };
}
