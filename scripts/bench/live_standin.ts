// The live relay on localhost, around a stand-in for the speech service: the real relay
// (supabase/functions/_shared/live.ts) and its real Soniox adapter, streaming to a local socket
// that speaks Soniox's protocol and "hears" one scripted word in every 300 ms of audio. For trying
// live_bench.ts, and later the app's own live client, with no key and nothing leaving the Mac.
//
//   deno run --allow-net=127.0.0.1 scripts/bench/live_standin.ts [--port 8787] [--finalize-ms 250] [--word-ms 300] [--auth-ms 80]
//   deno run … scripts/bench/live_bench.ts --url ws://127.0.0.1:8787/functions/v1/live --token local --clips <dir>
//
// Every dictation is allowed and none is counted: there is no database behind it. The bearer token
// must be "local". --finalize-ms is how long the stand-in takes to settle the text after the app's
// `finalize`, as a real service's last words take; --auth-ms how long the token check holds the
// upgrade, as the hosted one's does.
import { createLiveHandler, liveConfig } from "../../supabase/functions/_shared/live.ts";
import type { LiveProvider } from "../../supabase/functions/_shared/live/adapter.ts";
import { soniox } from "../../supabase/functions/_shared/live/soniox.ts";

/** The bearer token the local relay takes. */
export const LOCAL_TOKEN = "local";
/** The server's key for the "service". */
const STANDIN_KEY = "standin-key";
/** 16 kHz mono PCM16. */
const BYTES_PER_MS = 32;

/** What the stand-in hears, in order and again from the first, in the language it was hinted. */
const WORDS: Record<string, string[]> = {
  en: "one two three four five six seven eight nine ten".split(" "),
  ru: "раз два три четыре пять шесть семь восемь девять десять".split(" "),
};

/** Deno takes request headers for an outbound WebSocket, which the web's constructor can't. */
type OutboundSocket = new (url: string, options: { headers: Record<string, string> }) => WebSocket;

export interface StandInOptions {
  port?: number;
  /** One word is heard in this much audio (300 ms). */
  wordMs?: number;
  /** How long the settled text takes after a finalize (0). */
  finalizeMs?: number;
  /** Every socket fails with a 503 once it has had this many audio frames. */
  failAfterFrames?: number;
}

/** One socket of the stand-in: what it was sent, and what it answered. */
export interface StandInSession {
  authorization: string | null;
  /** The configuration it was sent first. */
  config: Record<string, unknown> | null;
  audioBytes: number;
  /** The settled text it sent. */
  text: string;
  finalized: boolean;
  closeCode: number | null;
}

export interface StandIn {
  /** ws://127.0.0.1:<port>/transcribe-websocket */
  url: string;
  /** Every socket so far, oldest first. */
  sessions: StandInSession[];
  shutdown(): Promise<void>;
}

/** A local socket that speaks Soniox's realtime protocol (_shared/live/soniox.ts) from a script. */
export function serveStandIn(options: StandInOptions = {}): StandIn {
  const wordBytes = (options.wordMs ?? 300) * BYTES_PER_MS;
  const sessions: StandInSession[] = [];
  const server = Deno.serve({ hostname: "127.0.0.1", port: options.port ?? 0, onListen: () => {} }, (request) => {
    const session: StandInSession = {
      authorization: request.headers.get("authorization"),
      config: null,
      audioBytes: 0,
      text: "",
      finalized: false,
      closeCode: null,
    };
    sessions.push(session);
    if (session.authorization !== `Bearer ${STANDIN_KEY}`) return new Response("unauthorized", { status: 401 });
    const { socket, response } = Deno.upgradeWebSocket(request);
    socket.binaryType = "arraybuffer";
    let language = "en";
    let heard = 0;
    let frames = 0;
    /** The newest words, which a service keeps revising: sent again with every reply. */
    const unsettled: string[] = [];
    let settling: ReturnType<typeof setTimeout> | undefined;

    /** A reply as Soniox sends it: the newly settled tokens once, then everything unsettled. */
    const reply = (settled: string[], markers: string[] = []) => {
      if (socket.readyState !== WebSocket.OPEN) return;
      session.text += settled.join("");
      socket.send(JSON.stringify({
        tokens: [
          ...settled.map((text) => ({ text, is_final: true, language })),
          ...markers.map((text) => ({ text, is_final: true })),
          ...unsettled.map((text) => ({ text, is_final: false, language })),
        ],
      }));
    };

    socket.onmessage = (event) => {
      const data = event.data as string | ArrayBuffer;
      if (typeof data !== "string") {
        frames++;
        session.audioBytes += data.byteLength;
        if (frames === options.failAfterFrames) {
          socket.send(JSON.stringify({ error_code: 503, error_type: "service_unavailable", error_message: "the stand-in was told to fail" }));
          return socket.close(1000);
        }
        const due = Math.floor(session.audioBytes / wordBytes);
        if (due === heard) return;
        const words = WORDS[language];
        while (heard < due) unsettled.push(` ${words[heard++ % words.length]}`);
        // All but the newest two settle.
        return reply(unsettled.splice(0, Math.max(0, unsettled.length - 2)));
      }
      if (!session.config) {
        try {
          session.config = JSON.parse(data);
        } catch {
          session.config = {};
        }
        const hints = session.config?.language_hints;
        if (Array.isArray(hints) && typeof hints[0] === "string" && Object.hasOwn(WORDS, hints[0])) language = hints[0];
        return;
      }
      // An empty text frame ends the stream.
      if (data === "") {
        socket.send(JSON.stringify({ tokens: [], finished: true }));
        return socket.close(1000);
      }
      if (data.includes('"finalize"')) {
        const settle = () => {
          session.finalized = true;
          reply([...unsettled.splice(0), "."], ["<fin>"]);
        };
        if (options.finalizeMs) settling = setTimeout(settle, options.finalizeMs);
        else settle();
      }
    };
    socket.onclose = (event) => {
      clearTimeout(settling);
      session.closeCode = event.code;
    };
    return response;
  });
  const { port } = server.addr as Deno.NetAddr;
  return { url: `ws://127.0.0.1:${port}/transcribe-websocket`, sessions, shutdown: () => server.shutdown() };
}

export interface LocalRelay {
  /** ws://127.0.0.1:<port>/functions/v1/live */
  url: string;
  /** What `record_usage` would have been sent. */
  usage: { dictationId: string; words: number }[];
  /** The relay's log lines, parsed. */
  logs: Record<string, unknown>[];
  shutdown(): Promise<void>;
}

export interface LocalRelayOptions {
  port?: number;
  /** With it on a request, a socket may choose its service (`?provider=`), as on the hosted relay. */
  benchKey?: string;
  /** How long the token check takes before the upgrade is answered (0): a cold hosted worker takes about 80 ms. */
  authMs?: number;
  log?: (line: string) => void;
}

/** The relay itself on localhost, with `service` as its Soniox and nothing behind it to ask. */
export function serveRelay(service: StandIn, options: LocalRelayOptions = {}): LocalRelay {
  const local: LiveProvider = {
    target: (access) => ({ ...soniox.target!(access), url: service.url }),
    adapter: (dictation) => {
      const adapter = soniox.adapter(dictation);
      return adapter && { ...adapter, target: () => local.target!(dictation) };
    },
  };
  const usage: LocalRelay["usage"] = [];
  const logs: LocalRelay["logs"] = [];
  const kept = new Set<Promise<unknown>>();
  const env = new Map([["SONIOX_API_KEY", STANDIN_KEY], ...(options.benchKey ? [["LIVE_BENCH_KEY", options.benchKey] as const] : [])]);
  let served = 0;
  const handler = createLiveHandler({
    config: liveConfig(env),
    authenticate: async (request) => {
      const known = request.headers.get("authorization") === `Bearer ${LOCAL_TOKEN}`;
      if (options.authMs) await new Promise((resolve) => setTimeout(resolve, options.authMs));
      return known ? { userId: "1b4e28ba-2fa1-41d2-883f-0016d3cca427", isAnonymous: false } : null;
    },
    preflight: () => Promise.resolve({ allowed: true, reason: null, plan: "pro", remaining: null, attempt: 1 }),
    recordUsage: (_caller, dictationId, words) => {
      usage.push({ dictationId, words });
      return Promise.resolve();
    },
    background: (work) => {
      const settled = Promise.resolve(work).catch(() => {}).finally(() => kept.delete(settled));
      kept.add(settled);
    },
    upgrade: (request) => Deno.upgradeWebSocket(request),
    connect: (target) => new (WebSocket as unknown as OutboundSocket)(target.url, { headers: target.headers ?? {} }),
    adapters: { soniox: local },
    // A worker that never ages: no platform ends this one, so every socket gets the whole budget.
    worker: () => ({ cold: served++ === 0, workerAgeMs: 0, region: "local", executionId: "standin" }),
    log: (line) => {
      logs.push(JSON.parse(line));
      options.log?.(line);
    },
  });
  const server = Deno.serve({ hostname: "127.0.0.1", port: options.port ?? 0, onListen: () => {} }, handler);
  const { port } = server.addr as Deno.NetAddr;
  return {
    url: `ws://127.0.0.1:${port}/functions/v1/live`,
    usage,
    logs,
    async shutdown() {
      await Promise.all(kept);
      await server.shutdown();
    },
  };
}

function flagNumber(name: string): number | undefined {
  const index = Deno.args.indexOf(name);
  const value = index === -1 ? NaN : Number(Deno.args[index + 1]);
  return Number.isFinite(value) && value >= 0 ? value : undefined;
}

if (import.meta.main) {
  const service = serveStandIn({ wordMs: flagNumber("--word-ms"), finalizeMs: flagNumber("--finalize-ms") });
  const relay = serveRelay(service, {
    port: flagNumber("--port") ?? 8787,
    authMs: flagNumber("--auth-ms"),
    log: (line) => console.log(line),
  });
  console.error(`The live relay is at ${relay.url} (bearer token "${LOCAL_TOKEN}"), its stand-in service at ${service.url}`);
}
