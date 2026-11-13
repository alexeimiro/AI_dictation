import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { createServer, type ServerOptions } from "./main.ts";

const ORIGIN = "http://localhost:8080";
const USER_ID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";
const DICTATION = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const TRANSCRIPT = "можешь скинуть отчёт до пятницы спасибо большое";
const CLEANED = "Можешь скинуть отчёт до пятницы? Спасибо большое!";

const env = (values: Record<string, string> = {}) => new Map(Object.entries(values));

/** A Supabase project on fakes: one user's token, RPCs that allow everything, and what was asked. */
function project() {
  const rpcs: { name: string; args: Record<string, unknown> }[] = [];
  const answers: Record<string, unknown> = {
    consume_bucket: true,
    quota_status: { plan: "basic", remaining: 870 },
    cleanup_preflight: { allowed: true, reason: null, plan: "basic", remaining: 870 },
    dictation_preflight: { allowed: true, reason: null, plan: "basic", remaining: 870, attempt: 1 },
  };
  const admin = {
    auth: {
      getClaims: (token: string) =>
        Promise.resolve(token === "user" ? { data: { claims: { sub: USER_ID, is_anonymous: false } }, error: null } : { data: null, error: null }),
    },
    rpc: (name: string, args: Record<string, unknown>) => {
      rpcs.push({ name, args });
      const answer = { data: answers[name] ?? null, error: null };
      const settled = () => Promise.resolve(answer);
      // A PostgREST builder: awaited as it is, narrowed to one row, or given a signal first.
      return Object.assign(settled(), { single: settled, abortSignal: settled });
    },
  } as unknown as SupabaseClient;
  return { admin: () => admin, rpcs };
}

/** OpenAI on fakes: the transcription, the model's answer, and the warm-up's model lookup. */
function openai(): { fetcher: typeof fetch; paths: string[] } {
  const paths: string[] = [];
  const fetcher = ((input: string | URL, init: RequestInit = {}) => {
    const { pathname } = new URL(String(input));
    paths.push(pathname);
    if (pathname === "/v1/audio/transcriptions") return Promise.resolve(Response.json({ text: TRANSCRIPT, languages: [{ code: "ru" }] }));
    if (pathname === "/v1/responses") {
      const model = String((JSON.parse(String(init.body)) as Record<string, unknown>).model);
      return Promise.resolve(Response.json({
        model,
        status: "completed",
        incomplete_details: null,
        output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text: CLEANED, annotations: [] }] }],
        usage: { input_tokens: 1950, output_tokens: 12, input_tokens_details: { cached_tokens: 1900, cache_write_tokens: 0 } },
      }));
    }
    return Promise.resolve(Response.json({ id: "model", object: "model" }));
  }) as unknown as typeof fetch;
  return { fetcher, paths };
}

const CONFIGURED = { MURMUR_HOST: "edge-fi", MURMUR_REGION: "europe-north1", MURMUR_VERSION: "a1b2c3d", OPENAI_API_KEY: "sk-test" };

function configured(values: Record<string, string> = {}, options: ServerOptions = {}) {
  const supabase = project();
  const models = openai();
  const logs: Record<string, unknown>[] = [];
  const server = createServer(env({ ...CONFIGURED, ...values }), {
    admin: supabase.admin,
    fetcher: models.fetcher,
    log: (line) => void logs.push(JSON.parse(line)),
    ...options,
  });
  return { server, logs, rpcs: supabase.rpcs, paths: models.paths };
}

function post(path: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`${ORIGIN}${path}`, {
    method: "POST",
    headers: { Authorization: "Bearer user", "Content-Type": "application/json", ...headers },
    body: body === null ? undefined : JSON.stringify(body),
  });
}

const get = (path: string, headers: Record<string, string> = {}) => new Request(`${ORIGIN}${path}`, { headers });

/** A WAV of `ms` of 16 kHz mono PCM16, in base64 as the app sends it to `transcribe`. */
function wavOf(ms: number): string {
  const data = ms * 32;
  const le32 = (value: number) => [value & 0xff, (value >>> 8) & 0xff, (value >>> 16) & 0xff, (value >>> 24) & 0xff];
  const ascii = (text: string) => [...text].map((char) => char.charCodeAt(0));
  return btoa(String.fromCharCode(
    ...ascii("RIFF"), ...le32(36 + data), ...ascii("WAVE"),
    ...ascii("fmt "), ...le32(16), 1, 0, 1, 0, ...le32(16000), ...le32(32000), 2, 0, 16, 0,
    ...ascii("data"), ...le32(data), ...new Array(data).fill(0),
  ));
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

Deno.test("the health check says which home this is, without asking the database", async () => {
  let now = 1_000_000;
  const { server, rpcs } = configured({}, { now: () => now });
  now += 4200;
  const response = await server.handler(get("/healthz"));
  assertEquals(response.status, 200);
  assertEquals(await response.json(), { ok: true, host: "edge-fi", version: "a1b2c3d", uptimeMs: 4200, configured: true, draining: false });
  assertEquals(response.headers.get("x-murmur-host"), "edge-fi");
  assertEquals(rpcs, []);
});

Deno.test("only the four dictation functions are served, under Supabase's own paths", async () => {
  const { server } = configured();
  for (const path of ["/", "/dictate", "/functions/v1/", "/functions/v1/verify-purchase", "/functions/v1/dictate/extra", "/functions/v2/dictate"]) {
    const response = await server.handler(get(path));
    assertEquals([response.status, await response.json()], [404, { error: "not_found" }], path);
  }
});

Deno.test("a warm-up, a transcription and a cleanup run through the same handlers as on Supabase", async () => {
  const { server, rpcs, paths, logs } = configured();

  const warm = await server.handler(post("/functions/v1/dictate", null, { "x-murmur-warm": "1" }));
  assertEquals(warm.status, 200);
  const warmed = await warm.json();
  // The process stands in for a worker: this home's region, and one id for as long as it runs.
  assertEquals([warmed.warm, warmed.region], [true, "europe-north1"]);
  assertMatch(warmed.executionId, /^[0-9a-f-]{36}$/);
  assertEquals(warm.headers.get("x-murmur-host"), "edge-fi");

  const heard = await server.handler(post(
    "/functions/v1/transcribe",
    { dictationId: DICTATION, audio: wavOf(2500), format: "wav", language: "ru-RU" },
    { "x-murmur-dictation": DICTATION },
  ));
  assertEquals(heard.status, 200);
  const transcript = await heard.json();
  assertEquals([transcript.text, transcript.words, transcript.timings.region, transcript.timings.executionId], [
    TRANSCRIPT, 7, "europe-north1", warmed.executionId,
  ]);

  const written = await server.handler(post("/functions/v1/cleanup", {
    dictationId: DICTATION,
    transcript: TRANSCRIPT,
    language: "ru-RU",
    style: "grammar",
  }));
  assertEquals(written.status, 200);
  assertEquals((await written.json()).text, CLEANED);

  assertEquals(paths.filter((path) => path !== "/v1/models/gpt-6-astra"), ["/v1/audio/transcriptions", "/v1/responses"]);
  // Each call's cost is recorded under this home's name.
  const costs = rpcs.filter((rpc) => rpc.name === "record_cost").map((rpc) => rpc.args.p_calls as Record<string, unknown>[]);
  assertEquals(costs.map((calls) => calls.map((call) => [call.kind, call.host, call.audioMs ?? null])), [
    [["speech", "edge-fi", 2500]],
    [["text", "edge-fi", null]],
  ]);
  assertEquals(logs.map((line) => line.event), ["dictate_warm", "transcribe", "cleanup"]);
  assert(logs.every((line) => line.region === "europe-north1" && line.executionId === warmed.executionId));
});

Deno.test("each function keeps its own answers: no token is 401, and live wants an upgrade", async () => {
  const { server } = configured();
  const anonymous = await server.handler(post("/functions/v1/dictate", null, { Authorization: "Bearer nobody", "x-murmur-warm": "1" }));
  assertEquals([anonymous.status, await anonymous.json()], [401, { error: "unauthorized" }]);
  const plain = await server.handler(get("/functions/v1/live", { Authorization: "Bearer user", "x-murmur-dictation": DICTATION }));
  assertEquals([plain.status, (await plain.json()).error], [400, "bad_request"]);
});

Deno.test("the kill switch answers 503 edge_disabled for the functions, and the server stays healthy", async () => {
  const { server, rpcs } = configured({ EDGE_DISABLED: "1" });
  for (const name of ["dictate", "transcribe", "cleanup", "live"]) {
    const response = await server.handler(post(`/functions/v1/${name}`, null));
    assertEquals([response.status, await response.json()], [503, { error: "edge_disabled" }], name);
    assertEquals(response.headers.get("x-murmur-host"), "edge-fi");
  }
  assertEquals((await server.handler(get("/healthz"))).status, 200);
  assertEquals(rpcs, []);
});

Deno.test("a server with no project serves no function, and says so", async () => {
  const server = createServer(env({ MURMUR_HOST: "test-gcp" }));
  assertEquals(server.configured, false);
  for (const name of ["dictate", "transcribe", "cleanup", "live"]) {
    const response = await server.handler(post(`/functions/v1/${name}`, null));
    assertEquals([response.status, await response.json()], [503, { error: "not_configured" }], name);
  }
  const health = await (await server.handler(get("/healthz"))).json();
  assertEquals([health.ok, health.host, health.configured, health.version], [true, "test-gcp", false, "dev"]);
});

Deno.test("the network test is served with the bench key alone, and closed without it", async () => {
  // No project at all: what a host is given for the test of its network.
  const open = createServer(env({ MURMUR_HOST: "test-gcp", LIVE_BENCH_KEY: "bench-key" }));
  const wrong = await open.handler(get("/functions/v1/live?mode=echo", { "x-murmur-bench": "not-it" }));
  assertEquals([wrong.status, await wrong.json()], [401, { error: "unauthorized" }]);
  // The right key reaches the test, which then wants a WebSocket.
  const right = await quietly(() => open.handler(get("/functions/v1/live?mode=echo", { "x-murmur-bench": "bench-key" })));
  assert(right.status !== 401 && right.status !== 404 && (await right.json()).error !== "not_configured");

  const closed = createServer(env({ MURMUR_HOST: "test-gcp" }));
  const refused = await closed.handler(get("/functions/v1/live?mode=echo", { "x-murmur-bench": "bench-key" }));
  assertEquals([refused.status, await refused.json()], [503, { error: "live_unavailable" }]);
  // Without a mode it is a dictation's socket, which this server has no project for.
  const relay = await open.handler(get("/functions/v1/live", { "x-murmur-bench": "bench-key" }));
  assertEquals(await relay.json(), { error: "not_configured" });
});

Deno.test("while it drains for a stop, the server reports unhealthy and takes no live socket, but answers the rest", async () => {
  const { server } = configured();
  server.beginDrain();
  const health = await server.handler(get("/healthz"));
  assertEquals(health.status, 503);
  const body = await health.json();
  assertEquals([body.ok, body.draining], [false, true]);

  const socket = await server.handler(get("/functions/v1/live", { Authorization: "Bearer user", "x-murmur-dictation": DICTATION, upgrade: "websocket" }));
  assertEquals([socket.status, await socket.json()], [503, { error: "live_unavailable" }]);
  const warm = await server.handler(post("/functions/v1/dictate", null, { "x-murmur-warm": "1" }));
  assertEquals(warm.status, 200);
});

Deno.test("without a name of its own, this home is called edge", async () => {
  const server = createServer(env());
  assertEquals(server.host, "edge");
  assertEquals((await server.handler(get("/healthz"))).headers.get("x-murmur-host"), "edge");
});
