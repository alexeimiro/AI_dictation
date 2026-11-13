// The live bake-off's client: plays recordings through the `live` relay (its protocol is in
// supabase/functions/live/index.ts) the way the app will, and times what comes back. Each clip is
// one dictation. The socket is opened and the audio starts at the same moment, as at a tap on the
// mic; the frames go out at the pace they were spoken, the ones spoken before the socket opened
// right after it; `finalize` follows the last one, as at a tap on done. It never speaks to a
// speech service itself: the relay does, with the server's keys.
//
//   deno run --allow-net --allow-read --allow-write --allow-env --allow-run=afconvert scripts/bench/live_bench.ts \
//     --clips <folder> [--providers soniox,deepgram] [--language ru] [--languages ru,en] [--keywords Okafor,Murmur] \
//     [--repeat 3] [--per-minute 8] [--label wifi] [--region eu-central-1] [--bench <LIVE_BENCH_KEY>] \
//     [--url wss://<project>.supabase.co/functions/v1/live] [--key <publishable key>] [--token <user JWT>] [--out <file.json>]
//
// --clips      recordings named `<group>-<name>.wav` (or .m4a, .aiff, .caf, .mp3, which afconvert
//              turns into what the app sends: PCM16, mono, 16 kHz). The group, ru, en or mix, is
//              how the results are split. A `<group>-<name>.txt` beside a clip is its reference
//              text. say_clips.ts makes a spoken test set with the Mac's voices.
// --providers  the services to play every clip through, in turn. It needs the bench key, which
//              lets a socket choose its service; without --providers the relay's own is used.
// --language   the language each dictation asks for. Without it the service detects the language
//              among --languages (ru,en unless given), as the app's Auto does.
// --per-minute at most that many dictations begun in any minute (8): an anonymous caller is
//              allowed 10.
// The URL, the publishable key and the user's token come as live_spike.ts takes them; the bench
// key also comes from the LIVE_BENCH_KEY variable. The results, with every text that came back,
// go to scripts/out/ (never committed), and a summary is printed. live_standin.ts serves the relay
// on localhost with a scripted service, to try this with no key.
import { flagValue, localConfig, sleep, userToken } from "./live_spike.ts";
import { describeDiff, differenceRate, totalDifference, wordDiff, type WordDifference, wordDifference } from "./metrics.ts";
import { percentile } from "./models.ts";

/** The app's frame: 100 ms of 16 kHz mono PCM16. */
const FRAME_MS = 100;
const BYTES_PER_MS = 32;
/** How long a dictation may take to end after its last frame: the relay's own limit is 2.5 s. */
const END_TIMEOUT_MS = 15_000;
/** When the app starts its upload beside a `finalize` still unanswered (the relay's `ready.policy`). */
const HEDGE_AFTER_MS = 1000;
/** The recordings --clips takes. */
const AUDIO_FILE = /\.(wav|m4a|aiff?|caf|mp3)$/i;

/** Each service's list price for a minute of streamed audio, in dollars (read in November 2026). */
const PRICE_PER_MINUTE: Record<string, number> = {
  soniox: 0.002,
  elevenlabs: 0.0037,
  assemblyai: 0.0075,
  deepgram: 0.0092,
  openai: 0.017,
};

/** Deno takes request headers for a WebSocket, which the web's constructor can't. */
type HeaderSocket = new (url: string, options: { headers: Record<string, string> }) => WebSocket;

/** One recording, as the samples the app would send for it. */
export interface Clip {
  /** The file's name without its extension: `ru-say-03`. */
  name: string;
  /** What the name starts with, before its first "-": ru, en, mix. The results are split by it. */
  group: string;
  /** PCM16, mono, 16 kHz. */
  pcm: Uint8Array;
  audioMs: number;
  /** The text of `<name>.txt` beside the clip; null without one. */
  reference: string | null;
}

/** The samples of a WAV file that already is what the app sends (PCM16, mono, 16 kHz); null for any other. */
export function pcmOfWav(bytes: Uint8Array): Uint8Array | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (at: number) => String.fromCharCode(...bytes.subarray(at, at + 4));
  if (bytes.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;
  let plain = false;
  for (let at = 12; at + 8 <= bytes.byteLength;) {
    const size = view.getUint32(at + 4, true);
    const body = at + 8;
    if (tag(at) === "fmt " && size >= 16 && body + 16 <= bytes.byteLength) {
      // Format 0xFFFE keeps the real one in the extension after these 16 bytes, at the start of its
      // sub-format id: afconvert writes PCM that way when it converts from AAC.
      const code = view.getUint16(body, true);
      const format = code === 0xfffe && size >= 40 && body + 26 <= bytes.byteLength ? view.getUint16(body + 24, true) : code;
      // Format 1 (PCM), one channel, 16000 samples a second, 16 bits each.
      plain = format === 1 && view.getUint16(body + 2, true) === 1 &&
        view.getUint32(body + 4, true) === 16000 && view.getUint16(body + 14, true) === 16;
    } else if (tag(at) === "data") {
      if (!plain) return null;
      // A writer that didn't know the length yet leaves a size past the file's end: the data runs to it.
      const end = Math.min(bytes.byteLength, body + size);
      return bytes.subarray(body, end - ((end - body) % 2));
    }
    // Chunks are padded to an even length.
    at = body + size + (size % 2);
  }
  return null;
}

/** A clip's samples: read as they are from a WAV file the app could have sent, else through afconvert. */
async function samples(path: string): Promise<Uint8Array> {
  if (/\.wav$/i.test(path)) {
    const pcm = pcmOfWav(await Deno.readFile(path));
    if (pcm) return pcm;
  }
  const converted = await Deno.makeTempFile({ suffix: ".wav" });
  try {
    const { success, stderr } = await new Deno.Command("afconvert", {
      args: ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, converted],
      stdout: "null",
      stderr: "piped",
    }).output();
    if (!success) throw new Error(`afconvert could not read ${path}: ${new TextDecoder().decode(stderr).trim()}`);
    const pcm = pcmOfWav(await Deno.readFile(converted));
    if (!pcm) throw new Error(`afconvert wrote no 16 kHz PCM16 for ${path}`);
    return pcm;
  } finally {
    await Deno.remove(converted).catch(() => {});
  }
}

/** The group a clip's name puts it in: `ru-say-03` is in "ru"; a name without one is in "other". */
export function groupOf(name: string): string {
  return name.match(/^([a-z]{2,3})-/i)?.[1].toLowerCase() ?? "other";
}

/** Every recording in `folder`, by name, with the reference text beside it. */
export async function loadClips(folder: string): Promise<Clip[]> {
  const files: string[] = [];
  for await (const entry of Deno.readDir(folder)) if (entry.isFile && AUDIO_FILE.test(entry.name)) files.push(entry.name);
  const clips: Clip[] = [];
  for (const file of files.sort()) {
    const name = file.replace(AUDIO_FILE, "");
    const pcm = await samples(`${folder}/${file}`);
    let reference: string | null = null;
    try {
      reference = (await Deno.readTextFile(`${folder}/${name}.txt`)).trim() || null;
    } catch {
      // No reference text for this clip.
    }
    clips.push({ name, group: groupOf(name), pcm, audioMs: Math.round(pcm.byteLength / BYTES_PER_MS), reference });
  }
  return clips;
}

/** A clip cut into the frames the app sends: 100 ms each, the last one what is left. */
export function framesOf(pcm: Uint8Array): Uint8Array[] {
  const frames: Uint8Array[] = [];
  const size = FRAME_MS * BYTES_PER_MS;
  for (let at = 0; at < pcm.byteLength; at += size) frames.push(pcm.subarray(at, Math.min(pcm.byteLength, at + size)));
  return frames;
}

export interface SessionOptions {
  /** The relay: wss://<project>/functions/v1/live. */
  url: string;
  /** What every upgrade carries: the user's token, the publishable key, the bench key, the region. */
  headers: Record<string, string>;
  /** The service to ask for with `?provider=` (a bench socket's right); null for the relay's own. */
  provider: string | null;
  /** The language asked for; null to have it detected among `languages`. */
  language: string | null;
  languages: string[];
  keywords: string[];
  /** How many times faster than it was spoken the audio is played: 1, except in tests. */
  pace?: number;
  /** Opens the socket (a WebSocket with those request headers). */
  connect?: (url: string, headers: Record<string, string>) => WebSocket;
}

/** How one dictation went. Times are whole ms. */
export interface SessionResult {
  clip: string;
  group: string;
  /** The service asked for; null for the relay's own. */
  asked: string | null;
  /** The service `ready` named. */
  provider: string | null;
  /**
   * "final"; "error:<code>" when the relay said why not; "refused:<status>" when it gave no socket
   * (the app would upload); "closed" for a socket that ended without a word; "timeout".
   */
  outcome: string;
  retryable: boolean | null;
  closeCode: number | null;
  /** What the socket itself reported, when anything. */
  socketError: string | null;
  audioMs: number;
  /** From the tap on the mic: the socket open, `ready`, the first words shown, the first settled. */
  openMs: number | null;
  readyMs: number | null;
  firstWordsMs: number | null;
  firstSettledMs: number | null;
  /** From the tap on done to the final text: the wait this is all about. */
  doneToFinalMs: number | null;
  partials: number;
  /** The longest silence between two of the relay's messages while the audio was going out. */
  longestQuietMs: number | null;
  /** Frames spoken before the socket was open, which went out in one burst after. */
  backlogFrames: number;
  budgetSeconds: number | null;
  /** The relay's own account of the session (`final.timings`). */
  relay: Record<string, unknown> | null;
  text: string | null;
  languages: string[];
  /** The words the relay counted toward the plan. */
  words: number | null;
  /** Whether the final text begins with what the partials had settled: settled text is never revised. */
  settledHeld: boolean | null;
  reference: string | null;
  difference: WordDifference | null;
  /** The words that differ from the reference: "fox→box −the +very". */
  differs: string | null;
}

function openSocket(url: string, headers: Record<string, string>): WebSocket {
  return new (WebSocket as unknown as HeaderSocket)(url, { headers });
}

/** One clip as one dictation through the relay, from the tap on the mic to the socket's close. */
export async function dictate(clip: Clip, options: SessionOptions): Promise<SessionResult> {
  const pace = options.pace ?? 1;
  const dictationId = crypto.randomUUID();
  const url = new URL(options.url);
  if (options.provider) url.searchParams.set("provider", options.provider);
  const frames = framesOf(clip.pcm);

  let openedAt: number | null = null;
  let readyAt: number | null = null;
  let firstWordsAt: number | null = null;
  let firstSettledAt: number | null = null;
  /** The tap on done: the last frame has been spoken. */
  let doneAt: number | null = null;
  let finalAt: number | null = null;
  let lastMessageAt: number | null = null;
  let longestQuietMs: number | null = null;
  let partials = 0;
  /** What the partials settled, in order. */
  let settled = "";
  let ready: Record<string, unknown> | null = null;
  let final: Record<string, unknown> | null = null;
  let error: Record<string, unknown> | null = null;
  let socketError: string | null = null;
  let closeCode: number | null = null;
  /** Frames spoken so far, and how many of them the socket has been given. */
  let spoken = 0;
  let sent = 0;
  let backlogFrames = 0;
  let finalizeSent = false;
  let over = false;
  let timedOut = false;
  const ended = Promise.withResolvers<void>();
  const end = () => {
    over = true;
    ended.resolve();
  };

  // The tap on the mic: the app opens the socket and starts recording at once.
  const tappedAt = performance.now();
  const socket = (options.connect ?? openSocket)(url.href, { ...options.headers, "x-murmur-dictation": dictationId });
  socket.binaryType = "arraybuffer";

  /** Hands the socket what has been spoken and not sent yet and, after the last frame, the `finalize`. */
  const flush = () => {
    if (socket.readyState !== WebSocket.OPEN) return;
    while (sent < spoken) socket.send(frames[sent++]);
    if (doneAt !== null && !finalizeSent) {
      finalizeSent = true;
      socket.send(JSON.stringify({ type: "finalize", audioMs: clip.audioMs }));
    }
  };

  socket.onopen = () => {
    openedAt = performance.now();
    backlogFrames = spoken;
    socket.send(JSON.stringify({
      type: "start",
      v: 1,
      dictationId,
      language: options.language,
      languages: options.languages,
      keywords: options.keywords,
      audio: { format: "pcm_s16le", rate: 16000, channels: 1 },
      client: "live-bench",
    }));
    flush();
  };
  socket.onmessage = (event) => {
    if (typeof event.data !== "string") return;
    const at = performance.now();
    let message: Record<string, unknown>;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }
    if (doneAt === null && lastMessageAt !== null) longestQuietMs = Math.max(longestQuietMs ?? 0, at - lastMessageAt);
    lastMessageAt = at;
    if (message.type === "ready") {
      ready = message;
      readyAt = at;
    } else if (message.type === "partial") {
      partials++;
      if (message.stable || message.volatile) firstWordsAt ??= at;
      if (typeof message.stable === "string" && message.stable) {
        firstSettledAt ??= at;
        settled += message.stable;
      }
    } else if (message.type === "final") {
      final = message;
      finalAt = at;
    } else if (message.type === "error") {
      error = message;
    } else if (typeof message.type === "string" && message.type.startsWith("spike.")) {
      // The function deployed there is still the relay spike: it only echoes.
      socketError = "the function answered as the relay spike, not the relay";
      end();
    }
  };
  socket.onerror = (event) => {
    socketError ??= (event as ErrorEvent).message || "socket error";
    // A refused upgrade has no close to wait for.
    if (openedAt === null) end();
  };
  socket.onclose = (event) => {
    closeCode = event.code;
    end();
  };

  for (let index = 0; index < frames.length && !over; index++) {
    // An absolute clock: a late frame doesn't push the ones after it.
    await sleep(tappedAt + Math.min((index + 1) * FRAME_MS, clip.audioMs) / pace - performance.now());
    spoken = index + 1;
    flush();
  }
  if (!over) {
    doneAt = performance.now();
    flush();
  }
  const timer = setTimeout(() => {
    timedOut = true;
    end();
  }, END_TIMEOUT_MS);
  await ended.promise;
  clearTimeout(timer);
  if (socket.readyState <= WebSocket.OPEN) socket.close(1000);

  const since = (at: number | null) => at === null ? null : Math.round(at - tappedAt);
  // What `message` narrowing loses across the handlers above.
  const said = { ready, final, error } as Record<"ready" | "final" | "error", Record<string, unknown> | null>;
  const refused = openedAt === null && socketError !== null ? (socketError as string).match(/\b([345]\d\d)\b/)?.[1] ?? "no socket" : null;
  const text = typeof said.final?.text === "string" ? said.final.text : null;
  const steps = text !== null && clip.reference ? wordDiff(clip.reference, text) : null;
  return {
    clip: clip.name,
    group: clip.group,
    asked: options.provider,
    provider: typeof said.ready?.provider === "string" ? said.ready.provider : null,
    outcome: said.final
      ? "final"
      : said.error
      ? `error:${said.error.code}`
      : refused
      ? `refused:${refused}`
      : timedOut
      ? "timeout"
      : "closed",
    retryable: typeof said.error?.retryable === "boolean" ? said.error.retryable : null,
    closeCode,
    socketError,
    audioMs: clip.audioMs,
    openMs: since(openedAt),
    readyMs: since(readyAt),
    firstWordsMs: since(firstWordsAt),
    firstSettledMs: since(firstSettledAt),
    doneToFinalMs: finalAt !== null && doneAt !== null ? Math.round(finalAt - doneAt) : null,
    partials,
    longestQuietMs: longestQuietMs === null ? null : Math.round(longestQuietMs),
    backlogFrames,
    budgetSeconds: typeof said.ready?.budgetSeconds === "number" ? said.ready.budgetSeconds : null,
    relay: typeof said.final?.timings === "object" ? said.final.timings as Record<string, unknown> | null : null,
    text,
    languages: Array.isArray(said.final?.languages) ? said.final.languages as string[] : [],
    words: typeof said.final?.words === "number" ? said.final.words : null,
    // The relay trims the whole text and closes up doubled spaces, so the same is done to its start.
    settledHeld: text === null ? null : text.startsWith(settled.trim().replace(/ {2,}/g, " ")),
    reference: clip.reference,
    difference: text !== null && clip.reference ? wordDifference(clip.reference, text) : null,
    differs: steps ? describeDiff(steps) : null,
  };
}

/**
 * Holds a dictation's start back until fewer than `perMinute` began in the minute before it: the
 * relay refuses a caller's dictations beyond its minute's count.
 */
export function startGate(perMinute: number, now: () => number = Date.now, wait: (ms: number) => Promise<void> = sleep): () => Promise<void> {
  const starts: number[] = [];
  return async () => {
    for (;;) {
      while (starts.length > 0 && starts[0] <= now() - 60_000) starts.shift();
      if (starts.length < perMinute) break;
      await wait(starts[0] + 60_000 - now() + 50);
    }
    starts.push(now());
  };
}

// MARK: Summary

export interface Spread {
  n: number;
  p50: number | null;
  p95: number | null;
  max: number | null;
}

function spread(values: (number | null)[]): Spread {
  const measured = values.filter((value): value is number => value !== null);
  return { n: measured.length, p50: percentile(measured, 50), p95: percentile(measured, 95), max: measured.length ? Math.max(...measured) : null };
}

/** One service's dictations, all of them or one group's. */
export interface SummaryRow {
  provider: string;
  /** "all", or a clip group. */
  group: string;
  sessions: number;
  /** Dictations that ended in a final text. */
  finals: number;
  doneToFinalMs: Spread;
  /** The part of that wait the relay measured, from the app's `finalize` to the service's last words: the rest is the network. */
  atRelayMs: Spread;
  readyMs: Spread;
  firstWordsMs: Spread;
  /** Finals that took longer than the hedge: the app would have started its upload beside them. */
  overHedge: number;
  /** Finals whose text didn't begin with what the partials had settled. */
  settledBroken: number;
  /** Against the reference texts, over the clips that have one. */
  difference: WordDifference;
  differenceRate: number | null;
  audioMinutes: number;
  /** At the service's list price; null for one this file has no price for. */
  cost: number | null;
}

function summaryRow(provider: string, group: string, results: SessionResult[]): SummaryRow {
  const finals = results.filter((result) => result.outcome === "final");
  const difference = totalDifference(finals.flatMap((result) => result.difference ?? []));
  const audioMinutes = results.reduce((sum, result) => sum + result.audioMs, 0) / 60_000;
  return {
    provider,
    group,
    sessions: results.length,
    finals: finals.length,
    doneToFinalMs: spread(finals.map((result) => result.doneToFinalMs)),
    atRelayMs: spread(finals.map((result) => typeof result.relay?.finalizeMs === "number" ? result.relay.finalizeMs : null)),
    readyMs: spread(results.map((result) => result.readyMs)),
    firstWordsMs: spread(results.map((result) => result.firstWordsMs)),
    overHedge: finals.filter((result) => (result.doneToFinalMs ?? 0) > HEDGE_AFTER_MS).length,
    settledBroken: finals.filter((result) => result.settledHeld === false).length,
    difference,
    differenceRate: differenceRate(difference),
    audioMinutes,
    cost: Object.hasOwn(PRICE_PER_MINUTE, provider) ? audioMinutes * PRICE_PER_MINUTE[provider] : null,
  };
}

/** Each service's results as a row for all its clips and, with more than one group, a row a group. */
export function summarize(results: SessionResult[]): SummaryRow[] {
  const byProvider = Map.groupBy(results, (result) => result.provider ?? result.asked ?? "the relay's own");
  const rows: SummaryRow[] = [];
  for (const [provider, list] of byProvider) {
    rows.push(summaryRow(provider, "all", list));
    const groups = Map.groupBy(list, (result) => result.group);
    if (groups.size > 1) for (const [group, part] of [...groups].sort(([a], [b]) => a.localeCompare(b))) rows.push(summaryRow(provider, group, part));
  }
  return rows;
}

export interface Check {
  name: string;
  measured: string;
  needs: string;
  /** Null when there was nothing to measure. */
  passes: boolean | null;
}

const whole = (value: number | null) => value === null ? "–" : `${Math.round(value)} ms`;
const within = (value: number | null, limit: number) => value === null ? null : value <= limit;

/** The speed plan's numbers for one service's run: the relay's gate, and what qualifies it for the bake-off. */
export function checks(row: SummaryRow): Check[] {
  const share = row.sessions ? row.finals / row.sessions : null;
  return [
    {
      name: "Dictations that end in text",
      measured: share === null ? "–" : `${Math.round(share * 1000) / 10}% (${row.finals} of ${row.sessions})`,
      needs: "98% or more",
      passes: share === null ? null : share >= 0.98,
    },
    { name: "Done → text, median", measured: whole(row.doneToFinalMs.p50), needs: "400 ms or less", passes: within(row.doneToFinalMs.p50, 400) },
    { name: "Done → text, 95th percentile", measured: whole(row.doneToFinalMs.p95), needs: "800 ms or less", passes: within(row.doneToFinalMs.p95, 800) },
    {
      name: "The same, to qualify in the bake-off",
      measured: whole(row.doneToFinalMs.p95),
      needs: "500 ms or less",
      passes: within(row.doneToFinalMs.p95, 500),
    },
    { name: "Tap → ready, 95th percentile", measured: whole(row.readyMs.p95), needs: "1200 ms or less", passes: within(row.readyMs.p95, 1200) },
    { name: "Tap → first words, 95th percentile", measured: whole(row.firstWordsMs.p95), needs: "1500 ms or less", passes: within(row.firstWordsMs.p95, 1500) },
    {
      name: "Settled words never revised",
      measured: row.finals ? `${row.finals - row.settledBroken} of ${row.finals}` : "–",
      needs: "all",
      passes: row.finals ? row.settledBroken === 0 : null,
    },
  ];
}

function table(headers: string[], rows: string[][]): string {
  const widths = headers.map((header, column) => Math.max(header.length, ...rows.map((row) => row[column].length)));
  // The first two columns are names; the rest are numbers, set to the right.
  const line = (cells: string[]) => cells.map((cell, column) => column < 2 ? cell.padEnd(widths[column]) : cell.padStart(widths[column])).join("  ").trimEnd();
  return [line(headers), widths.map((width) => "-".repeat(width)).join("  "), ...rows.map(line)].join("\n");
}

/** The run as text: a row a service and group, then each service against the plan's numbers. */
export function report(results: SessionResult[]): string {
  const rows = summarize(results);
  const number = (value: number | null) => value === null ? "–" : String(Math.round(value));
  const out = [table(
    ["Service", "Clips", "n", "text", "done→text p50", "p95", "max", "at relay p50", "ready p95", "first words p95", "over 1 s", "words off", "minutes", "cost"],
    rows.map((row) => [
      row.provider,
      row.group,
      String(row.sessions),
      row.sessions ? `${Math.round((row.finals / row.sessions) * 100)}%` : "–",
      number(row.doneToFinalMs.p50),
      number(row.doneToFinalMs.p95),
      number(row.doneToFinalMs.max),
      number(row.atRelayMs.p50),
      number(row.readyMs.p95),
      number(row.firstWordsMs.p95),
      String(row.overHedge),
      row.differenceRate === null ? "–" : `${Math.round(row.differenceRate * 1000) / 10}%`,
      row.audioMinutes.toFixed(1),
      row.cost === null ? "–" : `$${row.cost.toFixed(3)}`,
    ]),
  )];
  out.push(
    "",
    "Times are ms. at relay: the part of done→text from the relay's receipt of `finalize` to the service's last words; the rest is the network.",
    "words off: the share of the reference texts' words a service changed, missed or added.",
  );
  for (const row of rows.filter((row) => row.group === "all")) {
    out.push("", `-- ${row.provider} against the plan's numbers --`, table(
      ["Check", "", "measured", "needs"],
      checks(row).map((check) => [check.name, check.passes === null ? "" : check.passes ? "ok" : "NO", check.measured, check.needs]),
    ));
  }
  const failed = results.filter((result) => result.outcome !== "final");
  if (failed.length > 0) {
    const counts = Map.groupBy(failed, (result) => result.outcome);
    out.push("", `Without a final text: ${[...counts].map(([outcome, list]) => `${outcome} ${list.length}`).join(", ")}`);
  }
  return out.join("\n");
}

// MARK: Run

/** A result as a line for the terminal while the run goes on. */
function progress(result: SessionResult): string {
  const text = result.text === null ? "" : `  "${result.text.length > 70 ? `${result.text.slice(0, 70)}…` : result.text}"`;
  return `${result.clip}  ${result.provider ?? result.asked ?? "relay"}  ${result.outcome}` +
    (result.doneToFinalMs === null ? "" : `  done→text ${result.doneToFinalMs} ms`) +
    (result.firstWordsMs === null ? "" : `  first words ${result.firstWordsMs} ms`) + text +
    (result.differs ? `\n    differs: ${result.differs}` : "") +
    (result.socketError && result.outcome !== "final" ? `\n    ${result.socketError}` : "");
}

/** The user's token, renewed before its hour is up: a long run outlives one. */
function tokenSource(host: string, key: string, given: string | undefined): () => Promise<string> {
  if (given) return () => Promise.resolve(given);
  let token = "";
  let issuedAt = 0;
  return async () => {
    if (!token || Date.now() - issuedAt > 30 * 60_000) {
      token = await userToken(host, key);
      issuedAt = Date.now();
    }
    return token;
  };
}

const list = (value: string | undefined) => (value ?? "").split(",").map((item) => item.trim()).filter(Boolean);

if (import.meta.main) {
  const config = await localConfig();
  const host = (config.SUPABASE_HOST ?? "").replace(/^https?:\/\//, "").replace(/\/$/, "");
  const url = flagValue("--url") ?? (host ? `wss://${host}/functions/v1/live` : "");
  const key = flagValue("--key") ?? config.SUPABASE_ANON_KEY ?? "";
  const bench = flagValue("--bench") ?? Deno.env.get("LIVE_BENCH_KEY") ?? "";
  const folder = flagValue("--clips");
  if (!url || !folder) throw new Error("--clips <folder> is required, and --url unless Config/Local.xcconfig names the project");
  const providers = list(flagValue("--providers"));
  if (providers.length > 0 && !bench) throw new Error("--providers needs the bench key (--bench, or LIVE_BENCH_KEY): only a bench socket may choose its service");
  const language = flagValue("--language") ?? null;
  const languages = language ? [] : list(flagValue("--languages") ?? "ru,en");
  const keywords = list(flagValue("--keywords"));
  const repeat = Math.max(1, Number(flagValue("--repeat")) || 1);
  const region = flagValue("--region") ?? null;
  const label = flagValue("--label") ?? "unnamed";

  const clips = await loadClips(folder);
  if (clips.length === 0) throw new Error(`no recordings in ${folder}`);
  const minutes = clips.reduce((sum, clip) => sum + clip.audioMs, 0) / 60_000;
  console.error(`${clips.length} clips, ${minutes.toFixed(1)} minutes of audio; ${repeat} time(s) through ${providers.join(", ") || "the relay's own service"}`);

  const urlHost = new URL(url).host;
  const token = tokenSource(urlHost, key, flagValue("--token"));
  const gate = startGate(Math.max(1, Number(flagValue("--per-minute")) || 8));
  const results: (SessionResult & { round: number })[] = [];
  for (let round = 1; round <= repeat; round++) {
    for (const clip of clips) {
      // Each clip goes through every service before the next clip: what the network does in that minute, it does to all.
      for (const provider of providers.length > 0 ? providers : [null]) {
        await gate();
        const headers: Record<string, string> = { Authorization: `Bearer ${await token()}`, "x-client-info": "live-bench" };
        if (key) headers.apikey = key;
        if (bench) headers["x-murmur-bench"] = bench;
        if (region) headers["x-region"] = region;
        const result = await dictate(clip, { url, headers, provider, language, languages, keywords });
        results.push({ round, ...result });
        console.error(progress(result));
      }
    }
  }

  const at = new Date().toISOString();
  const out = flagValue("--out") ?? `scripts/out/live_bench-${label}-${at.replaceAll(":", "").slice(0, 15)}.json`;
  await Deno.mkdir("scripts/out", { recursive: true });
  await Deno.writeTextFile(out, JSON.stringify({
    label, at, url: `${urlHost}${new URL(url).pathname}`, region, language, languages, keywords: keywords.length, repeat,
    summary: summarize(results), results,
  }, null, 2));
  console.log(report(results));
  console.error(`Saved to ${out}`);
}
