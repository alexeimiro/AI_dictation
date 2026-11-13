import { assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { transcribeConfig } from "../_shared/config.ts";
import type { CostCall } from "../_shared/cost.ts";
import type { Caller } from "../_shared/http.ts";
import { createTranscribeHandler, type TranscribeDeps } from "../_shared/transcribe_handler.ts";

const ENDPOINT = "http://localhost/functions/v1/transcribe";
const DICTATION = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const USER: Caller = { userId: "1b4e28ba-2fa1-41d2-883f-0016d3cca427", isAnonymous: false };
const GUEST: Caller = { userId: "6fa459ea-ee8a-4ca4-894e-db77e160355e", isAnonymous: true };
const TRANSCRIPT = "можешь скинуть отчёт до пятницы спасибо большое";

/** A WAV of `ms` of 16 kHz mono PCM16, in base64 as the app sends it. */
function wavOf(ms: number): string {
  const data = ms * 32;
  const le32 = (value: number) => [value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff];
  const ascii = (text: string) => [...text].map((char) => char.charCodeAt(0));
  const bytes = [
    ...ascii("RIFF"), ...le32(36 + data), ...ascii("WAVE"),
    ...ascii("fmt "), ...le32(16), 1, 0, 1, 0, ...le32(16000), ...le32(32000), 2, 0, 16, 0,
    ...ascii("data"), ...le32(data), ...new Array(data).fill(0),
  ];
  return btoa(String.fromCharCode(...bytes));
}

type Answer = { data?: unknown; error?: unknown };

interface Setup {
  /** What each RPC answers; unnamed ones succeed: within the limit, on Basic with 870 words left. */
  rpc?: Record<string, Answer>;
  openai?: () => Response | Promise<Response>;
  deps?: Partial<TranscribeDeps>;
}

/** A handler on fakes, and everything it did. */
function setup(options: Setup = {}) {
  const recorded = {
    rpcs: [] as { name: string; args: Record<string, unknown> }[],
    fetches: [] as string[],
    costs: [] as { caller: Caller; dictationId: string | null; calls: CostCall[] }[],
    background: [] as PromiseLike<unknown>[],
    logs: [] as Record<string, unknown>[],
  };
  const answers: Record<string, Answer> = {
    consume_bucket: { data: true },
    quota_status: { data: { plan: "basic", remaining: 870 } },
    record_usage: {},
    ...options.rpc,
  };
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      recorded.rpcs.push({ name, args });
      const answer = { data: null, error: null, ...answers[name] };
      // A PostgREST builder: awaited as it is, or narrowed to one row first.
      return Object.assign(Promise.resolve(answer), { single: () => Promise.resolve(answer) });
    },
  } as unknown as Pick<SupabaseClient, "rpc">;
  const fetcher = ((input: string | URL) => {
    recorded.fetches.push(new URL(String(input)).pathname);
    return Promise.resolve(options.openai?.() ?? Response.json({ text: TRANSCRIPT, languages: [{ code: "ru" }] }));
  }) as unknown as typeof fetch;

  const handler = createTranscribeHandler({
    admin,
    config: transcribeConfig(new Map()),
    apiKey: "sk-test",
    disabled: false,
    authenticate: (request) => {
      const token = request.headers.get("Authorization");
      return Promise.resolve(token === "Bearer user" ? USER : token === "Bearer guest" ? GUEST : null);
    },
    recordCost: (caller, dictationId, calls) => {
      recorded.costs.push({ caller, dictationId, calls });
      return Promise.resolve();
    },
    background: (work) => void recorded.background.push(work),
    fetcher,
    worker: () => ({ cold: false, workerAgeMs: 41210, region: "eu-central-1", executionId: "worker-a" }),
    log: (line) => void recorded.logs.push(JSON.parse(line)),
    ...options.deps,
  });
  return { handler, recorded };
}

interface RequestOptions {
  token?: string | null;
  /** The x-murmur-dictation header; null leaves it out, as builds before it did. */
  dictation?: string | null;
  body?: Record<string, unknown> | string;
  method?: string;
}

function request({ token = "user", dictation = DICTATION, body, method = "POST" }: RequestOptions = {}): Request {
  const payload = body ?? { dictationId: DICTATION, audio: wavOf(2500), format: "wav", language: "ru-RU", keywords: ["Окафор"] };
  return new Request(ENDPOINT, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token === null ? {} : { Authorization: `Bearer ${token}` }),
      ...(dictation === null ? {} : { "x-murmur-dictation": dictation }),
    },
    body: method === "POST" ? (typeof payload === "string" ? payload : JSON.stringify(payload)) : undefined,
  });
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

const rpcNames = (recorded: { rpcs: { name: string }[] }) => recorded.rpcs.map((rpc) => rpc.name);

Deno.test("a transcription is checked, transcribed, counted and costed, and answered in one reply", async () => {
  const { handler, recorded } = setup();
  const response = await handler(request());
  assertEquals(response.status, 200);
  const reply = await response.json();
  assertEquals(Object.keys(reply), ["text", "languages", "model", "words", "remaining", "totalMs", "timings"]);
  assertEquals([reply.text, reply.languages, reply.model, reply.words, reply.remaining], [TRANSCRIPT, ["ru"], "gpt-transcribe", 7, 863]);
  assertEquals(reply.timings.region, "eu-central-1");

  // The minute's bucket, then the week's words, then OpenAI; the words are recorded after the reply.
  assertEquals(rpcNames(recorded), ["consume_bucket", "quota_status", "record_usage"]);
  assertEquals(recorded.rpcs[0].args, { p_key: `transcribe:${USER.userId}`, p_limit: 40, p_window_seconds: 60 });
  assertEquals(recorded.rpcs[2].args, { p_user: USER.userId, p_dictation: DICTATION, p_words: 7 });
  assertEquals(recorded.fetches, ["/v1/audio/transcriptions"]);
  assertEquals(recorded.costs, [{
    caller: USER,
    dictationId: DICTATION,
    calls: [{ kind: "speech", path: "upload", plan: "basic", provider: "openai", model: "gpt-transcribe", audioMs: 2500 }],
  }]);
  assertEquals(recorded.background.length, 2);

  const [line] = recorded.logs;
  assertEquals([line.event, line.model, line.format, line.language, line.keywords, line.outWords, line.isAnonymous], [
    "transcribe", "gpt-transcribe", "wav", "ru", 1, 7, false,
  ]);
  assertFalse(JSON.stringify(line).includes("отчёт"), "the log never holds what was said");
});

Deno.test("an anonymous caller gets the tighter limit, and a plan without a weekly limit has nothing remaining to report", async () => {
  const { handler, recorded } = setup({ rpc: { quota_status: { data: { plan: "pro", remaining: null } } } });
  const reply = await (await handler(request({ token: "guest" }))).json();
  assertEquals(recorded.rpcs[0].args.p_limit, 10);
  assertEquals(reply.remaining, null);
  assertEquals(recorded.costs[0].calls[0].plan, "pro");
});

Deno.test("an id the header doesn't vouch for is neither counted nor named in the cost", async () => {
  // A build before the header sent a random id in the body.
  const { handler, recorded } = setup();
  const reply = await (await handler(request({ dictation: null }))).json();
  assertEquals([reply.words, reply.remaining], [0, 870]);
  assertEquals(rpcNames(recorded), ["consume_bucket", "quota_status"]);
  assertEquals(recorded.costs.map(({ dictationId, calls }) => [dictationId, calls.length]), [[null, 1]], "still paid for");
});

Deno.test("no caller is 401 and a body that isn't a request is 400, before any check", async () => {
  const { handler, recorded } = setup();
  assertEquals((await handler(request({ token: null }))).status, 401);
  assertEquals((await handler(request({ token: "someone" }))).status, 401);
  assertEquals((await handler(request({ body: "not json" }))).status, 400);
  const response = await handler(request({ body: { audio: wavOf(100), format: "mp3" } }));
  assertEquals(await response.json(), { error: "bad_request", detail: "format must be m4a or wav" });
  assertEquals(recorded.rpcs, []);
  assertEquals(recorded.fetches, []);
});

Deno.test("over the minute's limit is 429 and a used-up week 402, with nothing sent to OpenAI", async () => {
  const limited = setup({ rpc: { consume_bucket: { data: false } } });
  const first = await limited.handler(request());
  assertEquals([first.status, await first.json()], [429, { error: "rate_limited" }]);
  assertEquals(rpcNames(limited.recorded), ["consume_bucket"]);

  const spent = setup({ rpc: { quota_status: { data: { plan: "basic", remaining: 0 } } } });
  const second = await spent.handler(request());
  assertEquals([second.status, await second.json()], [402, { error: "limit_reached" }]);
  assertEquals([...limited.recorded.fetches, ...spent.recorded.fetches], []);
  assertEquals([...limited.recorded.costs, ...spent.recorded.costs], []);
});

Deno.test("a check that can't run lets the dictation through, unless the function is told to fail closed", async () => {
  const down = { consume_bucket: { error: { code: "PGRST000" } }, quota_status: { error: { code: "PGRST000" } } };

  // As it always was: the database being out doesn't stop a dictation.
  const open = setup({ rpc: down });
  const through = await quietly(() => open.handler(request()));
  assertEquals(through.status, 200);
  const reply = await through.json();
  assertEquals([reply.text, reply.words, reply.remaining], [TRANSCRIPT, 7, null]);

  const outages: Record<string, Answer>[] = [down, { consume_bucket: down.consume_bucket }, { quota_status: down.quota_status }];
  for (const rpc of outages) {
    const closed = setup({ rpc, deps: { failClosed: true } });
    const refused = await quietly(() => closed.handler(request()));
    assertEquals([refused.status, await refused.json()], [503, { error: "transcription_unavailable" }]);
    assertEquals(closed.recorded.fetches, [], "nothing is spent on a dictation that wasn't checked");
  }

  // Failing closed changes nothing while the checks answer.
  const healthy = setup({ deps: { failClosed: true } });
  assertEquals((await healthy.handler(request())).status, 200);
});

Deno.test("the kill switch and a missing key answer 503, and a failed transcription 502", async () => {
  const off = setup({ deps: { disabled: true } });
  const disabled = await off.handler(request());
  assertEquals([disabled.status, await disabled.json()], [503, { error: "transcription_unavailable" }]);
  assertEquals(off.recorded.rpcs, [], "before any database call");

  const keyless = setup({ deps: { apiKey: undefined } });
  assertEquals((await quietly(() => keyless.handler(request()))).status, 503);
  assertEquals(keyless.recorded.fetches, []);

  const failing = setup({ openai: () => Response.json({ error: { type: "server_error" } }, { status: 500 }) });
  const response = await quietly(() => failing.handler(request()));
  assertEquals([response.status, await response.json()], [502, { error: "transcription_unavailable" }]);
  assertEquals(rpcNames(failing.recorded), ["consume_bucket", "quota_status"], "nothing is counted");
  assertEquals(failing.recorded.costs, [], "and nothing was paid for");
  assertEquals(failing.recorded.logs, []);
});

Deno.test("silence is answered with no words, counted for nothing, and still costs its transcription", async () => {
  const { handler, recorded } = setup({ openai: () => Response.json({ text: "  ", languages: [] }) });
  const reply = await (await handler(request())).json();
  assertEquals([reply.text, reply.words, reply.remaining], ["", 0, 870]);
  assertEquals(rpcNames(recorded), ["consume_bucket", "quota_status"]);
  assertEquals(recorded.costs.length, 1);
});

Deno.test("OPTIONS answers with the CORS headers; any other method but POST gets 405", async () => {
  const { handler, recorded } = setup();
  const preflight = await handler(request({ method: "OPTIONS" }));
  assertEquals([preflight.status, preflight.headers.get("Access-Control-Allow-Methods")], [200, "POST, OPTIONS"]);
  assertEquals((await handler(request({ method: "GET" }))).status, 405);
  assertEquals(recorded.rpcs, []);
});

Deno.test("without a cost recorder the function works as before, with one task after the reply", async () => {
  const { handler, recorded } = setup({ deps: { recordCost: undefined } });
  assertEquals((await handler(request())).status, 200);
  assertEquals(recorded.background.length, 1);
});
