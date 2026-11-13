// Where a dictation's time goes, read from the app's timings log: the phone's
// `Application Support/Murmur/timings.jsonl`, one `DictationTimings` a line and never any text.
// A development build gives it up through Settings › Debug › Cloud latency › Export timings, or
// `xcrun devicectl device copy from --domain-type appDataContainer` with the app's bundle id.
//
// For Word for word dictations with a cloud transcript it prints the median and the 95th
// percentile of each phase from the keyboard's stop to the insert, how often the connection and
// the worker were cold, how often a dictation paid the second `cleanup` request, the same by
// audio length and by the pause before the dictation, and whether each threshold of the speed
// plan fires. The styles the model rewrites and translations get a short table each.
//
//   deno run --allow-read scripts/timings_report.ts <timings.jsonl> [--since 2026-11-10] [--until 2026-11-12] [--last 100]
//
// --since and --until take a date or a date and time (local), --last keeps the newest N entries.
import { percentile } from "./bench/models.ts";

/** `ServerTiming`: what the edge function measured. */
export interface ServerTiming {
  region?: string;
  cold?: boolean;
  workerAgeMs?: number;
  executionId?: string;
  authMs?: number;
  bodyMs?: number;
  preflightMs?: number;
  readyMs?: number;
  transcribeMs?: number;
  modelMs?: number;
  totalMs?: number;
}

/** `RequestTiming`: one call to an edge function, as the app saw it. */
export interface RequestTiming {
  function: string;
  status?: number;
  tokenMs?: number;
  totalMs: number;
  reused?: boolean;
  protocolName?: string;
  connectMs?: number;
  tlsMs?: number;
  uploadMs?: number;
  waitMs?: number;
  bytesSent?: number;
  region?: string;
  server?: ServerTiming;
}

/** `DictationTimings`, with its dates as the log writes them: milliseconds since 1970. */
export interface DictationTimings {
  requestId: string;
  createdAt: number;
  kind: "translation" | "dictation";
  audioSeconds: number;
  stopRequestedAt?: number;
  tapToStopMs?: number;
  encodeMs?: number;
  audioBytes?: number;
  tokenMs?: number;
  stopToResultMs?: number;
  requests: RequestTiming[];
  warmup?: RequestTiming;
  cleanupModel?: string;
  status?: string;
  insertable?: boolean;
  cloudTranscript?: boolean;
  claimedAt?: number;
  /**
   * The writing style, in logs from builds that record it: "verbatim" (Word for word), or one the
   * model writes ("grammar", "professional", "chat", "concise").
   */
  style?: string;
}

/** `rewritten`: every style the model writes, Improve my grammar among them. */
export type Route = "wordForWord" | "rewritten" | "translation";

/** A claim later than this after the result is "Insert last dictation", not the automatic insert. */
const AUTOMATIC_INSERT_LIMIT_MS = 10_000;
/** The region the database is in: a function that ran elsewhere reaches it across regions. */
const HOME_REGION = "eu-central-1";

/** The log's entries, oldest first, and how many lines weren't one. */
export function parseLog(text: string): { entries: DictationTimings[]; skipped: number } {
  const entries: DictationTimings[] = [];
  let skipped = 0;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line) as DictationTimings;
      if (typeof entry.createdAt !== "number" || !Array.isArray(entry.requests)) throw new Error("not an entry");
      entries.push(entry);
    } catch {
      skipped++;
    }
  }
  entries.sort((a, b) => a.createdAt - b.createdAt);
  return { entries, skipped };
}

/**
 * The path a dictation with a cloud transcript took; null for one the on-device transcriber
 * wrote, or that sent nothing (too short, failed before a reply). An entry from before
 * `cloudTranscript` counts as a cloud one, as the Debug screen counts it.
 */
export function routeOf(entry: DictationTimings): Route | null {
  if (entry.cloudTranscript === false || entry.requests.length === 0) return null;
  if (entry.kind === "translation") return "translation";
  // Word for word is the one style no model writes: every other one waits for the rewrite.
  if (entry.style) return entry.style === "verbatim" ? "wordForWord" : "rewritten";
  // Before the style was logged: Word for word went to `transcribe`, a rewritten style to
  // `dictate`. A rewritten dictation that fell back to `transcribe` and `cleanup` counts as Word
  // for word here.
  return entry.requests[0].function === "dictate" ? "rewritten" : "wordForWord";
}

/** The request that transcribed: `transcribe`, or `dictate`. */
export function transcription(entry: DictationTimings): RequestTiming | undefined {
  return entry.requests.find((request) => request.function === "transcribe" || request.function === "dictate");
}

/** The second request a Word for word dictation pays when `CleanupGate` asks for the model. */
export function cleanupTrip(entry: DictationTimings): RequestTiming | undefined {
  return entry.requests.find((request) => request.function === "cleanup");
}

export interface Stat {
  n: number;
  p50: number | null;
  p95: number | null;
}

/** The median and the 95th percentile of the values that were measured. */
export function stat(values: (number | null | undefined)[]): Stat {
  const measured = values.filter((value): value is number => typeof value === "number" && Number.isFinite(value));
  return { n: measured.length, p50: percentile(measured, 50), p95: percentile(measured, 95) };
}

export interface Share {
  count: number;
  total: number;
}

/** Of the entries where `value` is known, those where it is true. */
export function share<T>(items: T[], value: (item: T) => boolean | null | undefined): Share {
  const known = items.map(value).filter((flag): flag is boolean => typeof flag === "boolean");
  return { count: known.filter(Boolean).length, total: known.length };
}

function fraction(part: Share): number | null {
  return part.total > 0 ? part.count / part.total : null;
}

function difference(a: number | undefined, b: number | undefined): number | null {
  return typeof a === "number" && typeof b === "number" ? a - b : null;
}

/** Result written → the keyboard's claim, for an automatic insert; null for anything else. */
export function resultToInsert(entry: DictationTimings): number | null {
  if (entry.insertable !== true || typeof entry.claimedAt !== "number") return null;
  const ms = Math.round(entry.claimedAt - entry.createdAt);
  return ms >= 0 && ms <= AUTOMATIC_INSERT_LIMIT_MS ? ms : null;
}

/** The transcription request's wait less the function's own time: the round trip, the gateway and a cold worker's boot. */
export function networkMs(entry: DictationTimings): number | null {
  const request = transcription(entry);
  return difference(request?.waitMs, request?.server?.totalMs);
}

/** Whether the warm-up reached the worker that then served the dictation; null when either is unknown. */
export function warmupReachedWorker(entry: DictationTimings): boolean | null {
  const worker = entry.warmup?.server?.executionId;
  const reached = entry.requests.map((request) => request.server?.executionId).filter(Boolean);
  return worker && reached.length ? reached.includes(worker) : null;
}

/** What the phases the log names don't cover: stop → result less the encode and the requests. */
export function unexplained(entry: DictationTimings): number | null {
  if (typeof entry.stopToResultMs !== "number") return null;
  const requests = entry.requests.reduce((sum, request) => sum + request.totalMs, 0);
  return entry.stopToResultMs - (entry.encodeMs ?? 0) - requests;
}

/** One line of the phase table: its label and each entry's value. */
type Row = [label: string, value: (entry: DictationTimings) => number | null | undefined];

const PHASES: Row[] = [
  ["Stop → result", (e) => e.stopToResultMs],
  ["Keyboard's stop → the app", (e) => e.tapToStopMs],
  ["Encode", (e) => e.encodeMs],
  ["Token", (e) => e.tokenMs],
  ["Open the connection (cold only)", (e) => transcription(e)?.connectMs],
  ["Upload", (e) => transcription(e)?.uploadMs],
  ["Wait for the reply", (e) => transcription(e)?.waitMs],
  ["  network and gateway (wait − server)", networkMs],
  ["  server: token check", (e) => transcription(e)?.server?.authMs],
  ["  server: reading the body", (e) => transcription(e)?.server?.bodyMs],
  ["  server: limits and quota", (e) => transcription(e)?.server?.preflightMs],
  ["  server: everything before OpenAI", (e) => transcription(e)?.server?.readyMs],
  ["  server: OpenAI transcription", (e) => transcription(e)?.server?.transcribeMs],
  ["  server: model (rewrite, translation)", (e) => transcription(e)?.server?.modelMs],
  ["  server: total", (e) => transcription(e)?.server?.totalMs],
  ["Second request (cleanup), when paid", (e) => cleanupTrip(e)?.totalMs],
  ["Result → insert", resultToInsert],
  ["Keyboard's stop → insert", (e) => {
    const insert = resultToInsert(e);
    return insert === null || typeof e.stopRequestedAt !== "number" ? null : Math.round(e.claimedAt! - e.stopRequestedAt);
  }],
  ["Not covered by any phase", unexplained],
];

/** Audio length groups, in seconds: up to and including each bound. */
const LENGTHS: [label: string, upTo: number][] = [["≤ 5 s", 5], ["5–15 s", 15], ["15–45 s", 45], ["> 45 s", Infinity]];
/** Groups by the pause since the previous dictation ended, in seconds. */
const PAUSES: [label: string, upTo: number][] = [
  ["< 30 s", 30],
  ["30 s – 2 min", 120],
  ["2 – 10 min", 600],
  ["> 10 min", Infinity],
];

function groupIndex(value: number, groups: [string, number][]): number {
  const index = groups.findIndex(([, upTo]) => value <= upTo);
  return index === -1 ? groups.length - 1 : index;
}

/** Seconds from the previous entry's result to this dictation's stop less its audio: the pause before it. */
export function pauseBefore(entry: DictationTimings, previous: DictationTimings | undefined): number | null {
  if (!previous) return null;
  const stopped = entry.stopRequestedAt ?? entry.createdAt;
  return Math.max(0, (stopped - previous.createdAt) / 1000 - entry.audioSeconds);
}

export interface Threshold {
  name: string;
  fires: boolean;
  measured: string;
  then: string;
}

/** The speed plan's conditional items, each against what the Word for word dictations show. */
export function thresholds(entries: DictationTimings[]): Threshold[] {
  const encode = stat(entries.map((e) => e.encodeMs));
  const paid: Share = { count: entries.filter((e) => cleanupTrip(e)).length, total: entries.length };
  const cold = share(entries, (e) => transcription(e)?.server?.cold);
  const requests = entries.flatMap((e) => e.requests);
  const ranAt = requests.map((request) => request.server?.region).filter((region): region is string => !!region);
  const away: Share = { count: ranAt.filter((region) => region !== HOME_REGION).length, total: ranAt.length };
  // Warm workers only, so a cold start's cost isn't read as the region's.
  const warmIn = (home: boolean) =>
    entries.filter((e) => {
      const server = transcription(e)?.server;
      return !!server?.region && (server.region === HOME_REGION) === home && server.cold === false;
    });
  const slower = (value: (entry: DictationTimings) => number | null | undefined) =>
    difference(stat(warmIn(false).map(value)).p50 ?? undefined, stat(warmIn(true).map(value)).p50 ?? undefined);
  const slowerNetwork = slower(networkMs);
  const slowerLimits = slower((e) => transcription(e)?.server?.preflightMs);
  const signed = (value: number | null) => value === null ? "not comparable" : `${value >= 0 ? "+" : ""}${value} ms`;
  const insert = stat(entries.map(resultToInsert));
  const stop = stat(entries.map((e) => e.tapToStopMs));
  const total = stat(entries.map((e) => e.stopToResultMs));
  const rest = stat(entries.map(unexplained));
  const restShare = total.p50 && rest.p50 !== null ? rest.p50 / total.p50 : null;
  return [
    {
      name: "Encode while recording",
      fires: (encode.p50 ?? 0) >= 80 || (encode.p95 ?? 0) >= 250,
      measured: `encode p50 ${ms(encode.p50)}, p95 ${ms(encode.p95)}`,
      then: "p50 ≥ 80 ms or p95 ≥ 250 ms",
    },
    {
      name: "Cue words (the second request)",
      fires: (fraction(paid) ?? 0) >= 0.10,
      measured: `${percent(paid)} of dictations paid cleanup`,
      then: "10% or more",
    },
    {
      name: "Cold workers at stop",
      fires: (fraction(cold) ?? 0) > 0.10,
      measured: `${percent(cold)} of transcription requests`,
      then: "above 10% (after the warm-up covers every mode: warm when the keyboard appears)",
    },
    {
      name: "Pin the function's region",
      fires: (fraction(away) ?? 0) >= 0.20 && Math.max(slowerNetwork ?? 0, slowerLimits ?? 0) >= 40,
      measured: `${percent(away)} of requests ran outside ${HOME_REGION}; there the network leg is ${
        signed(slowerNetwork)
      } and the limits check ${signed(slowerLimits)}`,
      then: "20% or more outside, and the network leg or the limits check 40 ms slower there",
    },
    {
      name: "Keyboard's result poll",
      fires: (insert.p50 ?? 0) > 120,
      measured: `result → insert p50 ${ms(insert.p50)} (n ${insert.n})`,
      then: "p50 above 120 ms",
    },
    {
      name: "Main-thread stalls at stop",
      fires: (stop.p50 ?? 0) > 80,
      measured: `keyboard's stop → the app p50 ${ms(stop.p50)}`,
      then: "p50 above 80 ms",
    },
    {
      name: "Something isn't measured",
      fires: (restShare ?? 0) >= 0.15,
      measured: `${ms(rest.p50)} of ${ms(total.p50)} at the median${
        restShare === null ? "" : ` (${Math.round(restShare * 100)}%)`
      }`,
      then: "15% or more of stop → result",
    },
  ];
}

// MARK: Printing

function ms(value: number | null | undefined): string {
  return typeof value === "number" ? `${Math.round(value)} ms` : "—";
}

function seconds(milliseconds: number | null): string {
  return milliseconds === null ? "—" : `${Math.round(milliseconds / 1000)} s`;
}

function percent(part: Share): string {
  const value = fraction(part);
  return value === null ? "—" : `${Math.round(value * 100)}% (${part.count} of ${part.total})`;
}

function table(header: string[], rows: string[][]): string {
  const widths = header.map((title, column) => Math.max(title.length, ...rows.map((row) => row[column].length)));
  const line = (cells: string[]) =>
    cells.map((cell, column) => column === 0 ? cell.padEnd(widths[column]) : cell.padStart(widths[column])).join("  ");
  return [line(header), widths.map((width) => "-".repeat(width)).join("  "), ...rows.map(line)].join("\n");
}

function phaseTable(entries: DictationTimings[], rows: Row[] = PHASES): string {
  const lines = rows.map(([label, value]) => {
    const { n, p50, p95 } = stat(entries.map(value));
    return [label, ms(p50), ms(p95), String(n)];
  }).filter((row) => row[3] !== "0");
  return table(["Phase", "median", "p95", "n"], lines);
}

function counts(values: (string | undefined)[]): string {
  const tally = new Map<string, number>();
  for (const value of values) if (value) tally.set(value, (tally.get(value) ?? 0) + 1);
  const total = [...tally.values()].reduce((sum, count) => sum + count, 0);
  if (total === 0) return "—";
  return [...tally].sort((a, b) => b[1] - a[1])
    .map(([name, count]) => `${name} ${Math.round((count / total) * 100)}% (${count})`).join(", ");
}

function day(date: number): string {
  const local = new Date(date);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${local.getFullYear()}-${pad(local.getMonth() + 1)}-${pad(local.getDate())} ${pad(local.getHours())}:${
    pad(local.getMinutes())
  }`;
}

/** The whole report for `entries` (oldest first), as text. */
export function report(entries: DictationTimings[], skipped = 0): string {
  const out: string[] = [];
  const routes = new Map<Route, DictationTimings[]>([["wordForWord", []], ["rewritten", []], ["translation", []]]);
  const previous = new Map<DictationTimings, DictationTimings | undefined>();
  entries.forEach((entry, index) => {
    previous.set(entry, entries[index - 1]);
    const route = routeOf(entry);
    if (route) routes.get(route)!.push(entry);
  });
  const plain = routes.get("wordForWord")!;
  const others = entries.length - [...routes.values()].reduce((sum, list) => sum + list.length, 0);

  out.push(`Timings log: ${entries.length} dictations` +
    (entries.length ? `, ${day(entries[0].createdAt)} to ${day(entries[entries.length - 1].createdAt)}` : "") +
    (skipped ? `; ${skipped} lines skipped` : ""));
  out.push(`Cloud transcripts: Word for word ${plain.length}, rewritten styles ${routes.get("rewritten")!.length}, ` +
    `translations ${routes.get("translation")!.length}. Left out (on-device, too short, or failed): ${others}.`);

  out.push("", `== Word for word (${plain.length}) ==`, phaseTable(plain));

  const first = (e: DictationTimings) => transcription(e);
  const warmed = plain.filter((e) => e.warmup);
  const waits = plain.map((e) => e.stopToResultMs).filter((value): value is number => typeof value === "number");
  const within = (from: number, to: number) =>
    percent({ count: waits.filter((value) => value > from && value <= to).length, total: waits.length });
  const warmAges = plain.map((e) => first(e)?.server).filter((server) => server?.cold === false)
    .map((server) => server!.workerAgeMs).filter((age): age is number => typeof age === "number");
  out.push(
    "",
    `Stop → result: up to 1 s ${within(-1, 1000)}, 1–1.5 s ${within(1000, 1500)}, 1.5–2 s ${within(1500, 2000)}, ` +
      `2–3 s ${within(2000, 3000)}, over 3 s ${within(3000, Infinity)}`,
    "",
    `Connection opened for the request (cold): ${percent(share(plain, (e) => first(e)?.reused === undefined ? null : !first(e)!.reused))}`,
    `Worker's first request (cold):            ${percent(share(plain, (e) => first(e)?.server?.cold))}`,
    `Same worker as the dictation before:      ${
      percent(share(plain.slice(1), (e) => {
        const worker = first(e)?.server?.executionId;
        const before = first(plain[plain.indexOf(e) - 1])?.server?.executionId;
        return worker && before ? worker === before : null;
      }))
    }`,
    `Warm workers' age:                        median ${seconds(percentile(warmAges, 50))}, oldest ${
      seconds(warmAges.length ? Math.max(...warmAges) : null)
    }`,
    `Paid the second request (cleanup):        ${percent({ count: plain.filter((e) => cleanupTrip(e)).length, total: plain.length })}`,
    `Warm-up answered before the result:       ${percent({ count: warmed.length, total: plain.length })}`,
    `Warm-up reached the request's worker:     ${percent(share(warmed, warmupReachedWorker))}`,
    `Protocol:                                 ${counts(plain.map((e) => first(e)?.protocolName))}`,
    `Ran in (the function's region):           ${counts(plain.map((e) => first(e)?.server?.region))}`,
    `Entered at (the edge's region header):    ${counts(plain.map((e) => first(e)?.region))}`,
  );

  const worker = (cold: boolean) => plain.filter((e) => first(e)?.server?.cold === cold);
  const coldRows: Row[] = [PHASES[0], PHASES[6], PHASES[7], PHASES[8], PHASES[10], PHASES[12]];
  for (const cold of [true, false]) {
    const group = worker(cold);
    if (group.length) out.push("", `-- ${cold ? "Cold" : "Warm"} worker (${group.length}) --`, phaseTable(group, coldRows));
  }

  out.push("", "-- By audio length --", table(
    ["Length", "n", "stop → result", "encode p50", "encode p95", "bytes", "OpenAI"],
    LENGTHS.map(([label], index) => {
      const group = plain.filter((e) => groupIndex(e.audioSeconds, LENGTHS) === index);
      const encode = stat(group.map((e) => e.encodeMs));
      const bytes = stat(group.map((e) => e.audioBytes)).p50;
      return [
        label,
        String(group.length),
        ms(stat(group.map((e) => e.stopToResultMs)).p50),
        ms(encode.p50),
        ms(encode.p95),
        bytes === null ? "—" : `${Math.round(bytes / 1024)} KB`,
        ms(stat(group.map((e) => first(e)?.server?.transcribeMs)).p50),
      ];
    }),
  ));

  out.push("", "-- By the pause before the dictation --", table(
    ["Pause", "n", "cold connection", "cold worker", "stop → result"],
    PAUSES.map(([label], index) => {
      const group = plain.filter((e) => {
        const pause = pauseBefore(e, previous.get(e));
        return pause !== null && groupIndex(pause, PAUSES) === index;
      });
      return [
        label,
        String(group.length),
        percent(share(group, (e) => first(e)?.reused === undefined ? null : !first(e)!.reused)),
        percent(share(group, (e) => first(e)?.server?.cold)),
        ms(stat(group.map((e) => e.stopToResultMs)).p50),
      ];
    }),
  ));

  out.push("", "-- Thresholds --", table(
    ["Item", "fires", "measured", "fires when"],
    thresholds(plain).map((item) => [item.name, item.fires ? "YES" : "no", item.measured, item.then]),
  ));

  const short: Row[] = [PHASES[0], PHASES[2], PHASES[5], PHASES[6], PHASES[9], PHASES[10], PHASES[12], PHASES[13], PHASES[16]];
  for (const [route, title] of [["rewritten", "Rewritten styles"], ["translation", "Translations"]] as [Route, string][]) {
    const group = routes.get(route)!;
    if (group.length === 0) continue;
    // Which styles they were, in logs that say: before the five styles it was Improve my grammar alone.
    const styles = new Map<string, number>();
    for (const entry of group) if (entry.style) styles.set(entry.style, (styles.get(entry.style) ?? 0) + 1);
    out.push(
      "",
      `== ${title} (${group.length}) ==`,
      ...(route === "rewritten" && styles.size > 0
        ? [`By style: ${[...styles].map(([style, count]) => `${style} ${count}`).join(", ")}`]
        : []),
      phaseTable(group, short),
      `Cold connection: ${percent(share(group, (e) => first(e)?.reused === undefined ? null : !first(e)!.reused))}; ` +
        `cold worker: ${percent(share(group, (e) => first(e)?.server?.cold))}; ` +
        `warm-up answered: ${percent({ count: group.filter((e) => e.warmup).length, total: group.length })}; ` +
        `it reached the request's worker: ${percent(share(group.filter((e) => e.warmup), warmupReachedWorker))}`,
    );
  }
  return out.join("\n");
}

function parseDate(value: string | undefined, flag: string): number {
  const date = value ? new Date(value.includes("T") || value.includes(" ") ? value : `${value}T00:00:00`) : null;
  if (!date || Number.isNaN(date.getTime())) throw new Error(`${flag} needs a date such as 2026-11-12`);
  return date.getTime();
}

if (import.meta.main) {
  let path: string | undefined;
  let since = -Infinity;
  let until = Infinity;
  let last = Infinity;
  for (let index = 0; index < Deno.args.length; index++) {
    const flag = Deno.args[index];
    if (flag === "--since") since = parseDate(Deno.args[++index], flag);
    else if (flag === "--until") until = parseDate(Deno.args[++index], flag);
    else if (flag === "--last") last = Math.max(1, Number(Deno.args[++index]) || 1);
    else path = flag;
  }
  if (!path) throw new Error("usage: timings_report.ts <timings.jsonl> [--since date] [--until date] [--last N]");
  const { entries, skipped } = parseLog(await Deno.readTextFile(path));
  const chosen = entries.filter((entry) => entry.createdAt >= since && entry.createdAt < until);
  console.log(report(chosen.slice(-Math.min(last, chosen.length)), skipped));
}
