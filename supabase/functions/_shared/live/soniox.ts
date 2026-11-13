// The Soniox adapter for the live relay: its realtime WebSocket API, as documented at
// docs.soniox.com/stt/api-reference/websocket-api (read 2026-11-12).
//   → text    the configuration, once: the model, the raw PCM format, language hints, context terms
//   → binary  the audio
//   → text    {"type":"finalize"}: settle everything heard so far; the reply ends with a "<fin>" token
//   → text    "" (an empty text frame): the stream is over; Soniox answers `finished` and closes
//   ← text    { tokens: [{ text, is_final, language? }], … }: a final token comes once and is never
//             revised; the non-final ones are sent again, in full, with every reply
//   ← text    { error_code, error_type, error_message }, then Soniox closes
// The key goes with the connection, in the Authorization header: the configuration's `api_key`
// field is deprecated, and refused from 2027-01-15. Punctuation and casing have no setting in that
// API; its examples come punctuated and cased. Endpoint detection stays off: the app says when the
// user is done. No keepalive is sent: the app's audio has no gaps, and the relay closes a session
// that has had none for 15 s, before Soniox's own 20 s.
import type { LiveAdapterOptions, LiveEvent, LiveProvider, LiveTarget } from "./adapter.ts";

/** Soniox's realtime model (stt-rt-v5 is routed to it from 2026-12-15). */
export const DEFAULT_SONIOX_MODEL = "stt-rt-v6";

const ENDPOINT = "wss://stt-rt.soniox.com/transcribe-websocket";

/**
 * The languages Soniox transcribes (docs.soniox.com/stt/concepts/supported-languages, 2026-11-12).
 * A hint must be one of them, and speech in any other language would come back written as one of
 * these.
 */
const LANGUAGES = new Set(
  ("af sq ar az eu be bn bs bg ca zh hr cs da nl en et fi fr gl de el gu he hi hu id it ja kn kk ko lv lt mk ms ml mr " +
    "no fa pl pt pa ro ru sr sk sl es sw sv tl ta te th tr uk ur vi cy").split(" "),
);

/**
 * Soniox advises about 200 ms of silence between the end of speech and a finalize, and the app's
 * audio can end on a word: 200 ms of 16 kHz PCM16 zeros.
 */
const TRAILING_SILENCE_BYTES = 6400;

/** A marker among the tokens, never text: "<fin>" after a finalize, "<end>" at a detected endpoint. */
const MARKER = /^<[a-z_]+>$/;

type TextEvent = Extract<LiveEvent, { kind: "text" }>;

/** The fields of a token this adapter reads; nothing about them is taken on trust. */
interface SonioxToken {
  text?: unknown;
  is_final?: unknown;
  language?: unknown;
}

function target(apiKey: string): LiveTarget {
  return { url: ENDPOINT, headers: { Authorization: `Bearer ${apiKey}` } };
}

/** The language the user chose, else their languages for Soniox to detect it among. */
function languageHints(options: LiveAdapterOptions): string[] {
  return options.language ? [options.language] : options.languages;
}

/** The first message: what is coming and how to hear it. */
function configuration(options: LiveAdapterOptions): Record<string, unknown> {
  const hints = languageHints(options);
  return {
    model: options.model,
    audio_format: "pcm_s16le",
    sample_rate: 16000,
    num_channels: 1,
    // Hints only bias Soniox toward these languages; it still writes another one it hears.
    ...(hints.length > 0 ? { language_hints: hints } : {}),
    // Each token then names its language, which is how the app learns what was spoken.
    enable_language_identification: true,
    ...(options.keywords.length > 0 ? { context: { terms: options.keywords } } : {}),
  };
}

/** A token's language, when Soniox gives it as a plain code. */
function languageOf(token: SonioxToken): string | undefined {
  return typeof token.language === "string" && /^[a-z]{2,3}$/.test(token.language) ? token.language : undefined;
}

/**
 * A reply's tokens as text events. The final tokens are new settled text, in runs of one language;
 * the non-final ones are everything unsettled now, and go with the last run, or after it when they
 * are in another language. A reply without tokens still clears the unsettled text.
 */
function heard(tokens: unknown[]): LiveEvent[] {
  const texts: TextEvent[] = [];
  let volatile = "";
  let volatileLang: string | undefined;
  let finalized = false;
  for (const item of tokens) {
    const token: SonioxToken = typeof item === "object" && item !== null ? item : {};
    const text = typeof token.text === "string" ? token.text : "";
    if (!text) continue;
    if (MARKER.test(text)) {
      if (text === "<fin>") finalized = true;
      continue;
    }
    const lang = languageOf(token);
    if (token.is_final !== true) {
      volatile += text;
      volatileLang = lang ?? volatileLang;
      continue;
    }
    const run = texts.at(-1);
    if (run && (!lang || !run.lang || run.lang === lang)) {
      run.stable += text;
      if (lang && !run.lang) run.lang = lang;
    } else {
      texts.push({ kind: "text", stable: text, volatile: "", ...(lang ? { lang } : {}) });
    }
  }
  const last = texts.at(-1);
  if (last && (!volatileLang || !last.lang || last.lang === volatileLang)) {
    last.volatile = volatile;
    if (volatileLang && !last.lang) last.lang = volatileLang;
  } else {
    texts.push({ kind: "text", stable: "", volatile, ...(volatileLang ? { lang: volatileLang } : {}) });
  }
  return finalized ? [...texts, { kind: "finalized" }] : texts;
}

/**
 * An error reply, after which Soniox closes. A 408 and the 5xx are its own trouble, and another
 * socket may fare better. Everything else is the server's standing with Soniox (the key, a balance
 * or budget used up, its rate and connection limits, a configuration it refuses), never the user's
 * quota, and the next socket would meet it again.
 */
function failure(reply: Record<string, unknown>): LiveEvent {
  const code = Number(reply.error_code);
  const status = Number.isInteger(code) && code >= 400 && code <= 599 ? code : null;
  const type = typeof reply.error_type === "string" && /^[a-z_]{1,48}$/.test(reply.error_type) ? reply.error_type : null;
  // The status and the error type only: the message can repeat what was sent.
  const detail = ["soniox", status, type].filter((part) => part !== null).join(" ");
  return status === null || status === 408 || status >= 500
    ? { kind: "error", code: "provider", retryable: true, detail }
    : { kind: "error", code: "unavailable", retryable: false, detail };
}

function parse(data: string | ArrayBuffer): LiveEvent[] {
  if (typeof data !== "string") return [];
  let reply: Record<string, unknown> | null;
  try {
    reply = JSON.parse(data);
  } catch {
    return [];
  }
  if (typeof reply !== "object" || reply === null) return [];
  if (reply.error_code !== undefined || reply.error_type !== undefined) return [failure(reply)];
  const events = Array.isArray(reply.tokens) ? heard(reply.tokens) : [];
  // The last reply of a stream: Soniox closes after it.
  if (reply.finished === true) events.push({ kind: "closed" });
  return events;
}

export const soniox: LiveProvider = {
  // One address for every dictation: what a dictation asks for goes in its first message.
  target: ({ apiKey }) => target(apiKey),
  adapter(options) {
    // The language, or one of those it may be, is not one Soniox transcribes: the app uploads instead.
    if (languageHints(options).some((code) => !LANGUAGES.has(code))) return null;
    return {
      caps: { languageDetection: true },
      target: () => target(options.apiKey),
      configure: () => [JSON.stringify(configuration(options))],
      audio: (chunk) => chunk,
      finalize: () => [new ArrayBuffer(TRAILING_SILENCE_BYTES), JSON.stringify({ type: "finalize" })],
      end: () => [""],
      parse,
    };
  },
};
