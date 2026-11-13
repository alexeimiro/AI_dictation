// The relay spike's client: what a WebSocket through the `live` function (its spike,
// supabase/functions/live/spike.ts) survives and costs from the network this runs on. Run it on
// each network that matters (Wi-Fi, the phone's hotspot on each carrier), with --label naming it.
//
//   deno run --allow-net --allow-read --allow-write --allow-env scripts/bench/live_spike.ts \
//     --bench <LIVE_BENCH_KEY> [--run handshake,echo,download,stream:60] [--label wifi] \
//     [--url wss://<project>.supabase.co/functions/v1/live] [--key <publishable key>] \
//     [--token <user JWT> | --no-token] [--region eu-central-1] [--budget 380000] [--frame-bytes 3200] [--out <file.json>]
//
// --run takes, in order:
//   handshake            connects with headers, then with the key in the query, and prints `ready`
//   echo[:200]           that many pings, one at a time: the round trip through the function
//   download[:128]       that many KB sent back on one socket (a network that cuts large downloads)
//   stream:60[x3]        60 s of 100 ms audio-sized frames at real-time pace, 3 times, each ended by finalize
//   concurrent:5x120     5 such streams of 120 s at once
// --budget asks the function to keep each socket that many ms instead of its own limit, to find
// where the platform cuts one. --frame-bytes changes the size of each 100 ms frame (3200 by
// default), to tell a stall that follows the bytes sent from one that follows the clock. The URL and the publishable key default to Config/Local.xcconfig. Without --token, the session
// kept in scripts/out/live_spike_session.json is refreshed, or an anonymous user is signed up once
// and kept there. The bench key also comes from the LIVE_BENCH_KEY variable.
import { percentile } from "./models.ts";

/** 100 ms of 16 kHz mono PCM16, the frame the app will send. */
const FRAME_BYTES = 3200;
const FRAME_MS = 100;
const SESSION_FILE = "scripts/out/live_spike_session.json";

/** Deno takes request headers for a WebSocket, which the web's constructor can't. */
type HeaderSocket = new (url: string, options: { headers: Record<string, string> }) => WebSocket;

interface Options {
  url: string;
  key: string;
  bench: string;
  token: string | null;
  region: string | null;
  budget: number | null;
  /** Bytes in each 100 ms frame; 3200 is the app's 16 kHz PCM16. */
  frameBytes: number;
  label: string;
}

interface Ready {
  mode: string;
  sawAuthorization: boolean;
  sawApikey: boolean;
  benchVia: string;
  token: string;
  region: string | null;
  requestedRegion: string | null;
  executionId: string | null;
  cold: boolean;
  workerAgeMs: number;
  budgetMs: number;
}

/** One connection to the spike, with what came back over it. */
class Connection {
  readonly socket: WebSocket;
  readonly startedAt = performance.now();
  openMs: number | null = null;
  readyMs: number | null = null;
  ready: Ready | null = null;
  final: Record<string, unknown> | null = null;
  closeCode: number | null = null;
  error: string | null = null;
  bytesDown = 0;
  /** When each message arrived, for the longest silence between two. */
  private lastMessageAt: number | null = null;
  longestGapMs = 0;
  private waiters: { test: (message: Record<string, unknown>) => boolean; resolve: (message: Record<string, unknown> | null) => void }[] = [];
  /** Acknowledged audio frames: when frame `seq` (from 1) was acknowledged. */
  readonly ackedAt = new Map<number, number>();

  constructor(options: Options, query: Record<string, string> = {}, headers = true) {
    const url = new URL(options.url);
    // Named even for the default: the function sends a bench request without a mode to the relay.
    url.searchParams.set("mode", "echo");
    for (const [name, value] of Object.entries(query)) url.searchParams.set(name, value);
    if (options.budget) url.searchParams.set("budget", String(options.budget));
    if (headers) {
      const sent: Record<string, string> = { apikey: options.key, "x-murmur-bench": options.bench, "x-client-info": "live-spike" };
      if (options.token) sent.Authorization = `Bearer ${options.token}`;
      if (options.region) sent["x-region"] = options.region;
      this.socket = new (WebSocket as unknown as HeaderSocket)(url.href, { headers: sent });
    } else {
      url.searchParams.set("bench", options.bench);
      this.socket = new WebSocket(url.href);
    }
    this.socket.binaryType = "arraybuffer";
    this.socket.onopen = () => this.openMs = performance.now() - this.startedAt;
    this.socket.onerror = (event) => this.error = (event as ErrorEvent).message || "socket error";
    this.socket.onclose = (event) => {
      this.closeCode = event.code;
      for (const waiter of this.waiters.splice(0)) waiter.resolve(null);
    };
    this.socket.onmessage = (event) => {
      const at = performance.now();
      const data = event.data as string | ArrayBuffer;
      this.bytesDown += typeof data === "string" ? data.length : data.byteLength;
      if (this.lastMessageAt !== null) this.longestGapMs = Math.max(this.longestGapMs, at - this.lastMessageAt);
      this.lastMessageAt = at;
      if (typeof data !== "string") return;
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(data);
      } catch {
        return;
      }
      if (message.type === "spike.ready") {
        this.ready = message as unknown as Ready;
        this.readyMs = at - this.startedAt;
      } else if (message.type === "spike.ack") {
        this.ackedAt.set(message.seq as number, at);
      } else if (message.type === "spike.final") {
        this.final = message;
      } else if (message.type === "spike.error") {
        this.error = String(message.code);
      }
      const matched = this.waiters.filter((waiter) => waiter.test(message));
      this.waiters = this.waiters.filter((waiter) => !matched.includes(waiter));
      for (const waiter of matched) waiter.resolve(message);
    };
  }

  /** The next message `test` accepts; null when the socket closes or `timeoutMs` passes first. */
  next(test: (message: Record<string, unknown>) => boolean, timeoutMs: number): Promise<Record<string, unknown> | null> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((waiter) => waiter.resolve !== done);
        resolve(null);
      }, timeoutMs);
      const done = (message: Record<string, unknown> | null) => {
        clearTimeout(timer);
        resolve(message);
      };
      if (this.closeCode !== null) return done(null);
      this.waiters.push({ test, resolve: done });
    });
  }

  /** Waits for `spike.ready`; false when it didn't come. */
  async opened(timeoutMs = 10_000): Promise<boolean> {
    if (this.ready) return true;
    return (await this.next((message) => message.type === "spike.ready", timeoutMs)) !== null;
  }

  send(message: string | ArrayBuffer): boolean {
    if (this.socket.readyState !== WebSocket.OPEN) return false;
    this.socket.send(message);
    return true;
  }

  close() {
    if (this.socket.readyState <= WebSocket.OPEN) this.socket.close(1000);
  }
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
}

function rounded(value: number | null): number | null {
  return value === null ? null : Math.round(value);
}

function spread(values: number[]) {
  return { n: values.length, p50: rounded(percentile(values, 50)), p95: rounded(percentile(values, 95)), max: rounded(values.length ? Math.max(...values) : null) };
}

// MARK: Runs

async function handshake(options: Options) {
  const withHeaders = new Connection(options);
  const headersOk = await withHeaders.opened();
  const first = { ok: headersOk, openMs: rounded(withHeaders.openMs), readyMs: rounded(withHeaders.readyMs), ready: withHeaders.ready, error: withHeaders.error, closeCode: withHeaders.closeCode };
  withHeaders.close();
  const byQuery = new Connection(options, {}, false);
  const queryOk = await byQuery.opened();
  const second = { ok: queryOk, readyMs: rounded(byQuery.readyMs), benchVia: byQuery.ready?.benchVia ?? null, error: byQuery.error, closeCode: byQuery.closeCode };
  byQuery.close();
  return { headers: first, query: second };
}

async function echo(options: Options, count: number) {
  const connection = new Connection(options);
  if (!await connection.opened()) return { ok: false, error: connection.error, closeCode: connection.closeCode };
  const trips: number[] = [];
  for (let id = 0; id < count; id++) {
    const sentAt = performance.now();
    if (!connection.send(JSON.stringify({ type: "spike.ping", id }))) break;
    const pong = await connection.next((message) => message.type === "spike.pong" && message.id === id, 10_000);
    if (!pong) break;
    trips.push(performance.now() - sentAt);
  }
  connection.close();
  return { ok: trips.length === count, answered: trips.length, asked: count, roundTripMs: spread(trips), readyMs: rounded(connection.readyMs), region: connection.ready?.region ?? null };
}

async function download(options: Options, kilobytes: number) {
  const connection = new Connection(options);
  if (!await connection.opened()) return { ok: false, error: connection.error, closeCode: connection.closeCode };
  const pad = 4096;
  const count = Math.ceil((kilobytes * 1024) / pad);
  const startedAt = performance.now();
  let answered = 0;
  for (let id = 0; id < count; id++) {
    if (!connection.send(JSON.stringify({ type: "spike.ping", id, pad }))) break;
    const pong = await connection.next((message) => message.type === "spike.pong" && message.id === id, 15_000);
    if (!pong || (pong.pad as string).length !== pad) break;
    answered++;
  }
  const result = {
    ok: answered === count,
    askedKB: Math.round((count * pad) / 1024),
    receivedKB: Math.round(connection.bytesDown / 1024),
    ms: rounded(performance.now() - startedAt),
    longestGapMs: rounded(connection.longestGapMs),
    closeCode: connection.closeCode,
    error: connection.error,
  };
  connection.close();
  return result;
}

/** One stream of `seconds` at real-time pace, ended by finalize; how it went. */
async function stream(options: Options, seconds: number) {
  const connection = new Connection(options);
  if (!await connection.opened()) {
    return { ok: false, ended: "no ready", seconds: 0, error: connection.error, closeCode: connection.closeCode };
  }
  const frame = new Uint8Array(options.frameBytes).buffer;
  const sentAt: number[] = [];
  const begun = performance.now();
  const frames = Math.round((seconds * 1000) / FRAME_MS);
  for (let index = 0; index < frames; index++) {
    // An absolute clock: a late frame doesn't push the ones after it.
    await sleep(begun + index * FRAME_MS - performance.now());
    if (!connection.send(frame)) break;
    sentAt.push(performance.now());
  }
  const finalizedAt = performance.now();
  let ended = "closed early";
  let finalizeMs: number | null = null;
  if (sentAt.length === frames && connection.send(JSON.stringify({ type: "spike.finalize" }))) {
    const final = await connection.next((message) => message.type === "spike.final", 10_000);
    if (final) {
      ended = "final";
      finalizeMs = performance.now() - finalizedAt;
    } else {
      ended = connection.closeCode === null ? "no final in 10 s" : "closed before final";
    }
  }
  if (connection.error === "budget") ended = "budget";
  await sleep(200);
  const acks = sentAt.flatMap((at, index) => {
    const acked = connection.ackedAt.get(index + 1);
    return acked === undefined ? [] : [{ atSecond: Math.round((at - begun) / 100) / 10, ms: Math.round(acked - at) }];
  });
  const latencies = acks.map((ack) => ack.ms);
  const result = {
    ok: ended === "final" && latencies.length === frames,
    ended,
    seconds: Math.round((performance.now() - begun) / 100) / 10,
    framesSent: sentAt.length,
    framesAcked: latencies.length,
    ackMs: spread(latencies),
    // Where in the stream the slowest acknowledgements were: one stall delays a run of frames.
    slowest: [...acks].sort((a, b) => b.ms - a.ms).slice(0, 5),
    longestGapMs: rounded(connection.longestGapMs),
    finalizeMs: rounded(finalizeMs),
    readyMs: rounded(connection.readyMs),
    openMs: rounded(connection.openMs),
    region: connection.ready?.region ?? null,
    cold: connection.ready?.cold ?? null,
    workerAgeMs: connection.ready?.workerAgeMs ?? null,
    executionId: connection.ready?.executionId ?? null,
    closeCode: connection.closeCode,
    error: connection.error,
    serverStats: connection.final,
  };
  connection.close();
  return result;
}

// MARK: Setup

/** `NAME = value` lines of an xcconfig, as far as this needs them. */
export async function localConfig(): Promise<Record<string, string>> {
  try {
    const text = await Deno.readTextFile("Config/Local.xcconfig");
    return Object.fromEntries(
      text.split("\n").map((line) => line.match(/^\s*([A-Z_]+)\s*=\s*(.+?)\s*$/)).filter((match) => match !== null)
        // xcconfig writes "//" as "/$()/" so it isn't read as a comment.
        .map((match) => [match[1], match[2].replaceAll("$()", "")]),
    );
  } catch {
    return {};
  }
}

/** An access token for the project behind `host`: the kept session refreshed, else a new anonymous user. */
export async function userToken(host: string, key: string): Promise<string> {
  const auth = `https://${host}/auth/v1`;
  const headers = { apikey: key, "Content-Type": "application/json" };
  let session: { access_token?: string; refresh_token?: string } | null = null;
  try {
    const kept = JSON.parse(await Deno.readTextFile(SESSION_FILE));
    if (kept.host === host && kept.refresh_token) {
      const response = await fetch(`${auth}/token?grant_type=refresh_token`, {
        method: "POST", headers, body: JSON.stringify({ refresh_token: kept.refresh_token }),
      });
      if (response.ok) session = await response.json();
      else await response.body?.cancel();
    }
  } catch {
    // No session kept yet.
  }
  if (!session?.access_token) {
    console.error("Signing up one anonymous user for the spike (kept in scripts/out for the next runs)");
    const response = await fetch(`${auth}/signup`, { method: "POST", headers, body: JSON.stringify({ data: {} }) });
    if (!response.ok) throw new Error(`anonymous sign-up failed with HTTP ${response.status}`);
    session = await response.json();
  }
  await Deno.mkdir("scripts/out", { recursive: true });
  await Deno.writeTextFile(SESSION_FILE, JSON.stringify({ host, refresh_token: session!.refresh_token }));
  return session!.access_token!;
}

export function flagValue(name: string): string | undefined {
  const index = Deno.args.indexOf(name);
  return index === -1 ? undefined : Deno.args[index + 1];
}

if (import.meta.main) {
  const config = await localConfig();
  const host = (config.SUPABASE_HOST ?? "").replace(/^https?:\/\//, "").replace(/\/$/, "");
  const url = flagValue("--url") ?? (host ? `wss://${host}/functions/v1/live` : "");
  const key = flagValue("--key") ?? config.SUPABASE_ANON_KEY ?? "";
  const bench = flagValue("--bench") ?? Deno.env.get("LIVE_BENCH_KEY") ?? "";
  if (!url || !bench) throw new Error("--bench <LIVE_BENCH_KEY> is required, and --url unless Config/Local.xcconfig names the project");
  const urlHost = new URL(url).host;
  const token = Deno.args.includes("--no-token") ? null : flagValue("--token") ?? await userToken(urlHost, key);
  const options: Options = {
    url, key, bench, token,
    region: flagValue("--region") ?? null,
    budget: Number(flagValue("--budget")) || null,
    frameBytes: Number(flagValue("--frame-bytes")) || FRAME_BYTES,
    label: flagValue("--label") ?? "unnamed",
  };
  const runs = (flagValue("--run") ?? "handshake,echo,download,stream:60").split(",");

  const results: Record<string, unknown>[] = [];
  for (const run of runs) {
    const [name, argument] = run.split(":");
    console.error(`Running ${run}…`);
    if (name === "handshake") results.push({ run, ...await handshake(options) });
    else if (name === "echo") results.push({ run, ...await echo(options, Number(argument) || 200) });
    else if (name === "download") results.push({ run, ...await download(options, Number(argument) || 128) });
    else if (name === "stream") {
      const [seconds, times] = (argument ?? "60").split("x").map(Number);
      for (let index = 0; index < (times || 1); index++) results.push({ run, ...await stream(options, seconds || 60) });
    } else if (name === "concurrent") {
      const [count, seconds] = (argument ?? "5x120").split("x").map(Number);
      const streams = await Promise.all(Array.from({ length: count || 5 }, () => stream(options, seconds || 120)));
      for (const result of streams) results.push({ run, ...result });
    } else throw new Error(`unknown run: ${run}`);
  }

  const report = { label: options.label, at: new Date().toISOString(), url: `${urlHost}${new URL(url).pathname}`, region: options.region, results };
  const out = flagValue("--out") ?? `scripts/out/live_spike-${options.label}-${report.at.replaceAll(":", "").slice(0, 15)}.json`;
  await Deno.mkdir("scripts/out", { recursive: true });
  await Deno.writeTextFile(out, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  console.error(`Saved to ${out}`);
}
