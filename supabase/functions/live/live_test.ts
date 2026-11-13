import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { Caller } from "../_shared/http.ts";
import { createLiveHandler, type LiveConfig, liveConfig, type LiveDeps, parseStart, sessionBudgetMs } from "../_shared/live.ts";
import type { LiveProvider, LiveTarget } from "../_shared/live/adapter.ts";
import { soniox } from "../_shared/live/soniox.ts";
import type { Preflight } from "../_shared/preflight.ts";
import type { RequestStart } from "../_shared/timing.ts";

const ENDPOINT = "https://project.test/functions/v1/live";
const DICTATION = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const OTHER_DICTATION = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
const USER: Caller = { userId: "1b4e28ba-2fa1-41d2-883f-0016d3cca427", isAnonymous: false };
const GUEST: Caller = { userId: "6fa459ea-ee8a-4ca4-894e-db77e160355e", isAnonymous: true };
/** A worker that has just booted: the whole budget is left. */
const WORKER: RequestStart = { cold: true, workerAgeMs: 0, region: "eu-central-1", executionId: "worker-a" };
const ALLOWED: Preflight = { allowed: true, reason: null, plan: "basic", remaining: 870, attempt: 1 };
const BENCH_KEY = "bench-key";
const SONIOX: LiveTarget = { url: "wss://stt-rt.soniox.com/transcribe-websocket", headers: { Authorization: "Bearer soniox-key" } };
const READY = {
  type: "ready",
  v: 1,
  provider: "soniox",
  audio: { rate: 16000, maxChunkMs: 250 },
  budgetSeconds: 140,
  region: "eu-central-1",
  caps: { languageDetection: true },
  policy: { hedgeAfterMs: 1000, finalizeDeadlineMs: 2500 },
};

/**
 * A WebSocket the test drives from the other end: what was sent to it, and how it was closed. Like
 * a real one it is connecting until the other end opens it, and can't send before that.
 */
class FakeSocket {
  readyState: number = WebSocket.CONNECTING;
  binaryType = "blob";
  sent: (string | ArrayBuffer)[] = [];
  closedWith: { code: number; reason: string } | null = null;
  /** A close waits for the other end, as a real one does, until `drop` completes it. */
  lingers = false;
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: string | ArrayBuffer }) => void) | null = null;
  onclose: ((event: { code: number }) => void) | null = null;

  send(data: string | ArrayBuffer) {
    if (this.readyState === WebSocket.CONNECTING) throw new DOMException("the socket isn't open yet", "InvalidStateError");
    // A real socket drops what is sent once it is closing.
    if (this.readyState === WebSocket.OPEN) this.sent.push(data);
  }

  close(code = 1005, reason = "") {
    if (this.readyState >= WebSocket.CLOSING) return;
    this.closedWith = { code, reason };
    if (this.lingers) {
      this.readyState = WebSocket.CLOSING;
      return;
    }
    this.readyState = WebSocket.CLOSED;
    this.onclose?.({ code });
  }

  /** The other end connected, unless this end gave up first. */
  open() {
    if (this.readyState !== WebSocket.CONNECTING) return;
    this.readyState = WebSocket.OPEN;
    this.onopen?.();
  }

  /** A message from the other end. */
  receive(data: string | ArrayBuffer) {
    this.onmessage?.({ data });
  }

  /** The other end began to close: nothing more can be sent, and its close is still to come. */
  beginClose() {
    this.readyState = WebSocket.CLOSING;
  }

  /** The other end closed the socket, or the connection was lost. */
  drop(code = 1006) {
    if (this.readyState === WebSocket.CLOSED) return;
    this.readyState = WebSocket.CLOSED;
    this.onclose?.({ code });
  }

  /** The JSON messages sent so far, parsed. */
  get messages(): Record<string, unknown>[] {
    return this.sent.filter((item): item is string => typeof item === "string").map((item) => JSON.parse(item));
  }
}

/**
 * The handler's clock and its timers, moved by hand. It starts away from 0, so an absolute
 * reading would show.
 */
class FakeClock {
  now = 1000;
  #timers: { at: number; work: () => void }[] = [];

  schedule(ms: number, work: () => void): () => void {
    const timer = { at: this.now + ms, work };
    this.#timers.push(timer);
    return () => {
      this.#timers = this.#timers.filter((other) => other !== timer);
    };
  }

  /** Moves the clock on by `ms`, running what comes due on the way, each at its own time. */
  advance(ms: number) {
    const until = this.now + ms;
    for (;;) {
      const due = this.#timers.filter((timer) => timer.at <= until).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      this.#timers = this.#timers.filter((timer) => timer !== due);
      this.now = Math.max(this.now, due.at);
      due.work();
    }
    this.now = until;
  }

  /** How many timers are still to run. */
  get pending(): number {
    return this.#timers.length;
  }
}

/**
 * The requests whose socket was upgraded. Deno closes their headers then (reading one throws
 * "Request closed"), and so do the requests `upgradeRequest` makes.
 */
const upgraded = new WeakSet<Request>();

interface Setup {
  env?: Record<string, string>;
  /** Fields over the env's configuration: a provider the env doesn't know. */
  config?: Partial<LiveConfig>;
  /** Fields over WORKER: an older worker. */
  worker?: Partial<RequestStart>;
  /** The preflight's answer: fields over ALLOWED, an error it throws, or a promise the test settles. */
  preflight?: Partial<Preflight> | Error | (() => Promise<Preflight>);
  adapters?: Record<string, LiveProvider>;
  authenticate?: LiveDeps["authenticate"];
  connect?: LiveDeps["connect"];
}

/** A handler on fakes, and everything it did. */
function setup(options: Setup = {}) {
  const clock = new FakeClock();
  const recorded = {
    authenticated: 0,
    upgrades: 0,
    connected: [] as LiveTarget[],
    preflights: [] as { caller: Caller; scope: string; dictationId: string; perMinute: number }[],
    usage: [] as { caller: Caller; dictationId: string; words: number }[],
    kept: [] as PromiseLike<unknown>[],
    logs: [] as Record<string, unknown>[],
  };
  /** The app's end of each upgraded socket, and the provider's end of each connection, in order. */
  const clients: FakeSocket[] = [];
  const providers: FakeSocket[] = [];
  const handler = createLiveHandler({
    config: { ...liveConfig(new Map(Object.entries({ SONIOX_API_KEY: "soniox-key", ...options.env }))), ...options.config },
    authenticate: options.authenticate ?? ((request) => {
      recorded.authenticated++;
      const token = request.headers.get("authorization");
      return Promise.resolve(token === "Bearer user" ? USER : token === "Bearer guest" ? GUEST : null);
    }),
    preflight: async (caller, scope, dictationId, perMinute) => {
      recorded.preflights.push({ caller, scope, dictationId, perMinute });
      const answer = typeof options.preflight === "function" ? await options.preflight() : options.preflight;
      if (answer instanceof Error) throw answer;
      return { ...ALLOWED, ...answer };
    },
    recordUsage: (caller, dictationId, words) => {
      recorded.usage.push({ caller, dictationId, words });
      return Promise.resolve();
    },
    background: (work) => void recorded.kept.push(work),
    upgrade: (request) => {
      upgraded.add(request);
      recorded.upgrades++;
      const socket = new FakeSocket();
      clients.push(socket);
      return { socket: socket as unknown as WebSocket, response: new Response(null, { status: 200 }) };
    },
    connect: options.connect ?? ((target) => {
      recorded.connected.push(target);
      const socket = new FakeSocket();
      providers.push(socket);
      return socket as unknown as WebSocket;
    }),
    adapters: options.adapters ?? { soniox },
    worker: () => ({ ...WORKER, ...options.worker }),
    now: () => clock.now,
    schedule: (ms, work) => clock.schedule(ms, work),
    log: (line) => void recorded.logs.push(JSON.parse(line)),
  });
  return { handler, recorded, clock, clients, providers };
}

type Harness = ReturnType<typeof setup>;

interface RequestOptions {
  /** The bearer token: "user", "guest", anything else is invalid; null sends none. */
  token?: string | null;
  /** The x-murmur-dictation header; null leaves it out. */
  dictation?: string | null;
  query?: string;
  headers?: Record<string, string>;
}

function upgradeRequest({ token = "user", dictation = DICTATION, query = "", headers = {} }: RequestOptions = {}): Request {
  const request = new Request(`${ENDPOINT}${query}`, {
    headers: {
      upgrade: "websocket",
      ...(token === null ? {} : { authorization: `Bearer ${token}` }),
      ...(dictation === null ? {} : { "x-murmur-dictation": dictation }),
      ...headers,
    },
  });
  return new Proxy(request, {
    get(target, property, receiver) {
      if (property === "headers" && upgraded.has(receiver)) throw new TypeError("Request closed");
      const value = Reflect.get(target, property, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/** The app's first message; `fields` replace its own. */
function startMessage(fields: Record<string, unknown> = {}): string {
  return JSON.stringify({
    type: "start",
    v: 1,
    dictationId: DICTATION,
    language: null,
    languages: ["ru-RU", "en-US"],
    keywords: ["Окафор"],
    audio: { format: "pcm_s16le", rate: 16000, channels: 1 },
    client: "murmur-ios 1.0 (42)",
    ...fields,
  });
}

const finalize = (audioMs = 200) => JSON.stringify({ type: "finalize", audioMs });

function frame(bytes: number): ArrayBuffer {
  return new Uint8Array(bytes).buffer;
}

// Soniox's side, as its adapter reads it.
const settled = (text: string, language = "ru") => ({ text, is_final: true, language });
const unsettled = (text: string, language = "ru") => ({ text, is_final: false, language });
const FIN = { text: "<fin>", is_final: true };
const reply = (...tokens: Record<string, unknown>[]) =>
  JSON.stringify({ tokens, final_audio_proc_ms: 0, total_audio_proc_ms: 0 });

/** Lets promises that are already settled run their course: the preflight's answer. */
const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

/** A socket as far as `ready`: upgraded, its preflight passed, `start` in and the provider's socket open. */
async function session(h: Harness, options: { request?: RequestOptions; start?: Record<string, unknown> } = {}) {
  const response = await h.handler(upgradeRequest(options.request));
  assertEquals(response.status, 200);
  const client = h.clients.at(-1)!;
  client.open();
  await tick();
  client.receive(startMessage(options.start));
  const provider = h.providers.at(-1)!;
  provider.open();
  assertEquals(client.messages.at(-1)?.type, "ready");
  return { client, provider };
}

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

/** A service that takes the language in its URL and speaks in plain text frames. */
const late: LiveProvider = {
  adapter: (options) => ({
    caps: { languageDetection: false },
    target: () => ({ url: `wss://late.test/listen?language=${options.language ?? "multi"}`, protocols: ["token", options.apiKey] }),
    configure: () => [],
    audio: (chunk) => chunk,
    finalize: () => ["finalize"],
    end: () => ["bye"],
    parse: (data) => data === "done" ? [{ kind: "closed" }] : [{ kind: "text", stable: String(data), volatile: "" }],
  }),
};
const WITH_LATE: Partial<LiveConfig> = {
  providers: { soniox: { apiKey: "soniox-key", model: "stt-rt-v6" }, late: { apiKey: "late-key", model: "late-1" } },
};

Deno.test("a request that isn't an upgrade is refused before its token is looked at", async () => {
  const h = setup();
  const plain = new Request(ENDPOINT, { headers: { authorization: "Bearer user", "x-murmur-dictation": DICTATION } });
  const response = await h.handler(plain);
  assertEquals(response.status, 400);
  assertEquals(await response.json(), { error: "bad_request", detail: "a WebSocket upgrade is required" });
  assertEquals([h.recorded.authenticated, h.recorded.upgrades], [0, 0]);
});

Deno.test("the kill switch, an unknown provider and a missing key each answer 503 before any token check", async () => {
  const closed: Record<string, string>[] = [{ LIVE_DISABLED: "1" }, { LIVE_PROVIDER: "whisperer" }, { SONIOX_API_KEY: "" }];
  for (const env of closed) {
    const h = setup({ env });
    const response = await h.handler(upgradeRequest());
    assertEquals(response.status, 503, JSON.stringify(env));
    assertEquals(await response.json(), { error: "live_unavailable" });
    assertEquals([h.recorded.authenticated, h.recorded.upgrades], [0, 0]);
  }
});

Deno.test("no valid token → 401, and a token check that fails → 503; neither is upgraded", async () => {
  const h = setup();
  for (const token of [null, "expired"]) {
    const response = await h.handler(upgradeRequest({ token }));
    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "unauthorized" });
  }
  assertEquals([h.recorded.upgrades, h.recorded.preflights.length, h.recorded.connected.length], [0, 0, 0]);

  const broken = setup({ authenticate: () => Promise.reject(new Error("JWKS unreachable")) });
  const response = await quietly(() => broken.handler(upgradeRequest()));
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { error: "live_unavailable" });
  assertEquals(broken.recorded.upgrades, 0);
});

Deno.test("the upgrade must name its dictation in x-murmur-dictation", async () => {
  const h = setup();
  for (const dictation of [null, "", "not-a-uuid"]) {
    const response = await h.handler(upgradeRequest({ dictation }));
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "bad_request", detail: "x-murmur-dictation must be the dictation's UUID" });
  }
  assertEquals(h.recorded.upgrades, 0);
});

Deno.test("a caller's fourth socket on the worker is refused until one of the three ends", async () => {
  const h = setup();
  for (let index = 0; index < 3; index++) assertEquals((await h.handler(upgradeRequest())).status, 200);
  const fourth = await h.handler(upgradeRequest());
  assertEquals(fourth.status, 429);
  assertEquals(await fourth.json(), { error: "too_many_sockets" });
  // Another caller has three of their own.
  assertEquals((await h.handler(upgradeRequest({ token: "guest" }))).status, 200);

  // The app closed one, and the relay ended another.
  h.clients[0].drop(1000);
  h.clients[1].open();
  h.clients[1].receive("not a message");
  assertEquals(h.clients[1].closedWith?.code, 1008);
  assertEquals((await h.handler(upgradeRequest())).status, 200);
  assertEquals((await h.handler(upgradeRequest())).status, 200);
  assertEquals((await h.handler(upgradeRequest())).status, 429);
  assertEquals(h.recorded.upgrades, 6);
});

Deno.test("the preflight and the provider's connection start at the upgrade, from the headers alone", async () => {
  const h = setup();
  await h.handler(upgradeRequest({ dictation: ` ${DICTATION} ` }));
  h.clients[0].open();
  assertEquals(h.recorded.preflights, [{ caller: USER, scope: "live", dictationId: DICTATION, perMinute: 40 }]);
  assertEquals(h.recorded.connected, [SONIOX]);
  assertEquals(h.providers[0].binaryType, "arraybuffer");
  assertEquals(h.clients[0].binaryType, "arraybuffer");
  await tick();
  assertEquals(h.clients[0].sent, [], "nothing is said before the app's start");

  // An anonymous caller gets the tighter limit, as in `transcribe` and `dictate`.
  await h.handler(upgradeRequest({ token: "guest" }));
  h.clients[1].open();
  assertEquals(h.recorded.preflights[1], { caller: GUEST, scope: "live", dictationId: DICTATION, perMinute: 10 });
});

Deno.test("ready waits for the start, the preflight and the provider's socket, whichever comes last", async () => {
  const steps = {
    start: (h: Harness) => h.clients[0].receive(startMessage()),
    provider: (h: Harness) => h.providers[0].open(),
  };
  for (const order of [["start", "provider", "preflight"], ["preflight", "start", "provider"], ["preflight", "provider", "start"]] as const) {
    const gate = Promise.withResolvers<Preflight>();
    const h = setup({ preflight: () => gate.promise });
    await h.handler(upgradeRequest());
    h.clients[0].open();
    for (const [index, step] of order.entries()) {
      assertEquals(h.clients[0].sent, [], `${order}: nothing before ${step}`);
      assertEquals(h.providers[0].sent, [], `${order}: nothing reaches the provider before ${step}`);
      if (step === "preflight") gate.resolve(ALLOWED);
      else steps[step](h);
      await tick();
      if (index < order.length - 1) continue;
      assertEquals(h.clients[0].messages, [READY], String(order));
    }
  }
});

Deno.test("audio waits for the pipe, then follows the configuration in the order it came", async () => {
  const gate = Promise.withResolvers<Preflight>();
  const h = setup({ preflight: () => gate.promise });
  await h.handler(upgradeRequest());
  const client = h.clients[0];
  client.open();
  client.receive(startMessage());
  const [first, second, third] = [frame(3200), frame(1600), frame(3200)];
  client.receive(first);
  client.receive(second);
  const provider = h.providers[0];
  provider.open();
  assertEquals(provider.sent, [], "no audio leaves before the preflight has passed");

  gate.resolve(ALLOWED);
  await tick();
  assertEquals(provider.sent.length, 3);
  assertEquals(JSON.parse(provider.sent[0] as string), {
    model: "stt-rt-v6",
    audio_format: "pcm_s16le",
    sample_rate: 16000,
    num_channels: 1,
    language_hints: ["ru", "en"],
    enable_language_identification: true,
    context: { terms: ["Окафор"] },
  });
  assert(provider.sent[1] === first && provider.sent[2] === second, "the audio that waited, in order");
  assertEquals(client.messages, [READY]);

  client.receive(third);
  assert(provider.sent.at(-1) === third, "then straight through");
  // An empty frame carries nothing.
  client.receive(frame(0));
  assertEquals(provider.sent.length, 4);
});

Deno.test("more than 12 s of audio waiting for the provider ends the socket as unavailable", async () => {
  const h = setup();
  await h.handler(upgradeRequest());
  const client = h.clients[0];
  client.open();
  await tick();
  client.receive(startMessage());
  // 48 frames of 250 ms: 12 s, 384,000 bytes.
  for (let index = 0; index < 48; index++) client.receive(frame(8000));
  assertEquals(client.closedWith, null);
  client.receive(frame(640));
  assertEquals(client.messages, [{ type: "error", code: "unavailable", retryable: true }]);
  assertEquals(client.closedWith, { code: 1011, reason: "unavailable" });
  assertEquals(h.providers[0].closedWith?.code, 1000, "the connection still being made is given up");
  assertEquals(h.providers[0].sent, []);
});

Deno.test("a start in another version, or one the relay can't read, ends the socket with 1008", async () => {
  const refused = async (message: string, options: RequestOptions = {}) => {
    const h = setup();
    await h.handler(upgradeRequest(options));
    const client = h.clients[0];
    client.open();
    await tick();
    client.receive(message);
    h.providers[0].open();
    assertEquals(h.providers[0].sent, [], "nothing is streamed");
    assertEquals(h.providers[0].closedWith?.code, 1000);
    assertEquals(client.closedWith?.code, 1008, message);
    return client.messages;
  };
  assertEquals(await refused(startMessage({ v: 2 })), [{ type: "error", code: "unsupported_version", retryable: false }]);
  // A later version may hold anything else: it is still told the version is the trouble.
  assertEquals(await refused(JSON.stringify({ type: "start", v: 3, session: {} })), [
    { type: "error", code: "unsupported_version", retryable: false },
  ]);
  const badRequest = [{ type: "error", code: "bad_request", retryable: false }];
  assertEquals(await refused(startMessage({ dictationId: OTHER_DICTATION })), badRequest);
  assertEquals(await refused(startMessage({ audio: { format: "opus", rate: 48000, channels: 1 } })), badRequest);
  assertEquals(await refused(startMessage({ language: "not a tag!" })), badRequest);
  assertEquals(await refused(startMessage({ v: undefined })), badRequest);
  assertEquals(await refused("not json"), badRequest);
  assertEquals(await refused(JSON.stringify(["start"])), badRequest);
  assertEquals(await refused(finalize()), badRequest, "finalize before any start");
  assertEquals(await refused(startMessage({ pad: "x".repeat(70_000) })), badRequest, "a text frame too long to be read");
});

Deno.test("the start's dictation id is the header's, whatever its case; a second start is refused", async () => {
  const h = setup();
  const { client } = await session(h, {
    request: { dictation: DICTATION.toUpperCase() },
    start: { dictationId: DICTATION },
  });
  assertEquals(client.closedWith, null);
  client.receive(startMessage());
  assertEquals(client.messages.at(-1), { type: "error", code: "bad_request", retryable: false });
  assertEquals(client.closedWith, { code: 1008, reason: "bad_request" });
  assertEquals(h.recorded.logs[0].detail, "a second start");
});

Deno.test("a message of a type the relay doesn't know is ignored", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  client.receive(JSON.stringify({ type: "hint", words: ["later"] }));
  assertEquals(client.messages, [READY]);
  assertEquals(client.closedWith, null);
  assertEquals(provider.sent.length, 1, "only the configuration");
  client.drop(1000);
  assertEquals(h.recorded.logs[0].ignored, 1);
});

Deno.test("a refused preflight ends the socket as limit_reached or rate_limited, with nothing streamed", async () => {
  const cases = [
    ["limit_reached", "limit_reached", false],
    ["rate_limited", "rate_limited", true],
    // A dictation's seventh socket: a rate limit to the app.
    ["too_many_attempts", "rate_limited", true],
  ] as const;
  for (const [reason, code, retryable] of cases) {
    const h = setup({ preflight: { allowed: false, reason, attempt: null } });
    await h.handler(upgradeRequest());
    const client = h.clients[0];
    client.open();
    client.receive(startMessage());
    client.receive(frame(3200));
    h.providers[0].open();
    await tick();
    assertEquals(client.messages, [{ type: "error", code, retryable }], reason);
    assertEquals(client.closedWith, { code: 1000, reason: code });
    assertEquals(h.providers[0].sent, [], "no configuration and no audio");
    assertEquals(h.providers[0].closedWith?.code, 1000);
    assertEquals(h.recorded.usage, []);
    assertEquals([h.recorded.logs[0].outcome, h.recorded.logs[0].detail], [code, reason]);
  }
});

Deno.test("a preflight that fails, or refuses without a reason, fails closed as unavailable", async () => {
  for (const preflight of [new Error("dictation_preflight failed: 57014 canceling statement"), { allowed: false, reason: null }]) {
    const h = setup({ preflight });
    await h.handler(upgradeRequest());
    const client = h.clients[0];
    client.open();
    client.receive(startMessage());
    h.providers[0].open();
    await tick();
    assertEquals(client.messages, [{ type: "error", code: "unavailable", retryable: true }]);
    assertEquals(client.closedWith, { code: 1011, reason: "unavailable" });
    assertEquals(h.providers[0].sent, []);
    assertEquals(h.providers[0].closedWith?.code, 1000);
    assert(String(h.recorded.logs[0].detail).startsWith("preflight "), "the log line says why");
  }
});

Deno.test("partials carry what settled since the last one and all that is unsettled, at most one in 100 ms", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  provider.receive(reply(unsettled("При")));
  assertEquals(client.messages.at(-1), { type: "partial", seq: 1, stable: "", volatile: "При", lang: "ru" });

  // Within 100 ms of it: held back, and merged into one.
  h.clock.advance(30);
  provider.receive(reply(settled("Привет"), unsettled(", как")));
  h.clock.advance(30);
  provider.receive(reply(settled(","), unsettled(" как дела")));
  assertEquals(client.messages.length, 2, "ready and the first partial");
  h.clock.advance(39);
  assertEquals(client.messages.length, 2);
  h.clock.advance(1);
  assertEquals(client.messages.at(-1), { type: "partial", seq: 2, stable: "Привет,", volatile: " как дела", lang: "ru" });

  // Nothing new: nothing is sent.
  provider.receive(reply(unsettled(" как дела")));
  h.clock.advance(500);
  assertEquals(client.messages.length, 3);

  // After a quiet spell the next one goes at once; the settled text is never sent twice.
  provider.receive(reply(settled(" как дела"), unsettled("?")));
  assertEquals(client.messages.at(-1), { type: "partial", seq: 3, stable: " как дела", volatile: "?", lang: "ru" });
  h.clock.advance(100);
  provider.receive(reply(settled("?")));
  assertEquals(client.messages.at(-1), { type: "partial", seq: 4, stable: "?", volatile: "", lang: "ru" });

  // A reply that settled text in two languages is still one partial, in the language of the newest words.
  h.clock.advance(100);
  provider.receive(reply(settled(" Да,"), settled(" hello", "en"), unsettled(" wor", "en")));
  assertEquals(client.messages.at(-1), { type: "partial", seq: 5, stable: " Да, hello", volatile: " wor", lang: "en" });

  // A marker nobody asked for ends nothing.
  h.clock.advance(100);
  provider.receive(reply(unsettled(" world", "en"), FIN));
  assertEquals(client.messages.at(-1), { type: "partial", seq: 6, stable: "", volatile: " world", lang: "en" });
  assertEquals(client.closedWith, null);
  assertEquals(h.recorded.usage, []);
});

Deno.test("a partial carries the last 200 characters of the unsettled text", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  const long = "слово ".repeat(60);
  provider.receive(reply(unsettled(long)));
  const first = client.messages.at(-1)!.volatile as string;
  assertEquals(first.length, 200);
  assert(long.endsWith(first));

  // Never half of a character at the cut.
  h.clock.advance(100);
  const faces = "😀".repeat(150) + "!";
  provider.receive(reply(unsettled(faces)));
  const second = client.messages.at(-1)!.volatile as string;
  assertEquals(second.length, 199);
  assert(faces.endsWith(second) && second.isWellFormed());
});

Deno.test("finalize settles what the provider heard: the final text goes back, counted once, and one log line is written", async () => {
  const h = setup();
  await h.handler(upgradeRequest({ headers: { "x-client-info": "murmur-ios/1.0" } }));
  const client = h.clients[0];
  client.open();
  client.receive(startMessage());
  h.clock.advance(180);
  const provider = h.providers[0];
  provider.open();
  await tick();
  client.receive(frame(3200));
  client.receive(frame(3200));
  h.clock.advance(1020);
  provider.receive(reply(settled("Привет,"), settled(" как"), unsettled(" дела")));
  h.clock.advance(300);

  client.receive(finalize(200));
  const [silence, request] = provider.sent.slice(-2);
  assertEquals((silence as ArrayBuffer).byteLength, 6400, "200 ms of silence first");
  assertEquals(request, '{"type":"finalize"}');
  assertEquals(client.closedWith, null);
  // Nothing follows the app's finalize.
  client.receive(frame(3200));
  assertEquals(provider.sent.at(-1), request);

  h.clock.advance(280);
  provider.receive(reply(settled("  дела?"), settled(" Hello", "en"), FIN));
  assertEquals(client.messages.at(-1), {
    type: "final",
    // Everything settled, trimmed, with runs of spaces closed up.
    text: "Привет, как дела? Hello",
    languages: ["ru", "en"],
    audioMs: 200,
    words: 4,
    remaining: 866,
    timings: {
      region: "eu-central-1",
      cold: true,
      workerAgeMs: 0,
      upstreamMs: 180,
      firstPartialMs: 1200,
      finalizeMs: 280,
      totalMs: 1780,
    },
  });
  assertEquals(client.closedWith, { code: 1000, reason: "final" });
  assertEquals(provider.sent.at(-1), "", "the stream is ended Soniox's way");
  assertEquals(provider.closedWith?.code, 1000);
  assertEquals(h.recorded.usage, [{ caller: USER, dictationId: DICTATION, words: 4 }]);

  // A late reply changes nothing and counts nothing.
  provider.receive(reply(settled(" ещё"), FIN));
  assertEquals(h.recorded.usage.length, 1);
  assertEquals(client.messages.filter((message) => message.type === "final").length, 1);
  assertEquals(h.clock.pending, 0, "no timer outlives the session");

  assertEquals(h.recorded.logs, [{
    event: "live",
    provider: "soniox",
    model: "stt-rt-v6",
    outcome: "final",
    detail: null,
    closeCode: 1000,
    bench: false,
    language: null,
    detected: ["ru", "en"],
    keywords: 1,
    attempt: 1,
    isAnonymous: false,
    finalize: true,
    appAudioMs: 200,
    audioMs: 200,
    sessionMs: 1780,
    budgetMs: 140_000,
    frames: 2,
    bytes: 6400,
    stableChars: 24,
    words: 4,
    partials: 1,
    ignored: 0,
    preflightMs: 180,
    upstreamMs: 180,
    readyMs: 180,
    firstPartialMs: 1200,
    finalizeMs: 280,
    cold: true,
    workerAgeMs: 0,
    region: "eu-central-1",
    executionId: "worker-a",
    client: "murmur-ios/1.0",
  }]);
});

Deno.test("a finalize that comes before the pipe is open waits for its audio", async () => {
  const gate = Promise.withResolvers<Preflight>();
  const h = setup({ preflight: () => gate.promise });
  await h.handler(upgradeRequest());
  const client = h.clients[0];
  client.open();
  client.receive(startMessage({ language: "ru-RU" }));
  const audio = frame(3200);
  client.receive(audio);
  client.receive(finalize(100));
  const provider = h.providers[0];
  provider.open();
  assertEquals(provider.sent, []);

  h.clock.advance(400);
  gate.resolve({ ...ALLOWED, remaining: null });
  await tick();
  assertEquals(provider.sent.length, 4, "the configuration, the audio, the silence, the finalize");
  assert(provider.sent[1] === audio);
  assertEquals(provider.sent[3], '{"type":"finalize"}');
  assertEquals(client.messages.at(-1)?.type, "ready");

  h.clock.advance(100);
  provider.receive(reply(settled("Да."), FIN));
  const final = client.messages.at(-1)!;
  assertEquals([final.type, final.text, final.words, final.audioMs], ["final", "Да.", 1, 100]);
  // No weekly limit on this plan, and the deadline ran from the finalize, not from the pipe.
  assertEquals(final.remaining, null);
  assertEquals((final.timings as Record<string, unknown>).finalizeMs, 500);
});

Deno.test("an empty dictation gets a final with no words, and nothing is counted", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  client.receive(finalize(0));
  provider.receive(reply(FIN));
  const final = client.messages.at(-1)!;
  assertEquals([final.type, final.text, final.languages, final.words, final.remaining], ["final", "", [], 0, 870]);
  assertEquals(client.closedWith, { code: 1000, reason: "final" });
  assertEquals(h.recorded.usage, []);
  assertEquals(h.recorded.logs[0].words, 0);
});

Deno.test("a close without finalize, or before the final text, is a cancel: nothing is counted", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  client.receive(frame(3200));
  provider.receive(reply(settled("Привет")));
  client.drop(1001);
  assertEquals(provider.sent.at(-1), "", "the provider's stream is ended");
  assertEquals(provider.closedWith?.code, 1000);
  assertEquals(h.recorded.usage, []);
  assertEquals(h.recorded.logs.length, 1);
  const line = h.recorded.logs[0];
  assertEquals([line.outcome, line.closeCode, line.finalize, line.words], ["cancelled", 1001, false, null]);
  assertEquals(h.clock.pending, 0);

  // The app gave up waiting after its finalize: the text that then settles goes nowhere.
  const second = await session(h);
  second.provider.receive(reply(settled("Привет")));
  second.client.receive(finalize());
  second.client.drop(1000);
  second.provider.receive(reply(settled(" мир"), FIN));
  assertEquals(h.recorded.usage, []);
  assertEquals([h.recorded.logs[1].outcome, h.recorded.logs[1].finalize], ["cancelled", true]);
  assertEquals(second.client.messages.filter((message) => message.type === "final"), []);

  // The same when the app's close is under way as the text settles: it can't be sent any more.
  const third = await session(h);
  third.client.receive(finalize());
  third.client.beginClose();
  third.provider.receive(reply(settled("Привет, мир"), FIN));
  assertEquals(h.recorded.usage, []);
  assertEquals(h.recorded.logs.length, 2, "the session ends with the app's close");
  third.client.drop(1000);
  assertEquals([h.recorded.logs[2].outcome, h.recorded.logs[2].words], ["cancelled", null]);
});

Deno.test("no final text 2.5 s after finalize ends the socket as finalize_timeout", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  provider.receive(reply(settled("Привет")));
  // 13 s into a quiet session: from the finalize on, only its own deadline runs, not the wait for audio.
  h.clock.advance(13_000);
  client.receive(finalize());
  // A repeat doesn't start the wait again.
  h.clock.advance(1000);
  client.receive(finalize());
  h.clock.advance(1499);
  assertEquals(client.closedWith, null);
  h.clock.advance(1);
  assertEquals(client.messages.at(-1), { type: "error", code: "finalize_timeout", retryable: true });
  assertEquals(client.closedWith, { code: 1000, reason: "finalize_timeout" });
  assertEquals(provider.closedWith?.code, 1000);
  assertEquals(h.recorded.usage, []);
  assertEquals(h.clock.pending, 0);
});

Deno.test("the relay closes the socket itself, with 1012, when its budget is up", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  // Audio keeps coming, so the session is never idle.
  for (let second = 1; second < 140; second++) {
    h.clock.advance(1000);
    client.receive(frame(8000));
  }
  assertEquals(client.closedWith, null);
  h.clock.advance(1000);
  assertEquals(client.messages.at(-1), { type: "error", code: "budget", retryable: true });
  assertEquals(client.closedWith, { code: 1012, reason: "budget" });
  assertEquals(provider.closedWith?.code, 1000);
  assertEquals([h.recorded.logs[0].outcome, h.recorded.logs[0].sessionMs], ["budget", 140_000]);
  assertEquals(h.clock.pending, 0);
});

Deno.test("the budget is what is left of the worker's time, and a worker near its end takes no socket", async () => {
  const budgetOf = async (options: Setup) => {
    const h = setup(options);
    const { client } = await session(h);
    return { h, client, seconds: client.messages[0].budgetSeconds };
  };
  // A fresh worker: the whole bound.
  assertEquals((await budgetOf({})).seconds, 140);
  // The platform ends a worker 150 s after its boot: one that is 60 s old has 85 s for a socket.
  const aged = await budgetOf({ worker: { workerAgeMs: 60_000 } });
  assertEquals(aged.seconds, 85);
  for (let second = 1; second < 85; second++) {
    aged.h.clock.advance(1000);
    aged.client.receive(frame(8000));
  }
  assertEquals(aged.client.closedWith, null);
  aged.h.clock.advance(1000);
  assertEquals(aged.client.closedWith, { code: 1012, reason: "budget" });
  assertEquals(aged.h.recorded.logs[0].budgetMs, 85_000);

  // A paid plan's wall clock raises it: to the bound, and past it with the bound raised too.
  assertEquals((await budgetOf({ worker: { workerAgeMs: 60_000 }, env: { LIVE_WALL_CLOCK_MS: "400000" } })).seconds, 140);
  const paid = { LIVE_WALL_CLOCK_MS: "400000", LIVE_MAX_SESSION_MS: "380000" };
  assertEquals((await budgetOf({ worker: { workerAgeMs: 60_000 }, env: paid })).seconds, 335);
  assertEquals((await budgetOf({ env: paid })).seconds, 380);

  // 20 s is the least worth a socket.
  assertEquals((await budgetOf({ worker: { workerAgeMs: 125_000 } })).seconds, 20);
  for (const workerAgeMs of [125_001, 149_000, 200_000]) {
    const old = setup({ worker: { workerAgeMs } });
    const response = await old.handler(upgradeRequest());
    assertEquals(response.status, 503, String(workerAgeMs));
    assertEquals(await response.json(), { error: "live_unavailable" });
    assertEquals([old.recorded.authenticated, old.recorded.upgrades], [0, 0]);
  }

  const config = liveConfig(new Map());
  assertEquals(sessionBudgetMs(config, WORKER), 140_000);
  assertEquals(sessionBudgetMs(config, { ...WORKER, workerAgeMs: 60_000 }), 85_000);
  assertEquals(sessionBudgetMs(config, { ...WORKER, workerAgeMs: 170_000 }), 0);
});

Deno.test("a socket with no audio for 15 s is closed as idle", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  h.clock.advance(10_000);
  client.receive(frame(3200));
  h.clock.advance(14_999);
  assertEquals(client.closedWith, null, "the audio at 10 s started the wait again");
  h.clock.advance(1);
  assertEquals(client.messages.at(-1), { type: "error", code: "idle", retryable: true });
  assertEquals(client.closedWith, { code: 1000, reason: "idle" });
  assertEquals(provider.closedWith?.code, 1000);

  // A socket that never says anything goes the same way.
  const silent = setup();
  await silent.handler(upgradeRequest());
  silent.clients[0].open();
  await tick();
  silent.clock.advance(15_000);
  assertEquals(silent.clients[0].messages, [{ type: "error", code: "idle", retryable: true }]);
  assertEquals(silent.recorded.logs[0].outcome, "idle");

  // And one that opens only after that long is closed at once, with nothing started for it.
  const slow = setup();
  await slow.handler(upgradeRequest());
  slow.clock.advance(15_000);
  assertEquals([slow.recorded.logs[0].outcome, slow.clients[0].closedWith], ["idle", null]);
  slow.clients[0].open();
  await tick();
  assertEquals(slow.clients[0].closedWith, { code: 1000, reason: "idle" });
  assertEquals([slow.recorded.preflights.length, slow.recorded.connected.length, slow.clients[0].sent.length], [0, 0, 0]);
  assertEquals((await slow.handler(upgradeRequest())).status, 200, "its slot was freed");
});

Deno.test("more audio than the socket's time could hold ends it", async () => {
  const h = setup({ worker: { workerAgeMs: 125_000 } });
  const { client } = await session(h);
  // 20 s of budget and the 12 s that may wait: 32 s of audio, however fast it comes.
  for (let index = 0; index < 32; index++) client.receive(frame(32_000));
  assertEquals(client.closedWith, null);
  client.receive(frame(640));
  assertEquals(client.messages.at(-1), { type: "error", code: "bad_request", retryable: false });
  assertEquals(client.closedWith, { code: 1008, reason: "bad_request" });
});

Deno.test("a provider that can't be reached ends the socket as a provider error", async () => {
  const h = setup();
  await h.handler(upgradeRequest());
  const client = h.clients[0];
  client.open();
  await tick();
  client.receive(startMessage());
  client.receive(frame(3200));
  // The handshake failed: the socket closes without ever opening.
  h.providers[0].drop(1006);
  assertEquals(client.messages, [{ type: "error", code: "provider", retryable: true }]);
  assertEquals(client.closedWith, { code: 1011, reason: "provider" });
  assertEquals([h.recorded.logs[0].outcome, h.recorded.logs[0].detail, h.recorded.logs[0].upstreamMs], ["provider", "socket closed 1006", null]);

  const unreachable = setup({
    connect: () => {
      throw new TypeError("invalid URL");
    },
  });
  await unreachable.handler(upgradeRequest());
  unreachable.clients[0].open();
  assertEquals(unreachable.clients[0].messages, [{ type: "error", code: "provider", retryable: true }]);
  assertEquals(unreachable.clients[0].closedWith, { code: 1011, reason: "provider" });
  // No connection was made, so the worker waits for the app's socket alone.
  await unreachable.recorded.kept[0];
});

Deno.test("a provider's error after ready reaches the app as its adapter judged it, without the message", async () => {
  const failed = async (error: Record<string, unknown>) => {
    const h = setup();
    const { client, provider } = await session(h);
    provider.receive(reply(settled("Привет")));
    provider.receive(JSON.stringify(error));
    assertEquals(client.closedWith?.code, 1011);
    assertFalse(provider.sent.includes(""), "a stream the provider ended isn't ended again");
    assertEquals(provider.closedWith?.code, 1000);
    assertEquals(h.recorded.usage, []);
    return { error: client.messages.at(-1), log: h.recorded.logs[0] };
  };
  // Soniox's own failure: another socket may work.
  const outage = await failed({ error_code: 503, error_type: "service_unavailable", error_message: "Cannot continue: Привет" });
  assertEquals(outage.error, { type: "error", code: "provider", retryable: true });
  assertEquals([outage.log.outcome, outage.log.detail], ["provider", "soniox 503 service_unavailable"]);
  // The server's balance at Soniox: not the user's limit, and no use trying again.
  const broke = await failed({ error_code: 402, error_type: "organization_balance_exhausted", error_message: "Add funds." });
  assertEquals(broke.error, { type: "error", code: "unavailable", retryable: false });
  assertEquals([broke.log.outcome, broke.log.detail], ["unavailable", "soniox 402 organization_balance_exhausted"]);
});

Deno.test("a provider that ends the stream early is an error; a normal close after finalize is the final text", async () => {
  // Soniox says it is finished, though nobody asked.
  const early = setup();
  const first = await session(early);
  first.provider.receive(JSON.stringify({ tokens: [], finished: true }));
  assertEquals(first.client.messages.at(-1), { type: "error", code: "provider", retryable: true });
  assertEquals(first.client.closedWith, { code: 1011, reason: "provider" });

  // The connection is lost mid-dictation.
  const lost = setup();
  const second = await session(lost);
  second.provider.drop(1006);
  assertEquals(second.client.messages.at(-1), { type: "error", code: "provider", retryable: true });

  // After the app's finalize a normal close is the end of the dictation.
  const closing = setup();
  const third = await session(closing);
  third.provider.receive(reply(settled("Привет, мир.")));
  third.client.receive(finalize());
  third.provider.drop(1000);
  const final = third.client.messages.at(-1)!;
  assertEquals([final.type, final.text, final.words], ["final", "Привет, мир.", 2]);
  assertEquals(closing.recorded.usage, [{ caller: USER, dictationId: DICTATION, words: 2 }]);

  // But a lost connection isn't: the tail may be missing.
  const cut = setup();
  const fourth = await session(cut);
  fourth.provider.receive(reply(settled("Привет, мир.")));
  fourth.client.receive(finalize());
  fourth.provider.drop(1006);
  assertEquals(fourth.client.messages.at(-1), { type: "error", code: "provider", retryable: true });
  assertEquals(cut.recorded.usage, []);
});

Deno.test("a provider whose address depends on the dictation is connected when the start arrives", async () => {
  const h = setup({ adapters: { late }, config: { ...WITH_LATE, provider: "late" } });
  await h.handler(upgradeRequest());
  const client = h.clients[0];
  client.open();
  await tick();
  assertEquals(h.recorded.connected, [], "its address isn't known yet");
  client.receive(startMessage({ language: "ru-RU" }));
  assertEquals(h.recorded.connected, [{ url: "wss://late.test/listen?language=ru", protocols: ["token", "late-key"] }]);
  const provider = h.providers[0];
  provider.open();
  assertEquals(client.messages, [{ ...READY, provider: "late", caps: { languageDetection: false } }]);
  assertEquals(provider.sent, [], "it has no configuration frame");

  const audio = frame(3200);
  client.receive(audio);
  provider.receive("Привет мир");
  assertEquals(client.messages.at(-1), { type: "partial", seq: 1, stable: "Привет мир", volatile: "" });
  client.receive(finalize(100));
  assertEquals(provider.sent, [audio, "finalize"]);
  // This service finishes by closing its stream.
  provider.receive("done");
  const final = client.messages.at(-1)!;
  // It names no languages: the words are counted in the one the user chose.
  assertEquals([final.type, final.text, final.languages, final.words], ["final", "Привет мир", [], 2]);
  assertEquals(provider.sent, [audio, "finalize"], "a stream the provider ended isn't ended again");
  assertEquals(provider.closedWith?.code, 1000);
});

Deno.test("a dictation in a language the provider doesn't take is refused before any audio leaves", async () => {
  const h = setup();
  await h.handler(upgradeRequest());
  const client = h.clients[0];
  client.open();
  await tick();
  h.providers[0].open();
  client.receive(frame(3200));
  client.receive(startMessage({ language: "is-IS" }));
  assertEquals(client.messages, [{ type: "error", code: "unavailable", retryable: false }]);
  assertEquals(client.closedWith, { code: 1011, reason: "unavailable" });
  assertEquals(h.providers[0].sent, []);
  assertEquals(h.providers[0].closedWith?.code, 1000);
});

Deno.test("a bench run may choose the provider for its socket; without the key the choice is ignored", async () => {
  const options: Setup = { env: { LIVE_BENCH_KEY: BENCH_KEY }, adapters: { soniox, late }, config: WITH_LATE };
  const providerOf = async (request: RequestOptions) => {
    const h = setup(options);
    const { client } = await session(h, { request });
    client.drop(1000);
    return [client.messages[0].provider, h.recorded.logs[0].provider, h.recorded.logs[0].bench];
  };
  assertEquals(await providerOf({ query: "?provider=late", headers: { "x-murmur-bench": BENCH_KEY } }), ["late", "late", true]);
  assertEquals(await providerOf({ query: `?provider=late&bench=${BENCH_KEY}` }), ["late", "late", true]);
  // The key alone changes nothing.
  assertEquals(await providerOf({ headers: { "x-murmur-bench": BENCH_KEY } }), ["soniox", "soniox", true]);
  assertEquals(await providerOf({ query: "?provider=late" }), ["soniox", "soniox", false]);
  assertEquals(await providerOf({ query: "?provider=late", headers: { "x-murmur-bench": "wrong" } }), ["soniox", "soniox", false]);

  // A provider the relay doesn't have, or has no key for.
  const h = setup(options);
  for (const provider of ["whisperer", "constructor"]) {
    const response = await h.handler(upgradeRequest({ query: `?provider=${provider}`, headers: { "x-murmur-bench": BENCH_KEY } }));
    assertEquals(response.status, 503, provider);
  }
  // No bench key set: a request can't pass as a bench run with an empty one.
  const closed = setup({ adapters: { soniox, late }, config: WITH_LATE });
  const { client } = await session(closed, { request: { query: "?provider=late&bench=" } });
  assertEquals(client.messages[0].provider, "soniox");
});

Deno.test("the worker is kept alive until both sockets have closed", async () => {
  const h = setup();
  const { client, provider } = await session(h);
  assertEquals(h.recorded.kept.length, 1);
  let settledAt = "";
  h.recorded.kept[0].then(() => settledAt = "settled");
  // The provider's socket takes a moment to close after the app has gone.
  provider.lingers = true;
  client.drop(1000);
  await tick();
  assertEquals(provider.closedWith?.code, 1000);
  assertEquals(settledAt, "", "the provider's socket is still closing");
  provider.drop(1000);
  await tick();
  assertEquals(settledAt, "settled");

  // And the app's socket after the relay has closed it: the final text is still on its way out.
  const other = setup();
  const second = await session(other);
  let done = false;
  other.recorded.kept[0].then(() => done = true);
  second.client.lingers = true;
  second.client.receive(finalize());
  second.provider.receive(reply(settled("Да."), FIN));
  assertEquals(second.client.closedWith, { code: 1000, reason: "final" });
  await tick();
  assertFalse(done, "the app hasn't acknowledged the close");
  second.client.drop(1000);
  await tick();
  assert(done);
  assertEquals(other.recorded.logs.length, 1, "one line, written when the session ended");
});

Deno.test("an exception in a socket's handler ends that session, and nothing else", async () => {
  const broken: LiveProvider = {
    ...soniox,
    adapter: (options) => ({
      ...soniox.adapter(options)!,
      parse: () => {
        throw new SyntaxError("Unexpected token in what was said");
      },
    }),
  };
  const h = setup({ adapters: { soniox: broken } });
  const { client, provider } = await session(h);
  provider.receive("{}");
  assertEquals(client.messages.at(-1), { type: "error", code: "unavailable", retryable: true });
  assertEquals(client.closedWith, { code: 1011, reason: "unavailable" });
  assertEquals(provider.closedWith?.code, 1000);
  assertEquals([h.recorded.logs[0].outcome, h.recorded.logs[0].detail], ["unavailable", "exception SyntaxError"]);
  // The handler goes on serving.
  assertEquals((await h.handler(upgradeRequest())).status, 200);
});

Deno.test("the log line and the errors never hold what was said, or the keywords", async () => {
  const secrets = ["тайное", "секрет", "конец", "Секретов", "пароль"];
  const h = setup();
  const said = await session(h, { start: { keywords: ["Секретов"], client: "murmur-ios" } });
  said.provider.receive(reply(settled("тайное слово"), unsettled(" секрет")));
  said.client.receive(finalize());
  said.provider.receive(reply(settled(" конец"), FIN));
  assertEquals(said.client.messages.at(-1)?.text, "тайное слово конец");

  const failed = await session(h, { start: { keywords: ["Секретов"] } });
  failed.provider.receive(reply(settled("тайное слово")));
  failed.provider.receive(JSON.stringify({ error_code: 400, error_type: "invalid_request", error_message: "Context: пароль" }));
  const error = failed.client.messages.at(-1)!;
  assertEquals(error, { type: "error", code: "unavailable", retryable: false });

  const cancelled = await session(h, { start: { keywords: ["Секретов"] } });
  cancelled.provider.receive(reply(unsettled("секрет")));
  cancelled.client.drop(1000);

  assertEquals(h.recorded.logs.map((line) => line.outcome), ["final", "unavailable", "cancelled"]);
  const written = JSON.stringify(h.recorded.logs);
  for (const secret of secrets) assertFalse(written.includes(secret), secret);
  // The app's own name is the one thing kept from its start, when the upgrade had no x-client-info.
  assertEquals(h.recorded.logs[0].client, "murmur-ios");
  assertEquals(h.recorded.logs[0].keywords, 1);
});

Deno.test("liveConfig reads the env, with its defaults", () => {
  assertEquals(liveConfig(new Map()), {
    disabled: false,
    provider: "soniox",
    maxSessionMs: 140_000,
    wallClockMs: 150_000,
    benchKey: undefined,
    providers: { soniox: { apiKey: undefined, model: "stt-rt-v6" } },
    perMinute: 40,
    anonymousPerMinute: 10,
  });
  const env = new Map(Object.entries({
    LIVE_DISABLED: "1",
    LIVE_PROVIDER: " Soniox ",
    LIVE_MAX_SESSION_MS: "380000",
    LIVE_WALL_CLOCK_MS: "400000",
    LIVE_BENCH_KEY: BENCH_KEY,
    SONIOX_API_KEY: "soniox-key",
    LIVE_SONIOX_MODEL: "stt-rt-v7",
  }));
  assertEquals(liveConfig(env), {
    disabled: true,
    provider: "soniox",
    maxSessionMs: 380_000,
    wallClockMs: 400_000,
    benchKey: BENCH_KEY,
    providers: { soniox: { apiKey: "soniox-key", model: "stt-rt-v7" } },
    perMinute: 40,
    anonymousPerMinute: 10,
  });
  // Not usable numbers, and values left empty: the defaults.
  const odd = liveConfig(new Map(Object.entries({
    LIVE_MAX_SESSION_MS: "soon",
    LIVE_WALL_CLOCK_MS: "-1",
    LIVE_PROVIDER: "",
    LIVE_BENCH_KEY: "",
    LIVE_SONIOX_MODEL: "",
    LIVE_DISABLED: "true",
  })));
  assertEquals(odd, liveConfig(new Map()));
});

Deno.test("parseStart cleans the start as transcribe cleans its body", () => {
  const audio = { format: "pcm_s16le", rate: 16000, channels: 1 };
  const start = { type: "start", v: 1, dictationId: DICTATION, language: null, audio };
  assertEquals(parseStart(start), {
    ok: true,
    value: { dictationId: DICTATION, language: null, languages: [], keywords: [], client: null },
  });
  assertEquals(
    parseStart({
      ...start,
      language: "ru_RU",
      languages: ["ru-RU", "en-US", "ru", "nb-NO", "not a tag", 5],
      keywords: [" Окафор ", "окафор", "<b>", "x".repeat(60), 7],
      client: "c".repeat(100),
      later: "a field of a newer app",
    }),
    {
      ok: true,
      value: { dictationId: DICTATION, language: "ru", languages: ["ru", "en", "no"], keywords: ["Окафор"], client: "c".repeat(64) },
    },
  );
  // Auto-detect, as the app sends it.
  const automatic = parseStart({ ...start, language: "und" });
  assert(automatic.ok && automatic.value.language === null);

  const refused = (fields: Record<string, unknown>) => {
    const parsed = parseStart({ ...start, ...fields });
    return parsed.ok ? null : parsed.error;
  };
  assertEquals(refused({ type: "finalize" }), "type must be start");
  assertEquals(refused({ v: 2 }), "v must be 1");
  assertEquals(refused({ v: "1" }), "v must be 1");
  assertEquals(refused({ dictationId: "not-a-uuid" }), "dictationId must be a UUID");
  assertEquals(refused({ dictationId: undefined }), "dictationId must be a UUID");
  assertEquals(refused({ language: "ru; DROP" }), "language must be a BCP-47 tag");
  for (const wrong of [undefined, null, "pcm", { ...audio, format: "wav" }, { ...audio, rate: 24000 }, { ...audio, channels: 2 }]) {
    assertEquals(refused({ audio: wrong }), "audio must be pcm_s16le at 16000 Hz with 1 channel");
  }
  for (const body of [null, "start", 7]) assertEquals(parseStart(body), { ok: false, error: "start must be a JSON object" });
});
