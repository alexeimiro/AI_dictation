// GET /functions/v1/live (a WebSocket upgrade)
// One socket per dictation. The app streams its audio while the user speaks; the relay
// (_shared/live.ts) passes it to a speech service and sends back the words as they settle, then
// the final text. The service is the one LIVE_PROVIDER names, spoken to through its adapter
// (_shared/live/), so the app only knows this protocol, version 1.
// The upgrade carries Authorization: Bearer <user JWT> and x-murmur-dictation: <the dictation's
// id>. From those headers alone the preflight (attempts, rate limit, quota, in scope "live": only
// a dictation's first socket takes from the minute's 40, or 10 for an anonymous caller) and the
// connection to the service start at once, before the app's first message.
//   → text    { type: "start", v: 1, dictationId, language: BCP-47 | null, languages?: BCP-47[],
//               keywords?: string[], audio: { format: "pcm_s16le", rate: 16000, channels: 1 },
//               client? }  dictationId is the header's; `languages` are hints while the language
//             is detected; up to 100 keywords. Audio may follow at once.
//   → binary  PCM16LE mono 16 kHz, 20–250 ms a frame. Up to 12 s of it waits for the service.
//   → text    { type: "finalize", audioMs }  the user tapped done. A close without it, or before
//             the final text, is a cancel: nothing is counted.
//   ← { type: "ready", v: 1, provider, audio: { rate: 16000, maxChunkMs: 250 }, budgetSeconds,
//       region, caps: { languageDetection }, policy: { hedgeAfterMs: 1000, finalizeDeadlineMs: 2500 } }
//       `start` is in, the preflight passed and the audio is reaching the service. `budgetSeconds`
//       is how long this socket can last, from the upgrade.
//   ← { type: "partial", seq, stable, volatile, lang? }  display only, at most one in 100 ms.
//       `stable` is the settled text since the last partial and is never revised; `volatile`
//       replaces the one before (its last 200 characters).
//   ← { type: "final", text, languages, audioMs, words, remaining, timings: { region, cold,
//       workerAgeMs, upstreamMs, firstPartialMs, finalizeMs, totalMs } }, then close 1000.
//       `text` is the whole dictation and replaces the partials; `audioMs` is the audio the relay
//       received; `words` is what was counted toward the free plan's week and `remaining` what is
//       left of it (null when unlimited). `upstreamMs` is the service's handshake, `finalizeMs`
//       runs from `finalize`, and `firstPartialMs` and `totalMs` from the upgrade.
//   ← { type: "error", code, retryable }, never any text, then close:
//       1000  limit_reached · rate_limited · idle (no audio for 15 s) · finalize_timeout (no final
//             text 2.5 s after `finalize`)
//       1008  bad_request · unsupported_version
//       1011  provider (the service failed) · unavailable (the relay or its account at the
//             service can't serve the dictation)
//       1012  budget (the socket's time is up)
//       `retryable`: another socket may work. False for what a new one would meet again: the
//       week's words used up, a message the relay can't read, the server's account at the service.
// A message of a type the relay doesn't know is ignored.
// Responses before the upgrade: 400 bad_request (not an upgrade, or no dictation id) ·
// 401 unauthorized · 429 too_many_sockets (3 per caller on a worker) · 503 live_unavailable
// (LIVE_DISABLED=1, no such provider, no key for it, the token check failed, or the worker has
// under 20 s left) → the app uploads the dictation as before.
// A socket lasts min(LIVE_MAX_SESSION_MS, LIVE_WALL_CLOCK_MS − the worker's age − 5 s): the
// platform ends a worker that long after it booted, with every socket on it.
// The relay spike (spike.ts) stays for bench runs: a request with the bench key (`x-murmur-bench`,
// or `?bench=`) and `?mode=` goes to it. A bench key without `?mode=` reaches the relay, where
// `?provider=` may choose the service for that socket.
// Env: LIVE_PROVIDER (default soniox), SONIOX_API_KEY, LIVE_SONIOX_MODEL (default stt-rt-v6),
// LIVE_MAX_SESSION_MS (default 140000), LIVE_WALL_CLOCK_MS (default 150000, the Free plan's; a
// paid plan's is 400000), LIVE_DISABLED=1, LIVE_BENCH_KEY (bench runs and the spike).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { adminClient, authenticate, background } from "../_shared/http.ts";
import { createLiveHandler, liveConfig } from "../_shared/live.ts";
import type { LiveTarget } from "../_shared/live/adapter.ts";
import { soniox } from "../_shared/live/soniox.ts";
import { dictationPreflight, recordUsage } from "../_shared/preflight.ts";
import { beginRequest } from "../_shared/timing.ts";
import { createSpikeHandler, type Upstream } from "./spike.ts";

/** Deno takes request headers for an outbound WebSocket, which the web's constructor can't. */
type OutboundSocket = new (url: string, options: { headers: Record<string, string>; protocols?: string[] }) => WebSocket;

const config = liveConfig();

let client: SupabaseClient | undefined;
/** The service-role client, made by the first request that needs it: the spike also runs with no project to ask. */
const admin = () => client ??= adminClient();

function connect(target: LiveTarget): WebSocket {
  return new (WebSocket as unknown as OutboundSocket)(target.url, {
    headers: target.headers ?? {},
    // Named only when the service asks for them, so a socket without them is opened as the spike opens it.
    ...(target.protocols ? { protocols: target.protocols } : {}),
  });
}

/** The spike's pass-through: the provider's socket, or null when it is unknown or has no key. */
function upstream(provider: string): Upstream | null {
  const sonioxKey = config.providers.soniox.apiKey;
  if (provider === "soniox" && sonioxKey) {
    return { url: "wss://stt-rt.soniox.com/transcribe-websocket", headers: { Authorization: `Bearer ${sonioxKey}` } };
  }
  return null;
}

/** The bearer token checked as the other functions check it; null without a project to ask. */
async function verifyToken(request: Request): Promise<boolean | null> {
  if (!Deno.env.get("SUPABASE_URL")) return null;
  try {
    return (await authenticate(request, admin())) !== null;
  } catch {
    return null;
  }
}

const spike = createSpikeHandler({
  benchKey: config.benchKey,
  maxSessionMs: config.maxSessionMs,
  upgrade: (request) => Deno.upgradeWebSocket(request),
  upstream,
  connect,
  verifyToken,
  background,
  worker: () => beginRequest(),
});

const live = createLiveHandler({
  config,
  authenticate: async (request) => await authenticate(request, admin()),
  preflight: async (caller, scope, dictationId, perMinute) =>
    await dictationPreflight(admin(), caller, scope, dictationId, perMinute),
  recordUsage: async (caller, dictationId, words) => await recordUsage(admin(), caller, dictationId, words),
  background,
  upgrade: (request) => Deno.upgradeWebSocket(request),
  connect,
  adapters: { soniox },
  worker: () => beginRequest(),
});

Deno.serve((request) => {
  const url = new URL(request.url);
  // A run of the spike carries the bench key, which the spike itself checks, and names its mode.
  const bench = request.headers.has("x-murmur-bench") || url.searchParams.has("bench");
  return bench && url.searchParams.has("mode") ? spike(request) : live(request);
});
