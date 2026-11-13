import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { LiveAdapter, LiveAdapterOptions, LiveEvent } from "../_shared/live/adapter.ts";
import { DEFAULT_SONIOX_MODEL, soniox } from "../_shared/live/soniox.ts";

const OPTIONS: LiveAdapterOptions = {
  language: null,
  languages: ["ru", "en"],
  keywords: ["Окафор", "Murmur"],
  model: DEFAULT_SONIOX_MODEL,
  apiKey: "soniox-key",
};

/** The adapter of a dictation Soniox takes. */
function adapter(options: Partial<LiveAdapterOptions> = {}): LiveAdapter {
  const made = soniox.adapter({ ...OPTIONS, ...options });
  assert(made, "Soniox takes this dictation");
  return made;
}

/** The configuration frame, parsed. */
function configuration(options: Partial<LiveAdapterOptions> = {}): Record<string, unknown> {
  const frames = adapter(options).configure();
  assertEquals(frames.length, 1);
  return JSON.parse(frames[0] as string);
}

type Token = { text: string; is_final: boolean; language?: string };
const settled = (text: string, language?: string): Token => ({ text, is_final: true, ...(language ? { language } : {}) });
const unsettled = (text: string, language?: string): Token => ({ text, is_final: false, ...(language ? { language } : {}) });

/** A reply as Soniox sends it. */
function reply(tokens: unknown[], extra: Record<string, unknown> = {}): string {
  return JSON.stringify({ tokens, final_audio_proc_ms: 760, total_audio_proc_ms: 880, ...extra });
}

const parse = (data: string | ArrayBuffer): LiveEvent[] => adapter().parse(data);

Deno.test("the key goes with the connection, in the Authorization header, and never in the configuration", () => {
  const target = { url: "wss://stt-rt.soniox.com/transcribe-websocket", headers: { Authorization: "Bearer soniox-key" } };
  // The same address for every dictation, so the relay can open it before the app's start.
  assertEquals(soniox.target?.({ apiKey: "soniox-key", model: DEFAULT_SONIOX_MODEL }), target);
  assertEquals(adapter().target(), target);
  const frame = adapter().configure()[0] as string;
  assertFalse(frame.includes("soniox-key"));
  assertFalse("api_key" in JSON.parse(frame));
});

Deno.test("the configuration asks for raw 16 kHz PCM, each token's language, the user's languages and their dictionary", () => {
  assertEquals(configuration(), {
    model: "stt-rt-v6",
    audio_format: "pcm_s16le",
    sample_rate: 16000,
    num_channels: 1,
    language_hints: ["ru", "en"],
    enable_language_identification: true,
    context: { terms: ["Окафор", "Murmur"] },
  });
  assertEquals(configuration({ model: "stt-rt-v7" }).model, "stt-rt-v7");
});

Deno.test("a chosen language is the only hint; no languages means no hints, and no keywords no context", () => {
  assertEquals(configuration({ language: "ru" }).language_hints, ["ru"]);
  const bare = configuration({ languages: [], keywords: [] });
  assertFalse("language_hints" in bare);
  assertFalse("context" in bare);
  // Endpoint detection stays off: the app says when the user is done.
  assertFalse("enable_endpoint_detection" in bare);
});

Deno.test("a dictation in a language Soniox doesn't transcribe gets no adapter", () => {
  assertEquals(soniox.adapter({ ...OPTIONS, language: "is" }), null);
  // One it would have to detect among the user's languages.
  assertEquals(soniox.adapter({ ...OPTIONS, languages: ["en", "hy"] }), null);
  // The user's other languages don't matter once one is chosen.
  assert(soniox.adapter({ ...OPTIONS, language: "ru", languages: ["is"] }));
  // What `isoLanguage` makes of Apple's nb-NO, fil-PH and he-IL.
  for (const language of ["no", "tl", "he"]) assert(soniox.adapter({ ...OPTIONS, language }), language);
});

Deno.test("audio passes untouched; finalize is 200 ms of silence, then the request; an empty text frame ends the stream", () => {
  const made = adapter();
  const chunk = new Uint8Array(3200).buffer;
  assert(made.audio(chunk) === chunk);

  const [silence, finalize, ...rest] = made.finalize();
  assert(silence instanceof ArrayBuffer);
  assertEquals(silence.byteLength, 6400);
  assert(new Uint8Array(silence).every((byte) => byte === 0));
  assertEquals(JSON.parse(finalize as string), { type: "finalize" });
  assertEquals(rest, []);

  assertEquals(made.end(), [""]);
  assertEquals(made.caps, { languageDetection: true });
});

Deno.test("final tokens are settled text, sent once; the non-final ones are all that is unsettled now", () => {
  assertEquals(parse(reply([unsettled("How"), unsettled("'re")])), [{ kind: "text", stable: "", volatile: "How're" }]);
  assertEquals(parse(reply([settled("How"), settled(" "), unsettled("are"), unsettled(" "), unsettled("you")])), [
    { kind: "text", stable: "How ", volatile: "are you" },
  ]);
  assertEquals(parse(reply([settled(" "), settled("do"), settled("ing"), settled("?")])), [
    { kind: "text", stable: " doing?", volatile: "" },
  ]);
  // Nothing unsettled any more: the reply still says so.
  assertEquals(parse(reply([])), [{ kind: "text", stable: "", volatile: "" }]);
});

Deno.test("the <fin> marker ends a finalize and is never text, like any other marker", () => {
  assertEquals(parse(reply([settled(" спасибо", "ru"), settled(".", "ru"), { text: "<fin>", is_final: true }])), [
    { kind: "text", stable: " спасибо.", volatile: "", lang: "ru" },
    { kind: "finalized" },
  ]);
  assertEquals(parse(reply([{ text: "<fin>", is_final: true }])), [
    { kind: "text", stable: "", volatile: "" },
    { kind: "finalized" },
  ]);
  // An endpoint, were detection ever on: not text, and not the end of a finalize.
  assertEquals(parse(reply([settled("Hi", "en"), { text: "<end>", is_final: true }])), [
    { kind: "text", stable: "Hi", volatile: "", lang: "en" },
  ]);
});

Deno.test("each run of settled text carries its language; the unsettled text follows in its own", () => {
  // Two languages settled in one reply: an event for each, in order.
  assertEquals(
    parse(reply([settled("Привет", "ru"), settled(",", "ru"), settled(" hello", "en"), unsettled(" how", "en")])),
    [
      { kind: "text", stable: "Привет,", volatile: "", lang: "ru" },
      { kind: "text", stable: " hello", volatile: " how", lang: "en" },
    ],
  );
  // The speaker switched after what settled.
  assertEquals(parse(reply([settled("Привет", "ru"), unsettled(" how are", "en")])), [
    { kind: "text", stable: "Привет", volatile: "", lang: "ru" },
    { kind: "text", stable: "", volatile: " how are", lang: "en" },
  ]);
  assertEquals(parse(reply([unsettled(" как", "ru"), unsettled(" дела", "ru")])), [
    { kind: "text", stable: "", volatile: " как дела", lang: "ru" },
  ]);
  // A token without a language joins its neighbours; a language that isn't a code is left out.
  assertEquals(parse(reply([settled(" "), settled("да", "ru"), settled("!")])), [
    { kind: "text", stable: " да!", volatile: "", lang: "ru" },
  ]);
  assertEquals(parse(reply([settled("yes", "English (US)")])), [{ kind: "text", stable: "yes", volatile: "" }]);
});

Deno.test("the last reply of a stream says Soniox is closing", () => {
  assertEquals(parse(reply([], { finished: true })), [{ kind: "text", stable: "", volatile: "" }, { kind: "closed" }]);
});

Deno.test("an error is Soniox's own trouble or the server's standing with it, and never carries its message", () => {
  const failure = (error_code: unknown, error_type: unknown) =>
    parse(JSON.stringify({ error_code, error_type, error_message: "Context is too long: Окафор", request_id: "r-1" }));
  const provider = (detail: string): LiveEvent[] => [{ kind: "error", code: "provider", retryable: true, detail }];
  const account = (detail: string): LiveEvent[] => [{ kind: "error", code: "unavailable", retryable: false, detail }];

  // Soniox's own trouble: another socket may fare better.
  assertEquals(failure(503, "service_unavailable"), provider("soniox 503 service_unavailable"));
  assertEquals(failure(500, "internal_error"), provider("soniox 500 internal_error"));
  assertEquals(failure(408, "request_timeout"), provider("soniox 408 request_timeout"));

  // The server's account, never the user's quota: the next socket would meet it again.
  assertEquals(failure(402, "organization_balance_exhausted"), account("soniox 402 organization_balance_exhausted"));
  assertEquals(failure(402, "project_monthly_budget_exhausted"), account("soniox 402 project_monthly_budget_exhausted"));
  assertEquals(failure(429, "limit_exceeded"), account("soniox 429 limit_exceeded"));
  assertEquals(failure(429, "max_concurrent_connections_reached"), account("soniox 429 max_concurrent_connections_reached"));
  assertEquals(failure(401, "unauthenticated"), account("soniox 401 unauthenticated"));
  assertEquals(failure(400, "invalid_request"), account("soniox 400 invalid_request"));

  // A shape the docs don't describe: treated as a failure of the service, with nothing of it kept.
  assertEquals(failure("soon", "Окафор said so"), provider("soniox"));
  assertEquals(parse(JSON.stringify({ error_type: "internal_error" })), provider("soniox internal_error"));
});

Deno.test("anything that isn't a reply means nothing", () => {
  for (const data of ["", "not json", "null", "42", '"tokens"', "[]", "{}"]) assertEquals(parse(data), [], data);
  assertEquals(parse(new Uint8Array(8).buffer), []);
  // Tokens that aren't tokens are skipped, not trusted.
  assertEquals(parse(reply([null, 7, { text: 5, is_final: true }, { is_final: true }, settled("ok")])), [
    { kind: "text", stable: "ok", volatile: "" },
  ]);
});
