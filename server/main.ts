// The dictation server: the functions a dictation waits on, in one long-running Deno process.
// It serves `dictate`, `transcribe`, `cleanup` and `live` under the same paths as Supabase
// (/functions/v1/<name>), from the same handlers (supabase/functions/_shared): nothing is copied,
// and the Supabase functions keep working beside it. Accounts, limits and usage stay in the
// Supabase project, which this server reaches with the project's URL and secret key.
//
// Unlike a Supabase worker, the process is always on: no cold start, no limit on how long it lives,
// and its connections to the database and the model services stay open between dictations.
//
//   GET /healthz   200 { ok, host, version, uptimeMs, configured } · 503 while it drains for a stop
//   /functions/v1/dictate | transcribe | cleanup | live   as each function's own header describes
//   503 { error: "edge_disabled" }    EDGE_DISABLED=1: the app falls back to the Supabase functions
//   503 { error: "not_configured" }   no SUPABASE_URL or key: only the network test below is served
// Every reply carries x-murmur-host: <MURMUR_HOST>.
//
// The network test (live/spike.ts) is served whenever LIVE_BENCH_KEY is set, with or without a
// Supabase project: a server with only that key is what scripts/bench/live_spike.ts is pointed at
// to see whether a hosting network can be reached.
//
// On SIGTERM or SIGINT the server stops taking live sockets (the app uploads instead), lets the
// requests and the sockets in hand finish for up to DRAIN_MS, then exits.
//
// Env: PORT (8080) · MURMUR_HOST (this home's name in the logs and the cost rows; "edge") ·
// MURMUR_REGION (where it runs, for the timings) · MURMUR_VERSION (the build) · DRAIN_MS (30000) ·
// EDGE_DISABLED=1 · SUPABASE_URL and SUPABASE_SECRET_KEYS (or SUPABASE_SERVICE_ROLE_KEY) ·
// and every variable the four functions read (OPENAI_API_KEY, ANTHROPIC_API_KEY, TRANSCRIBE_*,
// CLEANUP_*, TRANSLATE_*, DICTATE_*, LIVE_*, SONIOX_API_KEY). LIVE_WALL_CLOCK_MS is ignored here:
// nothing ends this process by its age.
//
//   deno run --allow-net --allow-env server/main.ts
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { createCleanupHandler } from "../supabase/functions/_shared/cleanup_handler.ts";
import {
  cleanupConfig,
  dictateConfig,
  type Env,
  envNumber,
  transcribeConfig,
  translationConfig,
} from "../supabase/functions/_shared/config.ts";
import { createCostRecorder } from "../supabase/functions/_shared/cost.ts";
import { createDictateHandler } from "../supabase/functions/_shared/dictate.ts";
import { adminClient, authenticate, background, drainBackground, json } from "../supabase/functions/_shared/http.ts";
import { createLiveHandler, liveConfig } from "../supabase/functions/_shared/live.ts";
import type { LiveTarget } from "../supabase/functions/_shared/live/adapter.ts";
import { soniox } from "../supabase/functions/_shared/live/soniox.ts";
import { dictationPreflight, readQuota, recordUsage } from "../supabase/functions/_shared/preflight.ts";
import { beginRequest, type RequestStart } from "../supabase/functions/_shared/timing.ts";
import { createTranscribeHandler } from "../supabase/functions/_shared/transcribe_handler.ts";
import { createSpikeHandler } from "../supabase/functions/live/spike.ts";

type Handler = (request: Request) => Response | Promise<Response>;

/** Deno takes request headers for an outbound WebSocket, which the web's constructor can't. */
type OutboundSocket = new (url: string, options: { headers: Record<string, string>; protocols?: string[] }) => WebSocket;

function connect(target: LiveTarget): WebSocket {
  return new (WebSocket as unknown as OutboundSocket)(target.url, {
    headers: target.headers ?? {},
    ...(target.protocols ? { protocols: target.protocols } : {}),
  });
}

export interface ServerOptions {
  /** The service-role client; made from the env on first use when left out. */
  admin?: () => SupabaseClient;
  /** Replaces `fetch` for the model calls. */
  fetcher?: typeof fetch;
  /** `Deno.upgradeWebSocket`. */
  upgrade?: (request: Request) => { socket: WebSocket; response: Response };
  /** The clock for the uptime (`Date.now`). */
  now?: () => number;
  log?: (line: string) => void;
}

export interface Server {
  handler: (request: Request) => Promise<Response>;
  /** Stops taking live sockets and reports unhealthy, so the platform sends traffic elsewhere. */
  beginDrain(): void;
  /** This home's name, as the logs and the cost rows carry it. */
  host: string;
  /** Whether the Supabase project is configured: without it only the network test is served. */
  configured: boolean;
}

const FUNCTIONS = "/functions/v1/";

/** The server's request handler, from its environment. Nothing listens yet: `serve` does that. */
export function createServer(env: Env, options: ServerOptions = {}): Server {
  const now = options.now ?? (() => Date.now());
  const bootedAt = now();
  const host = env.get("MURMUR_HOST")?.trim() || "edge";
  const region = env.get("MURMUR_REGION")?.trim() || null;
  const version = env.get("MURMUR_VERSION")?.trim() || "dev";
  // One id per boot: requests that share it shared this process, as a Supabase worker's execution id says.
  const instance = crypto.randomUUID();
  const disabled = env.get("EDGE_DISABLED") === "1";
  const configured = Boolean(
    options.admin || (env.get("SUPABASE_URL") && (env.get("SUPABASE_SECRET_KEYS") || env.get("SUPABASE_SERVICE_ROLE_KEY"))),
  );
  let draining = false;

  let client: SupabaseClient | undefined;
  const admin = options.admin ?? (() => client ??= adminClient());
  const upgrade = options.upgrade ?? ((request: Request) => Deno.upgradeWebSocket(request));
  /** The process as the functions' timings see a worker: cold once, then as old as its uptime. */
  const worker = (): RequestStart => {
    const start = beginRequest(env);
    return { ...start, region: start.region ?? region, executionId: start.executionId ?? instance };
  };
  const recordCost = createCostRecorder(admin, { host });
  const shared = { background, worker, log: options.log, fetcher: options.fetcher };

  // No platform ends this process by its age, so a socket's time is its own bound alone.
  const live = { ...liveConfig(env), wallClockMs: null };

  const spike = createSpikeHandler({
    benchKey: live.benchKey,
    maxSessionMs: live.maxSessionMs,
    upgrade,
    // The network test only echoes here: a service is reached through the relay itself.
    upstream: () => null,
    connect,
    verifyToken: async (request) => {
      if (!configured) return null;
      try {
        return (await authenticate(request, admin())) !== null;
      } catch {
        return null;
      }
    },
    background,
    worker,
    log: options.log,
  });

  /** The functions, made on the first request that needs them: a server with no project serves none. */
  let functions: Record<string, Handler> | undefined;
  const routes = () =>
    functions ??= {
      dictate: createDictateHandler({
        ...shared,
        config: dictateConfig(env),
        apiKey: env.get("OPENAI_API_KEY"),
        anthropicApiKey: env.get("ANTHROPIC_API_KEY"),
        authenticate: (request) => authenticate(request, admin()),
        preflight: (caller, scope, dictationId, perMinute) => dictationPreflight(admin(), caller, scope, dictationId, perMinute),
        readQuota: (caller, signal) => readQuota(admin(), caller, signal),
        recordUsage: (caller, dictationId, words) => recordUsage(admin(), caller, dictationId, words),
        recordCost,
      }),
      transcribe: createTranscribeHandler({
        ...shared,
        admin: admin(),
        config: transcribeConfig(env),
        apiKey: env.get("OPENAI_API_KEY"),
        disabled: env.get("TRANSCRIBE_DISABLED") === "1",
        failClosed: env.get("TRANSCRIBE_FAIL_CLOSED") === "1",
        authenticate: (request) => authenticate(request, admin()),
        recordCost,
      }),
      cleanup: createCleanupHandler({
        ...shared,
        admin: admin(),
        cleanup: cleanupConfig(env),
        translation: translationConfig(env),
        disabled: env.get("CLEANUP_DISABLED") === "1",
        key: (name) => env.get(name),
        authenticate: (request) => authenticate(request, admin()),
        recordCost,
      }),
      live: createLiveHandler({
        config: live,
        authenticate: (request) => authenticate(request, admin()),
        preflight: (caller, scope, dictationId, perMinute) => dictationPreflight(admin(), caller, scope, dictationId, perMinute),
        recordUsage: (caller, dictationId, words) => recordUsage(admin(), caller, dictationId, words),
        recordCost,
        background,
        upgrade,
        connect,
        adapters: { soniox },
        worker,
        log: options.log,
      }),
    };

  async function route(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") {
      return json({ ok: !draining, host, version, uptimeMs: now() - bootedAt, configured, draining }, draining ? 503 : 200);
    }
    if (!url.pathname.startsWith(FUNCTIONS)) return json({ error: "not_found" }, 404);
    const name = url.pathname.slice(FUNCTIONS.length);

    // A run of the network test carries the bench key, which the test itself checks, and names its mode.
    const bench = request.headers.has("x-murmur-bench") || url.searchParams.has("bench");
    if (name === "live" && bench && url.searchParams.has("mode")) return await spike(request);

    if (!["dictate", "transcribe", "cleanup", "live"].includes(name)) return json({ error: "not_found" }, 404);
    if (disabled) return json({ error: "edge_disabled" }, 503);
    if (!configured) return json({ error: "not_configured" }, 503);
    // A socket opened now would be cut by the stop: the app uploads this dictation instead.
    if (name === "live" && draining) return json({ error: "live_unavailable" }, 503);
    return await routes()[name](request);
  }

  return {
    handler: async (request) => {
      const response = await route(request);
      // A WebSocket upgrade's response can't be changed, and needs no label.
      if (response.status !== 101) {
        try {
          response.headers.set("x-murmur-host", host);
        } catch {
          // Immutable headers: the reply goes out as it is.
        }
      }
      return response;
    },
    beginDrain: () => void (draining = true),
    host,
    configured,
  };
}

if (import.meta.main) {
  const server = createServer(Deno.env);
  const port = envNumber(Deno.env, "PORT", 8080);
  const drainMs = envNumber(Deno.env, "DRAIN_MS", 30_000);
  const listener = Deno.serve({ port, hostname: "0.0.0.0", onListen: () => {} }, server.handler);
  console.log(JSON.stringify({
    event: "server_start",
    host: server.host,
    version: Deno.env.get("MURMUR_VERSION") ?? "dev",
    port,
    configured: server.configured,
    networkTest: Boolean(Deno.env.get("LIVE_BENCH_KEY")),
  }));

  let stopping = false;
  const stop = async (signal: string) => {
    if (stopping) return;
    stopping = true;
    console.log(JSON.stringify({ event: "server_stop", signal, drainMs }));
    server.beginDrain();
    // The requests in hand finish; the live sockets and the writes after a reply are waited for.
    const unfinished = await Promise.race([
      listener.shutdown().then(() => drainBackground(drainMs)),
      new Promise<number>((resolve) => setTimeout(() => resolve(-1), drainMs)),
    ]);
    console.log(JSON.stringify({ event: "server_stopped", unfinished }));
    Deno.exit(0);
  };
  for (const signal of ["SIGTERM", "SIGINT"] as const) Deno.addSignalListener(signal, () => void stop(signal));
}
