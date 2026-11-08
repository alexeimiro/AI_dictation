import { assert, assertEquals, assertFalse, assertStringIncludes } from "jsr:@std/assert@1";
import { DEFAULT_EFFORT, DEFAULT_MODEL } from "../_shared/cleanup.ts";
import { cleanupConfig, dictateConfig, envNumber, translationConfig } from "../_shared/config.ts";
import { createDictateHandler, type DictateDeps, parseDictateMetadata, parseDictateText } from "../_shared/dictate.ts";
import type { Caller } from "../_shared/http.ts";
import type { Preflight } from "../_shared/preflight.ts";
import { TRANSCRIBE_LIMITS } from "../_shared/transcribe.ts";

const ENDPOINT = "http://localhost/functions/v1/dictate";
const DICTATION = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const OTHER_DICTATION = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
const EXECUTION_ID = "4b6f7a1e-2c3d-4e5f-8a9b-0c1d2e3f4a5b";
const USER: Caller = { userId: "1b4e28ba-2fa1-41d2-883f-0016d3cca427", isAnonymous: false };
const GUEST: Caller = { userId: "6fa459ea-ee8a-4ca4-894e-db77e160355e", isAnonymous: true };
const AUDIO = new TextEncoder().encode("fake m4a bytes");
const TRANSCRIPT = "можешь скинуть отчёт до пятницы спасибо большое";
const TRANSLATION = "Can you send the report by Friday? Thanks a lot!";
/** `cleanup`'s 200 reply; `dictate`'s is a superset of it. */
const CLEANUP_KEYS = ["text", "status", "reason", "targetLanguage", "words", "model", "ttftMs", "totalMs", "remaining", "timings"];

const metadata = {
  dictationId: DICTATION,
  format: "m4a",
  language: "ru-RU",
  keywords: ["Окафор"],
  targetLanguage: "en-US",
  style: "casual",
  dictionary: [{ term: "Valerio", misspelling: "valeria" }],
  snippets: [{ token: "⟦s:1a2b3c4d⟧", trigger: "my calendar link" }],
};
const textBody = { dictationId: DICTATION, transcript: TRANSCRIPT, language: "ru-RU", targetLanguage: "en-US", style: "casual" };

const ALLOWED: Preflight = { allowed: true, reason: null, plan: "basic", remaining: 870, attempt: 1 };

// A signal that never fires: a real deadline would leave its timer behind for the test sanitizer.
const NEVER = new AbortController().signal;

/** A Responses API reply with the given text. */
function responsesReply(text: string): Record<string, unknown> {
  return {
    model: "gpt-6-astra-2026-09-01",
    status: "completed",
    incomplete_details: null,
    output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text, annotations: [] }] }],
    usage: { input_tokens: 1950, output_tokens: 12, input_tokens_details: { cached_tokens: 1900, cache_write_tokens: 0 } },
  };
}

/** The test's clock, which the fake OpenAI calls move on to stand for their duration. */
interface Clock {
  advance(ms: number): void;
}
/** One fake OpenAI endpoint. */
type Route = (init: RequestInit, clock: Clock) => Response | Promise<Response>;

interface Setup {
  env?: Record<string, string>;
  apiKey?: string;
  /** The preflight's answer: fields over ALLOWED, an error it throws, or a promise the test settles. */
  preflight?: Partial<Preflight> | Error | (() => Promise<Preflight>);
  transcription?: Route;
  responses?: Route;
  models?: Route;
}

interface Fetched {
  path: string;
  init: RequestInit;
  /** The JSON body, for the Responses call. */
  json?: Record<string, unknown>;
}

/** A handler on fakes, and everything it did, in order. */
function setup(options: Setup = {}) {
  const recorded = {
    events: [] as string[],
    fetches: [] as Fetched[],
    preflights: [] as { caller: Caller; dictationId: string; perMinute: number }[],
    usage: [] as { caller: Caller; dictationId: string; words: number }[],
    quotas: [] as Caller[],
    signals: [] as number[],
    background: [] as PromiseLike<unknown>[],
    logs: [] as Record<string, unknown>[],
  };
  let now = 1000;
  const clock: Clock = { advance: (ms) => void (now += ms) };
  let served = 0;
  const routes: Record<string, Route> = {
    "/v1/audio/transcriptions": options.transcription ?? ((_, clock) => {
      clock.advance(640);
      return Response.json({ text: TRANSCRIPT, languages: [{ code: "ru" }] });
    }),
    "/v1/responses": options.responses ?? ((_, clock) => {
      clock.advance(690);
      return Response.json(responsesReply(TRANSLATION));
    }),
    "/v1/models": options.models ?? ((_, clock) => {
      clock.advance(120);
      return Response.json({ id: "gpt-6-astra", object: "model" });
    }),
  };
  const fetcher = (async (input: string | URL, init: RequestInit = {}) => {
    const path = new URL(String(input)).pathname;
    recorded.events.push(`fetch ${path}`);
    recorded.fetches.push({ path, init, json: typeof init.body === "string" ? JSON.parse(init.body) : undefined });
    const route = routes[path.startsWith("/v1/models/") ? "/v1/models" : path];
    if (!route) throw new Error(`unexpected fetch ${path}`);
    // A real call answers later: the caller's phase has started timing by the time it does.
    await Promise.resolve();
    return await route(init, clock);
  }) as unknown as typeof fetch;

  const deps: DictateDeps = {
    config: dictateConfig(new Map(Object.entries(options.env ?? {}))),
    apiKey: "apiKey" in options ? options.apiKey : "sk-test",
    authenticate: (request) => {
      recorded.events.push("auth");
      const token = request.headers.get("Authorization");
      return Promise.resolve(token === "Bearer user" ? USER : token === "Bearer guest" ? GUEST : null);
    },
    preflight: async (caller, dictationId, perMinute) => {
      recorded.events.push("preflight");
      recorded.preflights.push({ caller, dictationId, perMinute });
      const answer = typeof options.preflight === "function" ? await options.preflight() : options.preflight;
      if (answer instanceof Error) throw answer;
      return { ...ALLOWED, attempt: recorded.preflights.length, ...answer };
    },
    readQuota: (caller) => {
      recorded.quotas.push(caller);
      return Promise.resolve();
    },
    recordUsage: (caller, dictationId, words) => {
      recorded.usage.push({ caller, dictationId, words });
      return Promise.resolve();
    },
    background: (work) => void recorded.background.push(work),
    fetcher,
    now: () => now,
    signal: (ms) => {
      recorded.signals.push(ms);
      return NEVER;
    },
    worker: () => ({ cold: served++ === 0, workerAgeMs: 41210, region: "eu-central-1", executionId: EXECUTION_ID }),
    log: (line) => void recorded.logs.push(JSON.parse(line)),
  };
  return { handler: createDictateHandler(deps), recorded, clock };
}

interface RequestOptions {
  /** The bearer token: "user", "guest", anything else is invalid; null sends none. */
  token?: string | null;
  /** The x-murmur-dictation header; null leaves it out. */
  dictation?: string | null;
  headers?: Record<string, string>;
}

function headersFor({ token = "user", dictation = DICTATION, headers = {} }: RequestOptions): Record<string, string> {
  return {
    ...(token === null ? {} : { Authorization: `Bearer ${token}` }),
    ...(dictation === null ? {} : { "x-murmur-dictation": dictation }),
    ...headers,
  };
}

/** The audio-mode form; the metadata is a part without a filename, as `curl -F 'metadata=<…'` sends it. */
function audioForm(meta: Record<string, unknown> | string = metadata, audio: Uint8Array<ArrayBuffer> | null = AUDIO): FormData {
  const form = new FormData();
  form.append("metadata", typeof meta === "string" ? meta : JSON.stringify(meta));
  if (audio) form.append("audio", new Blob([audio], { type: "audio/mp4" }), "dictation.m4a");
  return form;
}

function audioRequest(meta: Record<string, unknown> | string = metadata, options: RequestOptions = {}): Request {
  return new Request(ENDPOINT, { method: "POST", body: audioForm(meta), headers: headersFor(options) });
}

function textRequest(body: Record<string, unknown> = textBody, options: RequestOptions = {}): Request {
  return new Request(ENDPOINT, {
    method: "POST",
    body: JSON.stringify(body),
    headers: { ...headersFor(options), "Content-Type": "application/json" },
  });
}

function warmRequest(token: string | null = "user"): Request {
  return new Request(ENDPOINT, { method: "POST", headers: headersFor({ token, dictation: null, headers: { "x-murmur-warm": "1" } }) });
}

const paths = (recorded: { fetches: Fetched[] }) => recorded.fetches.map((fetched) => fetched.path);
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

/** Runs `work` with console.error silenced: the failure paths log on purpose. */
async function quietly<T>(work: () => Promise<T>): Promise<T> {
  const original = console.error;
  console.error = () => {};
  try {
    return await work();
  } finally {
    console.error = original;
  }
}

Deno.test("no caller → 401, with no preflight and no OpenAI call", async () => {
  const { handler, recorded } = setup();
  for (const request of [audioRequest(metadata, { token: null }), textRequest(textBody, { token: "expired" }), warmRequest("expired")]) {
    const response = await handler(request);
    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "unauthorized" });
  }
  assertEquals(recorded.preflights, []);
  assertEquals(recorded.fetches, []);
  assertEquals(recorded.quotas, []);
});

Deno.test("the preflight starts before the body has arrived, and OpenAI only once the preflight passes", async () => {
  const gate = Promise.withResolvers<Preflight>();
  const { handler, recorded } = setup({ preflight: () => gate.promise });
  const encoded = new Response(audioForm());
  const bytes = new Uint8Array(await encoded.arrayBuffer());
  let upload!: ReadableStreamDefaultController<Uint8Array>;
  const body = new ReadableStream<Uint8Array>({ start: (controller) => void (upload = controller) });
  upload.enqueue(bytes.slice(0, 64));
  const request = new Request(ENDPOINT, {
    method: "POST",
    body,
    headers: { ...headersFor({}), "content-type": encoded.headers.get("content-type")! },
  });

  let answered = false;
  const responding = handler(request).finally(() => void (answered = true));
  for (let i = 0; i < 50 && recorded.preflights.length === 0; i++) await tick();
  assertEquals(recorded.preflights, [{ caller: USER, dictationId: DICTATION, perMinute: 40 }], "from the headers alone");
  assertFalse(answered);

  recorded.events.push("rest of the body");
  upload.enqueue(bytes.slice(64));
  upload.close();
  for (let i = 0; i < 5; i++) await tick();
  assertEquals(recorded.fetches, [], "OpenAI waits for the preflight");

  recorded.events.push("preflight passed");
  gate.resolve(ALLOWED);
  const response = await responding;
  assertEquals(response.status, 200);
  assertEquals((await response.json()).status, "cleaned");
  assertEquals(recorded.events, [
    "auth",
    "preflight",
    "rest of the body",
    "preflight passed",
    "fetch /v1/audio/transcriptions",
    "fetch /v1/responses",
  ]);
});

Deno.test("a refused preflight answers 402 or 429, with no OpenAI call", async () => {
  for (const [reason, status] of [["limit_reached", 402], ["rate_limited", 429], ["too_many_attempts", 429]] as const) {
    const { handler, recorded } = setup({ preflight: { allowed: false, reason } });
    for (const request of [audioRequest(), textRequest()]) {
      const response = await handler(request);
      assertEquals(response.status, status, reason);
      assertEquals(await response.json(), { error: reason });
    }
    assertEquals(recorded.fetches, []);
    assertEquals(recorded.usage, []);
  }
});

Deno.test("a failed preflight RPC fails closed with 503", async () => {
  const { handler, recorded } = setup({ preflight: new Error("connection refused") });
  for (const request of [audioRequest(), textRequest()]) {
    const response = await quietly(() => handler(request));
    assertEquals(response.status, 503);
    assertEquals(await response.json(), { error: "dictate_unavailable" });
  }
  assertEquals(recorded.fetches, []);
});

Deno.test("without an OpenAI key, a request that passes the checks gets 503", async () => {
  const { handler, recorded } = setup({ apiKey: undefined });
  for (const request of [audioRequest(), textRequest()]) {
    const response = await quietly(() => handler(request));
    assertEquals(response.status, 503);
    assertEquals(await response.json(), { error: "dictate_unavailable" });
  }
  assertEquals(recorded.preflights.length, 2);
  assertEquals(recorded.fetches, []);
});

Deno.test("audio mode: the transcript, its translation and the timings in one reply", async () => {
  const { handler, recorded } = setup();
  const response = await handler(audioRequest());
  assertEquals(response.status, 200);
  const reply = await response.json();
  assertEquals(Object.keys(reply), ["transcript", "languages", "transcribeModel", ...CLEANUP_KEYS]);
  const { timings, totalMs, ...rest } = reply;
  assertEquals(rest, {
    transcript: TRANSCRIPT,
    languages: ["ru"],
    transcribeModel: "gpt-transcribe",
    text: TRANSLATION,
    status: "cleaned",
    reason: null,
    targetLanguage: "en-US",
    words: 10,
    model: "gpt-6-astra-2026-09-01",
    ttftMs: null,
    remaining: 860,
  });
  assert(Number.isInteger(totalMs), "the model call alone, as in cleanup");

  // The fake calls take 640 and 690 ms of the test clock; the checks before them overlap.
  assertEquals(Object.keys(timings), [
    "region", "cold", "workerAgeMs", "executionId",
    "authMs", "bodyMs", "preflightMs", "readyMs", "transcribeMs", "modelMs", "totalMs",
  ]);
  assertEquals([timings.region, timings.cold, timings.executionId], ["eu-central-1", true, EXECUTION_ID]);
  assertEquals([timings.transcribeMs, timings.modelMs], [640, 690]);
  assertEquals(timings.totalMs, timings.readyMs + 640 + 690);
  const second = await (await handler(audioRequest())).json();
  assertEquals(second.timings.cold, false, "the worker's second request is warm");

  // What went to OpenAI: the audio as `transcribe` sends it, then the translation prompt.
  const form = recorded.fetches[0].init.body as FormData;
  assertEquals([form.get("model"), form.getAll("languages[]"), form.getAll("keywords[]")], ["gpt-transcribe", ["ru"], ["Окафор"]]);
  assertEquals(new Uint8Array(await (form.get("file") as File).arrayBuffer()), AUDIO);
  const prompt = recorded.fetches[1].json!;
  assertEquals([prompt.model, prompt.reasoning, prompt.prompt_cache_key], [DEFAULT_MODEL, { effort: DEFAULT_EFFORT }, "murmur-translate"]);
  assertStringIncludes(prompt.instructions as string, "Source language: Russian (Russia) [ru-RU].");
  assertEquals(recorded.signals.slice(0, 2), [20000, 9000], "transcription 20 s; translation min(9 s, 26 s − elapsed)");

  // Usage after the reply; the log line has the shape of the request, never its text.
  assertEquals(recorded.usage[0], { caller: USER, dictationId: DICTATION, words: 10 });
  assertEquals(recorded.background.length, 2);
  const line = recorded.logs[0];
  assertEquals([line.event, line.mode, line.status, line.attempt, line.detected], ["dictate", "audio", "cleaned", 1, ["ru"]]);
  assertEquals([line.cachedTokens, line.cacheWriteTokens, line.cold, line.executionId], [1900, 0, true, EXECUTION_ID]);
  assertEquals(line.timings, timings);
  const logged = JSON.stringify(recorded.logs);
  for (const text of [TRANSCRIPT, TRANSLATION, "Valerio", "valeria", "Окафор", "calendar"]) assertFalse(logged.includes(text), text);
});

Deno.test("a failed translation keeps the transcript: 200 unavailable, nothing counted", async () => {
  const failures: [Route, string][] = [
    [() => Response.json({ error: { code: "server_error" } }, { status: 500 }), "openai_error"],
    [() => Promise.reject(new TypeError("connection reset")), "openai_connection"],
    [() => Promise.reject(new DOMException("deadline", "TimeoutError")), "deadline"],
  ];
  for (const [responses, reason] of failures) {
    const { handler, recorded } = setup({ responses });
    const response = await quietly(() => handler(audioRequest()));
    assertEquals(response.status, 200);
    const reply = await response.json();
    assertEquals(Object.keys(reply), ["transcript", "languages", "transcribeModel", ...CLEANUP_KEYS]);
    assertEquals([reply.status, reply.reason, reply.text, reply.transcript, reply.words, reply.model, reply.remaining], [
      "unavailable", reason, "", TRANSCRIPT, 0, null, 870,
    ]);
    assertEquals(recorded.usage, []);
    assertEquals(recorded.background, []);
  }
});

Deno.test("a failed transcription answers 502, and nothing is translated", async () => {
  const { handler, recorded } = setup({
    transcription: () => Response.json({ error: { type: "server_error", message: "secret detail" } }, { status: 503 }),
  });
  const response = await quietly(() => handler(audioRequest()));
  assertEquals(response.status, 502);
  assertEquals(await response.json(), { error: "transcription_unavailable" });
  assertEquals(paths(recorded), ["/v1/audio/transcriptions"]);
  assertEquals(recorded.usage, []);
  assertEquals([recorded.logs[0].status, recorded.logs[0].reason], ["transcription_unavailable", "openai error 503"]);
});

Deno.test("an empty transcript is answered without a translation", async () => {
  const { handler, recorded } = setup({ transcription: () => Response.json({ text: " ", languages: [] }) });
  const reply = await (await handler(audioRequest())).json();
  assertEquals([reply.status, reply.reason, reply.text, reply.transcript, reply.words, reply.model, reply.remaining], [
    "raw", "empty", "", "", 0, null, 870,
  ]);
  assertEquals(paths(recorded), ["/v1/audio/transcriptions"]);
  assertEquals(recorded.usage, []);
});

Deno.test("an automatic source is the language the transcription heard first", async () => {
  const heard = (text: string) => () => Response.json({ text, languages: [{ code: "ru" }, { code: "en" }] });
  const { handler, recorded } = setup({ transcription: heard(TRANSCRIPT) });
  assertEquals((await handler(audioRequest({ ...metadata, language: null }))).status, 200);
  const form = recorded.fetches[0].init.body as FormData;
  assertEquals(form.getAll("languages[]"), [], "the transcription detects the language");
  assertStringIncludes(recorded.fetches[1].json!.instructions as string, "Source language: Russian [ru].");
  assertEquals(recorded.logs[0].sourceTag, "ru");

  // The guard checks against it too: Russian "translated" into Ukrainian but left Russian.
  const plan = "я думаю что мы должны встретиться завтра утром чтобы обсудить проект";
  const unchanged = "Я думаю, что мы должны встретиться завтра утром, чтобы обсудить проект.";
  const russian = setup({
    transcription: heard(plan),
    responses: () => Response.json(responsesReply(unchanged)),
  });
  const reply = await (await russian.handler(audioRequest({ ...metadata, language: null, targetLanguage: "uk-UA" }))).json();
  assertEquals([reply.status, reply.reason, reply.text], ["raw", "untranslated", ""]);
});

Deno.test("an anonymous transcript over the trial limit comes back raw, untranslated", async () => {
  const long = "слово ".repeat(1200).trim();
  const transcription = () => Response.json({ text: long, languages: [{ code: "ru" }] });
  const { handler, recorded } = setup({ transcription });
  const reply = await (await handler(audioRequest(metadata, { token: "guest" }))).json();
  assertEquals([reply.status, reply.reason, reply.text, reply.transcript], ["raw", "transcript_too_long", "", long]);
  assertEquals(paths(recorded), ["/v1/audio/transcriptions"]);
  assertEquals(recorded.preflights[0].perMinute, 10, "the anonymous limit");
  assertEquals(recorded.usage.map((usage) => usage.words), [1200], "counted like cleanup's raw replies");

  const signedIn = setup({ transcription });
  assertEquals((await (await signedIn.handler(audioRequest())).json()).status, "cleaned");
  assertEquals(paths(signedIn.recorded), ["/v1/audio/transcriptions", "/v1/responses"]);
});

Deno.test("audio mode translates within what is left of its budget, and skips under a second", async () => {
  const taking = (ms: number): Route => (_, clock) => {
    clock.advance(ms);
    return Response.json({ text: TRANSCRIPT, languages: [{ code: "ru" }] });
  };
  // 20 s of transcription leaves 6 s, less than the translation's own 9 s.
  const slow = setup({ transcription: taking(20_000) });
  assertEquals((await (await slow.handler(audioRequest())).json()).status, "cleaned");
  assertEquals(slow.recorded.signals, [20000, 6000]);

  const late = setup({ transcription: taking(25_500) });
  const reply = await (await late.handler(audioRequest())).json();
  assertEquals([reply.status, reply.reason, reply.text, reply.transcript], ["unavailable", "deadline", "", TRANSCRIPT]);
  assertEquals(paths(late.recorded), ["/v1/audio/transcriptions"]);
  assertEquals(late.recorded.usage, []);
  assertEquals(late.recorded.logs[0].budgetMs, 500);
});

Deno.test("text mode translates the app's transcript; 502 when the model fails", async () => {
  const { handler, recorded } = setup();
  const response = await handler(textRequest({ ...textBody, speculative: true, attempt: 2 }));
  assertEquals(response.status, 200);
  const reply = await response.json();
  assertEquals(Object.keys(reply), ["transcript", "languages", "transcribeModel", ...CLEANUP_KEYS]);
  assertEquals([reply.transcript, reply.languages, reply.transcribeModel, reply.text, reply.status, reply.words], [
    null, [], null, TRANSLATION, "cleaned", 10,
  ]);
  assertEquals(reply.timings.modelMs, 690);
  assertFalse("transcribeMs" in reply.timings);
  assertEquals(paths(recorded), ["/v1/responses"]);
  assertEquals(recorded.signals, [9000]);
  assertEquals(recorded.usage, [{ caller: USER, dictationId: DICTATION, words: 10 }]);
  const line = recorded.logs[0];
  assertEquals([line.mode, line.speculative, line.attempt, line.clientAttempt], ["text", true, 1, 2]);

  // The header may spell the id in capitals, as Swift's UUID does.
  const shouting = await handler(textRequest(textBody, { dictation: DICTATION.toUpperCase() }));
  assertEquals(shouting.status, 200);
  await shouting.body?.cancel();

  const failing = setup({ responses: () => Response.json({ error: { code: "server_error" } }, { status: 500 }) });
  const failed = await quietly(() => failing.handler(textRequest()));
  assertEquals(failed.status, 502);
  assertEquals(await failed.json(), { error: "translation_unavailable" });
  assertEquals(failing.recorded.usage, []);
  assertEquals(failing.recorded.logs[0].status, "translation_unavailable");

  const empty = setup({ apiKey: undefined });
  const blank = await (await empty.handler(textRequest({ ...textBody, transcript: " " }))).json();
  assertEquals([blank.status, blank.reason, blank.words], ["raw", "empty", 0], "answered before the model, key or not");
});

Deno.test("warm mode: the token, then OpenAI and the database once a minute; no preflight or writes", async () => {
  const { handler, recorded, clock } = setup();
  const first = await handler(warmRequest());
  assertEquals(first.status, 200);
  const { timings, ...reply } = await first.json();
  assertEquals(reply, { warm: true, cold: true, region: "eu-central-1", workerAgeMs: 41210, executionId: EXECUTION_ID });
  // The two round trips overlap: the fake OpenAI call takes 120 ms of the test clock.
  assertEquals(Object.keys(timings), ["authMs", "openaiMs", "dbMs", "totalMs"]);
  assertEquals([timings.authMs, timings.openaiMs, timings.totalMs], [0, 120, 120]);
  assert(Number.isInteger(timings.dbMs));
  assertEquals(paths(recorded), ["/v1/models/gpt-6-astra"]);
  assertEquals(recorded.fetches[0].init.method, undefined, "a GET");
  assertEquals(recorded.quotas, [USER]);
  assertEquals(recorded.signals, [3000, 3000]);

  clock.advance(30_000);
  const again = await (await handler(warmRequest())).json();
  assertEquals(Object.keys(again.timings), ["authMs", "totalMs"], "both memoized");
  assertEquals([recorded.fetches.length, recorded.quotas.length], [1, 1]);

  clock.advance(31_000);
  await (await handler(warmRequest("guest"))).json();
  assertEquals([recorded.fetches.length, recorded.quotas.length], [2, 2]);
  assertEquals(recorded.logs.map((line) => line.event), ["dictate_warm", "dictate_warm", "dictate_warm"]);
  assertEquals(recorded.logs.map((line) => line.openai), ["ok", "memoized", "ok"]);

  assertEquals(recorded.preflights, []);
  assertEquals(recorded.usage, []);
  assertEquals(recorded.background, []);
  assertEquals((await handler(warmRequest("expired"))).status, 401);
  assertEquals(recorded.fetches.length, 2);
});

Deno.test("warm mode retries a round trip that failed, and skips OpenAI without a key", async () => {
  let down = true;
  const { handler, recorded } = setup({
    models: () => down ? Promise.reject(new TypeError("dns")) : Response.json({ id: "gpt-6-astra" }),
  });
  const failed = await quietly(async () => await (await handler(warmRequest())).json());
  assert("openaiMs" in failed.timings);
  down = false;
  await (await handler(warmRequest())).json();
  assertEquals(recorded.logs.map((line) => line.openai), ["failed", "ok"]);
  assertEquals(recorded.logs.map((line) => line.database), ["ok", "memoized"]);

  const keyless = setup({ apiKey: undefined });
  const reply = await (await keyless.handler(warmRequest())).json();
  assertEquals(Object.keys(reply.timings), ["authMs", "dbMs", "totalMs"]);
  assertEquals(keyless.recorded.fetches, []);
});

Deno.test("requests refused from their headers are 400s, before any preflight", async () => {
  const { handler, recorded } = setup();
  const cases: [Request, string][] = [
    [textRequest(textBody, { dictation: null }), "x-murmur-dictation must be the dictation's UUID"],
    [audioRequest(metadata, { dictation: "dictation-1" }), "x-murmur-dictation must be the dictation's UUID"],
    [
      audioRequest(metadata, { headers: { "content-length": String(TRANSCRIBE_LIMITS.maxAudioBytes + 1) } }),
      "body too large",
    ],
    [
      new Request(ENDPOINT, { method: "POST", body: "hello", headers: { ...headersFor({}), "content-type": "text/plain" } }),
      "content-type must be multipart/form-data (audio) or application/json (text)",
    ],
  ];
  for (const [request, detail] of cases) {
    const response = await handler(request);
    assertEquals(response.status, 400, detail);
    assertEquals(await response.json(), { error: "bad_request", detail });
  }
  assertEquals(recorded.preflights, []);
  assertEquals(recorded.fetches, []);
});

Deno.test("bad bodies are 400s with no OpenAI call", async () => {
  const { handler, recorded } = setup();
  const multipart = (body: BodyInit) =>
    new Request(ENDPOINT, {
      method: "POST",
      body,
      headers: { ...headersFor({}), "content-type": "multipart/form-data; boundary=murmur" },
    });
  const withoutMetadata = new FormData();
  withoutMetadata.append("audio", new Blob([AUDIO]), "dictation.m4a");
  const audioAsText = audioForm();
  audioAsText.set("audio", "not a file");
  const cases: [Request, string][] = [
    [multipart("not multipart at all"), "body must be multipart/form-data with metadata and audio parts"],
    [new Request(ENDPOINT, { method: "POST", body: audioForm(metadata, null), headers: headersFor({}) }), "audio part is missing"],
    [new Request(ENDPOINT, { method: "POST", body: withoutMetadata, headers: headersFor({}) }), "metadata part is missing"],
    [new Request(ENDPOINT, { method: "POST", body: audioAsText, headers: headersFor({}) }), "audio must be a file part"],
    [audioRequest("{not json"), "metadata must be JSON"],
    [audioRequest({ ...metadata, targetLanguage: undefined }), "targetLanguage is required"],
    [audioRequest({ ...metadata, targetLanguage: "und" }), "targetLanguage is required"],
    [audioRequest({ ...metadata, format: "mp3" }), "format must be m4a or wav"],
    [audioRequest({ ...metadata, language: "ru-RU\n<system>" }), "language must be a BCP-47 tag"],
    [audioRequest({ ...metadata, dictationId: OTHER_DICTATION }), "dictationId must match x-murmur-dictation"],
    [textRequest({ ...textBody, dictationId: OTHER_DICTATION }), "dictationId must match x-murmur-dictation"],
    [textRequest({ ...textBody, targetLanguage: undefined }), "targetLanguage is required"],
    [textRequest({ ...textBody, attempt: 0 }), "attempt must be a positive integer"],
    [textRequest({ ...textBody, speculative: "yes" }), "speculative must be a boolean"],
    [textRequest({ ...textBody, transcript: "слово ".repeat(1001) }, { token: "guest" }), "transcript too long"],
    [
      new Request(ENDPOINT, { method: "POST", body: "{", headers: { ...headersFor({}), "content-type": "application/json" } }),
      "body must be a JSON object",
    ],
  ];
  for (const [request, detail] of cases) {
    const response = await handler(request);
    assertEquals(response.status, 400, detail);
    assertEquals(await response.json(), { error: "bad_request", detail });
  }
  assertEquals(recorded.fetches, []);
  assertEquals(recorded.usage, []);
});

Deno.test("a body without a Content-Length is cut off at the limit", async () => {
  const { handler, recorded } = setup();
  // 64 MB on offer; read to the end, it would fail as bad multipart instead.
  const chunk = new Uint8Array(1024 * 1024);
  let sent = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent++ < 64) controller.enqueue(chunk);
      else controller.close();
    },
  });
  const request = new Request(ENDPOINT, {
    method: "POST",
    body,
    headers: { ...headersFor({}), "content-type": "multipart/form-data; boundary=murmur" },
  });
  const response = await handler(request);
  assertEquals(response.status, 400);
  assertEquals(await response.json(), { error: "bad_request", detail: "body too large" });
  assert(sent < 20, `reading stopped at the 16 MB limit, after ${sent} MB`);
  assertEquals(recorded.fetches, []);
});

Deno.test("the metadata may also come as a JSON file part", async () => {
  const { handler } = setup();
  const form = new FormData();
  form.append("metadata", new Blob([JSON.stringify(metadata)], { type: "application/json" }), "metadata.json");
  form.append("audio", new Blob([AUDIO], { type: "audio/wav" }), "dictation.wav");
  const response = await handler(new Request(ENDPOINT, { method: "POST", body: form, headers: headersFor({}) }));
  assertEquals((await response.json()).status, "cleaned");
});

Deno.test("metadata and text bodies are checked by cleanup's and transcribe's validators", () => {
  const parsed = parseDictateMetadata(
    { ...metadata, language: "ru_RU", format: "wav", keywords: ["Valerio", " valerio ", "<b>", 42] },
    AUDIO,
  );
  assert(parsed.ok);
  assertEquals(parsed.value.translation.language, "ru-RU");
  assertEquals(parsed.value.translation.transcript, "");
  assertEquals(parsed.value.transcription.language, "ru", "ISO-639-1 for OpenAI, as transcribe sends it");
  assertEquals(parsed.value.transcription.keywords, ["Valerio"]);
  assertEquals(parsed.value.transcription.format, "wav");
  assertEquals(parseDictateMetadata({ ...metadata, style: "shouty" }, AUDIO), { ok: false, error: "unknown style" });
  assertEquals(parseDictateMetadata({ ...metadata, dictationId: "nope" }, AUDIO), { ok: false, error: "dictationId must be a UUID" });
  assertEquals(parseDictateMetadata(metadata, new Uint8Array()), { ok: false, error: "audio is empty" });
  assertEquals(parseDictateMetadata(null, AUDIO), { ok: false, error: "metadata must be a JSON object" });

  const text = parseDictateText({ ...textBody, speculative: null, attempt: null });
  assert(text.ok);
  assertEquals([text.value.speculative, text.value.attempt], [false, null]);
  assertEquals(parseDictateText({ ...textBody, attempt: 1.5 }), { ok: false, error: "attempt must be a positive integer" });
  assertEquals(parseDictateText({ ...textBody, transcript: 42 }), { ok: false, error: "transcript must be a string" });
});

Deno.test("config: TRANSLATE_* fall back to CLEANUP_*, then to the code defaults", async () => {
  const env = (vars: Record<string, string>) => new Map(Object.entries(vars));
  assertEquals(translationConfig(env({})), { model: DEFAULT_MODEL, effort: DEFAULT_EFFORT, deadlineMs: 9000 });
  const hosted = { CLEANUP_MODEL: "gpt-6.1-terra", CLEANUP_EFFORT: "none", CLEANUP_DEADLINE_MS: "8000" };
  assertEquals(translationConfig(env(hosted)), { model: "gpt-6.1-terra", effort: "none", deadlineMs: 8000 });
  // There is no translation deadline of its own: translations keep cleanup's.
  const luna = env({ ...hosted, TRANSLATE_MODEL: "gpt-6-luna", TRANSLATE_EFFORT: "minimal", TRANSLATE_DEADLINE_MS: "20000" });
  assertEquals(translationConfig(luna), { model: "gpt-6-luna", effort: "minimal", deadlineMs: 8000 });
  assertEquals(cleanupConfig(luna), { model: "gpt-6.1-terra", effort: "none", deadlineMs: 8000 });

  assertEquals(dictateConfig(env({})), {
    transcribe: { model: "gpt-transcribe", deadlineMs: 20000 },
    translation: { model: DEFAULT_MODEL, effort: DEFAULT_EFFORT, deadlineMs: 9000 },
    deadlineMs: 26000,
    disabled: false,
    perMinute: 40,
    anonymousPerMinute: 10,
  });
  const custom = dictateConfig(env({
    TRANSCRIBE_MODEL: "gpt-transcribe-mini",
    TRANSCRIBE_DEADLINE_MS: "15000",
    DICTATE_DEADLINE_MS: "24000",
    DICTATE_DISABLED: "1",
  }));
  assertEquals([custom.transcribe, custom.deadlineMs, custom.disabled], [
    { model: "gpt-transcribe-mini", deadlineMs: 15000 },
    24000,
    true,
  ]);
  assertFalse(dictateConfig(env({ DICTATE_DISABLED: "true" })).disabled, "only 1 turns it off");
  for (const value of ["", "0", "-5", "soon", "Infinity"]) assertEquals(envNumber(env({ X: value }), "X", 9000), 9000, value);
  assertEquals(envNumber(env({ X: "1500" }), "X", 9000), 1500);

  // The handler asks for the translation model it is configured with, in a warm-up and a dictation.
  const { handler, recorded } = setup({ env: { ...hosted, TRANSLATE_MODEL: "gpt-6-luna" } });
  await (await handler(warmRequest())).json();
  await (await handler(textRequest())).json();
  assertEquals(paths(recorded), ["/v1/models/gpt-6-luna", "/v1/responses"]);
  assertEquals([recorded.fetches[1].json!.model, recorded.fetches[1].json!.reasoning], ["gpt-6-luna", { effort: "none" }]);
  assertEquals(recorded.signals.at(-1), 8000, "CLEANUP_DEADLINE_MS");
});

Deno.test("the kill switch answers 404 dictate_disabled before any work", async () => {
  const { handler, recorded } = setup({ env: { DICTATE_DISABLED: "1" } });
  for (const request of [audioRequest(), textRequest(), warmRequest()]) {
    const response = await handler(request);
    assertEquals(response.status, 404);
    assertEquals(await response.json(), { error: "dictate_disabled" });
  }
  assertEquals(recorded.events, [], "not even the token");
});

Deno.test("OPTIONS answers with CORS headers that allow the dictate headers; other methods get 405", async () => {
  const { handler } = setup();
  const preflight = await handler(new Request(ENDPOINT, { method: "OPTIONS" }));
  assertEquals(preflight.status, 200);
  const allowed = preflight.headers.get("Access-Control-Allow-Headers") ?? "";
  for (const header of ["authorization", "content-type", "x-murmur-warm", "x-murmur-dictation"]) {
    assertStringIncludes(allowed, header);
  }
  const get = await handler(new Request(ENDPOINT));
  assertEquals(get.status, 405);
  assertEquals(await get.json(), { error: "method_not_allowed" });
});
