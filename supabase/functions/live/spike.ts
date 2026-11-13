// The relay spike: what a long-lived WebSocket through an edge function survives and costs on
// the hosted project, measured before the live relay is built on it. `scripts/bench/live_spike.ts`
// is its only client, and every request needs the bench key (LIVE_BENCH_KEY).
//
// Two modes, chosen by `?mode=`:
//   echo      (default) answers each audio frame with a small `spike.ack`, so the client can time
//             every frame and see a stall; nothing leaves the function.
//   upstream  opens a second WebSocket to `?provider=` with the server's key and passes frames
//             both ways untouched, buffering what arrives before that socket is open.
// In both, the function's own messages have a `type` that starts with "spike.":
//   → spike.ping { id, pad? }   ← spike.pong { id, t, pad }   (pad: that many bytes back, to test
//                                                               a large download on one socket)
//   → spike.finalize            ← spike.final { frames, bytesIn, bytesOut, sessionMs, … }, close 1000
//   ← spike.ready { mode, sawAuthorization, token, region, executionId, workerAgeMs, budgetMs, … }
//   ← spike.upstream { ms }     the provider's socket opened, that long after it was asked for
//   ← spike.error { code }      budget (close 1012), upstream, bad_request
// `?budget=<ms>` replaces the function's own time limit for one socket (up to 10 minutes), so a
// run can find where the platform cuts it.
import type { RequestStart } from "../_shared/timing.ts";

/** Where a provider's realtime socket is, and the headers that carry the server's key. */
export interface Upstream {
  url: string;
  headers: Record<string, string>;
}

export interface SpikeDeps {
  /** LIVE_BENCH_KEY. Without it every request gets 503: the spike is closed. */
  benchKey: string | undefined;
  /** The function closes the socket itself after this long, ahead of the platform's wall clock. */
  maxSessionMs: number;
  /** `Deno.upgradeWebSocket`. */
  upgrade(request: Request): { socket: WebSocket; response: Response };
  /** The provider's socket for upstream mode, or null when the provider is unknown or has no key. */
  upstream(provider: string): Upstream | null;
  /** Opens the outbound socket. */
  connect(upstream: Upstream): WebSocket;
  /** Whether the bearer token names a user; null when it can't be checked here (no project URL). */
  verifyToken(request: Request): Promise<boolean | null>;
  /** Keeps the worker alive until `work` settles (`EdgeRuntime.waitUntil`). */
  background(work: Promise<unknown>): void;
  /** Counts the request against the worker (`beginRequest`). */
  worker(): RequestStart;
  now?: () => number;
  /** Runs `work` after `ms`; the returned function cancels it. */
  schedule?: (ms: number, work: () => void) => () => void;
  log?: (line: string) => void;
}

/** At most this much is held for a provider's socket that isn't open yet. */
const MAX_BUFFERED_BYTES = 2 * 1024 * 1024;
/** The largest `pad` a ping may ask for. */
const MAX_PAD_BYTES = 64 * 1024;
/** The longest budget a run may ask for with `?budget=`, to find where the platform cuts a socket. */
const MAX_BUDGET_MS = 600_000;

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function sizeOf(data: string | ArrayBuffer): number {
  return typeof data === "string" ? data.length : data.byteLength;
}

/** A relay control message, or null for anything that is the provider's to read. */
function control(data: unknown): { type: string; id?: unknown; pad?: unknown } | null {
  if (typeof data !== "string" || !data.includes('"spike.')) return null;
  try {
    const message = JSON.parse(data);
    return typeof message?.type === "string" && message.type.startsWith("spike.") ? message : null;
  } catch {
    return null;
  }
}

export function createSpikeHandler(deps: SpikeDeps): (request: Request) => Promise<Response> {
  const now = deps.now ?? (() => performance.now());
  const log = deps.log ?? ((line: string) => console.log(line));
  const schedule = deps.schedule ?? ((ms: number, work: () => void) => {
    const timer = setTimeout(work, ms);
    return () => clearTimeout(timer);
  });

  return async (request) => {
    const worker = deps.worker();
    if (!deps.benchKey) return json({ error: "live_unavailable" }, 503);
    const url = new URL(request.url);
    const benchHeader = request.headers.get("x-murmur-bench");
    // A client that can't set headers on the upgrade (a browser) passes the key in the query.
    if ((benchHeader ?? url.searchParams.get("bench")) !== deps.benchKey) return json({ error: "unauthorized" }, 401);
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return json({ error: "bad_request", detail: "a WebSocket upgrade is required" }, 400);
    }
    const mode = url.searchParams.get("mode") ?? "echo";
    const provider = url.searchParams.get("provider") ?? "";
    const upstream = mode === "upstream" ? deps.upstream(provider) : null;
    if (mode !== "echo" && mode !== "upstream") return json({ error: "bad_request", detail: "mode must be echo or upstream" }, 400);
    if (mode === "upstream" && !upstream) return json({ error: "live_unavailable", detail: "no such provider, or no key for it" }, 503);
    const asked = Number(url.searchParams.get("budget"));
    const budgetMs = Number.isFinite(asked) && asked >= 1000 ? Math.min(asked, MAX_BUDGET_MS) : deps.maxSessionMs;
    const token = request.headers.has("authorization") ? await deps.verifyToken(request) : null;

    const { socket, response } = deps.upgrade(request);
    socket.binaryType = "arraybuffer";
    const openedAt = now();
    const counts = { frames: 0, bytesIn: 0, bytesOut: 0, messagesOut: 0 };
    let outbound: WebSocket | null = null;
    let outboundOpen = false;
    let upstreamMs: number | null = null;
    let waiting: (string | ArrayBuffer)[] = [];
    let waitingBytes = 0;
    let closeReason = "client";
    let finished = false;

    const send = (message: string | ArrayBuffer) => {
      if (socket.readyState !== WebSocket.OPEN) return;
      socket.send(message);
      counts.bytesOut += sizeOf(message);
      counts.messagesOut++;
    };
    const say = (type: string, fields: Record<string, unknown> = {}) => send(JSON.stringify({ type, ...fields }));
    const end = (code: number, reason: string) => {
      closeReason = reason;
      if (socket.readyState === WebSocket.OPEN) socket.close(code, reason);
    };
    const stats = () => ({ ...counts, sessionMs: Math.round(now() - openedAt), upstreamMs });

    // The worker must outlive the reply to the upgrade: without a pending promise it can be
    // retired with the socket still open.
    const closed = new Promise<void>((resolve) => {
      const cancelBudget = schedule(budgetMs, () => {
        say("spike.error", { code: "budget" });
        end(1012, "budget");
      });
      socket.onclose = (event) => {
        if (finished) return;
        finished = true;
        cancelBudget();
        if (outbound && outbound.readyState <= WebSocket.OPEN) outbound.close();
        log(JSON.stringify({
          event: "live_spike",
          mode,
          provider: provider || null,
          closeCode: event.code,
          closeReason,
          ...stats(),
          ...worker,
          workerAgeMsAtClose: Math.round(worker.workerAgeMs + (now() - openedAt)),
        }));
        resolve();
      };
    });
    deps.background(closed);

    socket.onopen = () => {
      say("spike.ready", {
        mode,
        provider: provider || null,
        sawAuthorization: request.headers.has("authorization"),
        sawApikey: request.headers.has("apikey"),
        benchVia: benchHeader ? "header" : "query",
        token: token === null ? "unchecked" : token ? "valid" : "invalid",
        region: worker.region,
        requestedRegion: request.headers.get("x-region"),
        executionId: worker.executionId,
        cold: worker.cold,
        workerAgeMs: worker.workerAgeMs,
        budgetMs,
      });
      if (!upstream) return;
      const asked = now();
      try {
        outbound = deps.connect(upstream);
      } catch (error) {
        say("spike.error", { code: "upstream", detail: error instanceof Error ? error.name : String(error) });
        return end(1011, "upstream");
      }
      outbound.binaryType = "arraybuffer";
      outbound.onopen = () => {
        outboundOpen = true;
        upstreamMs = Math.round(now() - asked);
        say("spike.upstream", { ms: upstreamMs });
        for (const message of waiting) outbound!.send(message);
        waiting = [];
        waitingBytes = 0;
      };
      outbound.onmessage = (event) => send(event.data);
      outbound.onerror = () => say("spike.error", { code: "upstream" });
      outbound.onclose = (event) => {
        say("spike.final", { ...stats(), upstreamCloseCode: event.code });
        end(1000, "upstream closed");
      };
    };

    socket.onmessage = (event) => {
      const data = event.data as string | ArrayBuffer;
      counts.bytesIn += sizeOf(data);
      const message = control(data);
      if (message?.type === "spike.ping") {
        const pad = Math.min(MAX_PAD_BYTES, Math.max(0, Number(message.pad) || 0));
        return say("spike.pong", { id: message.id, t: Date.now(), pad: "x".repeat(pad) });
      }
      if (message?.type === "spike.finalize") {
        say("spike.final", stats());
        return end(1000, "finalized");
      }
      if (message) return say("spike.error", { code: "bad_request" });
      if (typeof data !== "string") counts.frames++;
      if (!upstream) {
        // Echo mode: an acknowledgement per audio frame; a text frame comes straight back.
        return typeof data === "string" ? send(data) : say("spike.ack", { seq: counts.frames, bytes: data.byteLength });
      }
      if (outboundOpen) return outbound!.send(data);
      waitingBytes += sizeOf(data);
      if (waitingBytes > MAX_BUFFERED_BYTES) {
        say("spike.error", { code: "upstream", detail: "the provider's socket didn't open in time" });
        return end(1011, "backlog");
      }
      waiting.push(data);
    };

    return response;
  };
}
