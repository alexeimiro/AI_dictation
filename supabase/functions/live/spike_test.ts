import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { RequestStart } from "../_shared/timing.ts";
import { createSpikeHandler, type SpikeDeps, type Upstream } from "./spike.ts";

const BENCH_KEY = "bench-key";
const WORKER: RequestStart = { cold: true, workerAgeMs: 7, region: "eu-central-1", executionId: "worker-a" };
const PROVIDER: Upstream = { url: "wss://provider.test/socket", headers: { Authorization: "Bearer server-key" } };

/** A WebSocket the test drives from the other end: what was sent to it, and how it was closed. */
class FakeSocket {
  readyState: number = WebSocket.OPEN;
  binaryType = "blob";
  sent: (string | ArrayBuffer)[] = [];
  closedWith: { code: number; reason: string } | null = null;
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: string | ArrayBuffer }) => void) | null = null;
  onclose: ((event: { code: number }) => void) | null = null;
  onerror: (() => void) | null = null;

  send(data: string | ArrayBuffer) {
    this.sent.push(data);
  }

  close(code = 1000, reason = "") {
    if (this.readyState === WebSocket.CLOSED) return;
    this.readyState = WebSocket.CLOSED;
    this.closedWith = { code, reason };
    this.onclose?.({ code });
  }

  /** The other end connected. */
  open() {
    this.onopen?.();
  }

  /** A message from the other end. */
  receive(data: string | ArrayBuffer) {
    this.onmessage?.({ data });
  }

  /** The JSON messages sent so far, parsed. */
  get messages(): Record<string, unknown>[] {
    return this.sent.filter((item): item is string => typeof item === "string").map((item) => JSON.parse(item));
  }
}

interface Harness {
  handler: (request: Request) => Promise<Response>;
  client: FakeSocket;
  provider: FakeSocket;
  upgrades: number;
  connected: Upstream[];
  kept: Promise<unknown>[];
  logs: string[];
  /** Runs what was scheduled, as if its time had come. */
  fire: () => void;
  cancelled: boolean;
}

function harness(overrides: Partial<SpikeDeps> = {}): Harness {
  const state: Harness = {
    handler: () => Promise.reject(new Error("not set")),
    client: new FakeSocket(),
    provider: new FakeSocket(),
    upgrades: 0,
    connected: [],
    kept: [],
    logs: [],
    fire: () => {},
    cancelled: false,
  };
  state.handler = createSpikeHandler({
    benchKey: BENCH_KEY,
    maxSessionMs: 140_000,
    upgrade: () => {
      state.upgrades++;
      return { socket: state.client as unknown as WebSocket, response: new Response(null, { status: 200 }) };
    },
    upstream: (provider) => provider === "soniox" ? PROVIDER : null,
    connect: (target) => {
      state.connected.push(target);
      return state.provider as unknown as WebSocket;
    },
    verifyToken: () => Promise.resolve(true),
    background: (work) => {
      state.kept.push(work);
    },
    worker: () => WORKER,
    now: () => 0,
    schedule: (_ms, work) => {
      state.fire = work;
      return () => {
        state.cancelled = true;
      };
    },
    log: (line) => state.logs.push(line),
    ...overrides,
  });
  return state;
}

function upgradeRequest(query = "", headers: Record<string, string> = {}): Request {
  return new Request(`https://project.test/functions/v1/live${query}`, {
    headers: { upgrade: "websocket", "x-murmur-bench": BENCH_KEY, authorization: "Bearer user-token", ...headers },
  });
}

function frame(bytes: number): ArrayBuffer {
  return new Uint8Array(bytes).buffer;
}

Deno.test("without a bench key set the spike is closed, before any upgrade", async () => {
  const h = harness({ benchKey: undefined });
  const response = await h.handler(upgradeRequest());
  assertEquals(response.status, 503);
  assertEquals(h.upgrades, 0);
});

Deno.test("a request without the bench key, or that isn't an upgrade, is refused", async () => {
  const h = harness();
  assertEquals((await h.handler(upgradeRequest("", { "x-murmur-bench": "wrong" }))).status, 401);
  const plain = new Request("https://project.test/functions/v1/live", { headers: { "x-murmur-bench": BENCH_KEY } });
  assertEquals((await h.handler(plain)).status, 400);
  assertEquals((await h.handler(upgradeRequest("?mode=other"))).status, 400);
  // Upstream mode needs a provider the function has a key for.
  assertEquals((await h.handler(upgradeRequest("?mode=upstream&provider=unknown"))).status, 503);
  assertEquals(h.upgrades, 0);
});

Deno.test("ready says what reached the function on the upgrade", async () => {
  const h = harness();
  await h.handler(upgradeRequest("", { apikey: "publishable", "x-region": "eu-central-1" }));
  h.client.open();
  const [ready] = h.client.messages;
  assertEquals(ready, {
    type: "spike.ready",
    mode: "echo",
    provider: null,
    sawAuthorization: true,
    sawApikey: true,
    benchVia: "header",
    token: "valid",
    region: "eu-central-1",
    requestedRegion: "eu-central-1",
    executionId: "worker-a",
    cold: true,
    workerAgeMs: 7,
    budgetMs: 140_000,
  });
  assertEquals(h.client.binaryType, "arraybuffer");
});

Deno.test("a client that can't set headers passes the key in the query, and its token goes unchecked", async () => {
  const h = harness();
  const request = new Request(`https://project.test/functions/v1/live?bench=${BENCH_KEY}`, { headers: { upgrade: "websocket" } });
  assertEquals((await h.handler(request)).status, 200);
  h.client.open();
  const [ready] = h.client.messages;
  assertEquals(ready.benchVia, "query");
  assertEquals(ready.sawAuthorization, false);
  assertEquals(ready.token, "unchecked");
});

Deno.test("echo mode acknowledges each audio frame and answers a ping with the padding it asked for", async () => {
  const h = harness();
  await h.handler(upgradeRequest());
  h.client.open();
  h.client.receive(frame(3200));
  h.client.receive(frame(3200));
  h.client.receive(JSON.stringify({ type: "spike.ping", id: 5, pad: 1000 }));
  const [, first, second, pong] = h.client.messages;
  assertEquals(first, { type: "spike.ack", seq: 1, bytes: 3200 });
  assertEquals(second, { type: "spike.ack", seq: 2, bytes: 3200 });
  assertEquals(pong.type, "spike.pong");
  assertEquals(pong.id, 5);
  assertEquals((pong.pad as string).length, 1000);
});

Deno.test("finalize reports the session's counts, closes normally and writes one log line", async () => {
  const h = harness();
  await h.handler(upgradeRequest());
  h.client.open();
  h.client.receive(frame(3200));
  h.client.receive(JSON.stringify({ type: "spike.finalize" }));
  const final = h.client.messages.at(-1)!;
  assertEquals(final.type, "spike.final");
  assertEquals(final.frames, 1);
  assertEquals(final.bytesIn, 3200 + JSON.stringify({ type: "spike.finalize" }).length);
  assertEquals(h.client.closedWith, { code: 1000, reason: "finalized" });
  assertEquals(h.logs.length, 1);
  const line = JSON.parse(h.logs[0]);
  assertEquals(line.event, "live_spike");
  assertEquals(line.closeCode, 1000);
  assertEquals(line.closeReason, "finalized");
  assertEquals(line.executionId, "worker-a");
  assert(h.cancelled, "the budget timer is cancelled once the socket has closed");
});

Deno.test("the worker is kept alive until the socket closes", async () => {
  const h = harness();
  await h.handler(upgradeRequest());
  h.client.open();
  assertEquals(h.kept.length, 1);
  let settled = false;
  h.kept[0].then(() => settled = true);
  await Promise.resolve();
  assertFalse(settled);
  h.client.close(1001, "going away");
  await h.kept[0];
  assert(settled);
});

Deno.test("the function closes the socket itself when its budget is up", async () => {
  const h = harness();
  await h.handler(upgradeRequest());
  h.client.open();
  h.fire();
  assertEquals(h.client.messages.at(-1), { type: "spike.error", code: "budget" });
  assertEquals(h.client.closedWith, { code: 1012, reason: "budget" });
  assertEquals(JSON.parse(h.logs[0]).closeReason, "budget");
});

Deno.test("a run may ask for its own budget, up to ten minutes", async () => {
  const budgets: number[] = [];
  const budgetOf = async (query: string) => {
    const h = harness({
      schedule: (ms) => {
        budgets.push(ms);
        return () => {};
      },
    });
    await h.handler(upgradeRequest(query));
    h.client.open();
    return h.client.messages[0].budgetMs;
  };
  assertEquals(await budgetOf("?budget=380000"), 380_000);
  assertEquals(await budgetOf("?budget=9000000"), 600_000);
  // Not a usable number: the function's own limit.
  assertEquals(await budgetOf("?budget=soon"), 140_000);
  assertEquals(await budgetOf("?budget=5"), 140_000);
  assertEquals(budgets, [380_000, 600_000, 140_000, 140_000]);
});

Deno.test("upstream mode holds frames until the provider's socket opens, then passes both ways", async () => {
  const h = harness();
  await h.handler(upgradeRequest("?mode=upstream&provider=soniox"));
  h.client.open();
  assertEquals(h.connected, [PROVIDER]);
  const config = JSON.stringify({ model: "stt-rt-v6" });
  const audio = frame(3200);
  h.client.receive(config);
  h.client.receive(audio);
  assertEquals(h.provider.sent, []);

  h.provider.open();
  assertEquals(h.provider.sent, [config, audio]);
  assertEquals(h.client.messages.at(-1), { type: "spike.upstream", ms: 0 });
  const later = frame(1600);
  h.client.receive(later);
  assertEquals(h.provider.sent.at(-1), later);

  // The provider's own messages reach the client untouched.
  const words = JSON.stringify({ tokens: [{ text: "hello", is_final: true }] });
  h.provider.receive(words);
  assertEquals(h.client.sent.at(-1), words);

  h.client.close(1000, "done");
  assertEquals(h.provider.closedWith?.code, 1000);
});

Deno.test("when the provider closes, the client gets the counts and a normal close", async () => {
  const h = harness();
  await h.handler(upgradeRequest("?mode=upstream&provider=soniox"));
  h.client.open();
  h.provider.open();
  h.provider.close(1000, "finished");
  const final = h.client.messages.at(-1)!;
  assertEquals(final.type, "spike.final");
  assertEquals(final.upstreamCloseCode, 1000);
  assertEquals(h.client.closedWith, { code: 1000, reason: "upstream closed" });
});

Deno.test("a provider that never opens doesn't let the backlog grow without bound", async () => {
  const h = harness();
  await h.handler(upgradeRequest("?mode=upstream&provider=soniox"));
  h.client.open();
  for (let index = 0; index < 3; index++) h.client.receive(frame(1024 * 1024));
  assertEquals(h.client.messages.at(-1)?.code, "upstream");
  assertEquals(h.client.closedWith, { code: 1011, reason: "backlog" });
});

Deno.test("the log line never holds what passed through", async () => {
  const h = harness();
  await h.handler(upgradeRequest("?mode=upstream&provider=soniox"));
  h.client.open();
  h.provider.open();
  h.client.receive(JSON.stringify({ context: "secret words" }));
  h.provider.receive(JSON.stringify({ tokens: [{ text: "secret words" }] }));
  h.client.close();
  assertFalse(h.logs.join("\n").includes("secret"));
});
