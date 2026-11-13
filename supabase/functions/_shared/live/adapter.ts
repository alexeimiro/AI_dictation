// What the live relay (_shared/live.ts) needs from a speech service: where its realtime socket is,
// the frames that configure it, carry the audio, finish and end a dictation, and what its replies
// mean. One adapter per service keeps that service's protocol out of the relay, and the relay's
// out of the app. The audio is always what the app sends: PCM16LE, mono, 16 kHz.

/** One WebSocket frame: text, or binary. */
export type LiveFrame = string | ArrayBuffer;

/** Where a service's realtime socket is, and what carries the server's key on its handshake. */
export interface LiveTarget {
  url: string;
  headers?: Record<string, string>;
  protocols?: string[];
}

/** What a service can do, as the app is told in `ready.caps`. */
export interface LiveCaps {
  /** The service says which languages it heard: `final.languages` and `partial.lang` are filled. */
  languageDetection: boolean;
}

/** One dictation as the app's `start` asks for it, with the server's key and model for the service. */
export interface LiveAdapterOptions {
  /** ISO-639-1 code ("ru"), or null to let the service detect the language. */
  language: string | null;
  /** Without a `language`: the ISO-639-1 codes the speech is one of (the user's languages); empty for any. */
  languages: string[];
  /** Personal dictionary terms, sent as keyword hints. */
  keywords: string[];
  model: string;
  apiKey: string;
}

/** What one message from a service means to the relay. */
export type LiveEvent =
  /**
   * The text moved on. `stable` is appended to the settled text and never revised; `volatile`
   * replaces the unsettled text before it. `lang`: the ISO-639-1 language of `stable`, or of
   * `volatile` when there is no `stable`.
   */
  | { kind: "text"; stable: string; volatile: string; lang?: string }
  /** Everything sent before `finalize()` is settled: the stable text is the whole dictation. */
  | { kind: "finalized" }
  /** The service ended the stream and sends nothing more. */
  | { kind: "closed" }
  /**
   * The service gave up. `provider` is its own failure; `unavailable` is the server's standing with
   * it (its key, its balance, its limits), which the user can do nothing about; `limit_reached` is
   * a limit on this user, should a service keep one: the app takes it for the plan's. `detail` is
   * for the log line: a status and an error type, never the service's message, which can repeat
   * what it was sent.
   */
  | { kind: "error"; code: "provider" | "unavailable" | "limit_reached"; retryable: boolean; detail?: string };

/** One dictation's side of a service's protocol. */
export interface LiveAdapter {
  caps: LiveCaps;
  /** The service's socket for this dictation. */
  target(): LiveTarget;
  /** The frames to send first, before any audio. */
  configure(): LiveFrame[];
  /** The frame that carries one chunk of the app's audio. */
  audio(chunk: ArrayBuffer): LiveFrame;
  /** The frames to send when the user is done: they ask the service to settle all it has heard. */
  finalize(): LiveFrame[];
  /** The frames that end the stream: after the final text, or when the dictation is given up. */
  end(): LiveFrame[];
  /**
   * What one message from the service means, in order. The relay takes in all of it before it
   * tells the app, so a reply that settled text in two languages can be two `text` events.
   */
  parse(data: string | ArrayBuffer): LiveEvent[];
}

/** A speech service the relay can stream to (`LIVE_PROVIDER` names one). */
export interface LiveProvider {
  /**
   * The service's socket when it is the same for every dictation. The relay then opens it at the
   * upgrade, while the app's `start` is still on its way. A service that takes the language or the
   * keywords in its URL leaves this out, and is connected from its adapter's `target()` instead.
   */
  target?(access: Pick<LiveAdapterOptions, "apiKey" | "model">): LiveTarget;
  /** A dictation's adapter, or null when the service can't take it: a language it doesn't know. */
  adapter(options: LiveAdapterOptions): LiveAdapter | null;
}
