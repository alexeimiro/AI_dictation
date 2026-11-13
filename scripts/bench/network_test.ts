// The network-test evening in one command. From the connection this Mac is on (home Wi-Fi, the
// iPhone's hotspot on one carrier), it runs the relay spike's test (live_spike.ts, unchanged)
// against every hosting network at the same moment, saves what came back, and prints one table for
// the whole evening: pass or fail per network on each connection, and which network to use.
//
//   scripts/network_test.sh <connection> [--quick] [--streams 5] [--only google,fly] [--host name=wss://…]
//
// or directly, from the repository root:
//
//   deno run --allow-net --allow-read --allow-write --allow-env --allow-run scripts/bench/network_test.ts \
//     --connection <name> [--bench <key>] [--hosts-file <file>] [--dir <folder>] [--seconds 60] [--vpn-ok] [--report]
//
// Hosts: `supabase` (today's project, named in Config/Local.xcconfig, pinned to eu-central-1 as the
// app pins dictate) and each line of scripts/out/network_test/hosts.txt, `name wss://…/functions/v1/live
// [x-region]`, which the setup scripts in server/deploy append to; --host name=url adds or replaces
// one, --only keeps the ones named. A host answers the test with LIVE_BENCH_KEY, one key for all;
// the wrapper loads it from scripts/out/live_bench.env. No token is sent: nothing is signed up or
// written anywhere, on any host.
//
// Each host gets, in this order, on one socket at a time: a handshake, 200 pings (the round trip),
// a 256 KB download in 4 KB replies (some Russian networks cut a connection after about 16 KB) and
// five 60 s streams of 100 ms audio-sized frames at real-time pace. All hosts run at once, so a
// hiccup of the connection itself shows on every host at the same second. --quick runs a short
// version (20 pings, 64 KB, one 10 s stream) into a separate folder, as a check before the real run.
//
// The rule (server/README.md): a network passes on a connection when the test started, every ping
// was answered, the 256 KB arrived, and at least 95% of the streams ended with every frame
// acknowledged and no silence over 2 s. A network passes when it passes on every connection run
// that evening. Among those, the lowest worst-connection 95th-percentile round trip wins, and the
// runner-up is the spare; today's Supabase is measured as the reference, not as a candidate.
//
// One evening is one folder, scripts/out/network_test/<date> (before 06:00 counts as the evening
// before). Every run adds its records there; running a connection again adds to what it had, so a
// retry can't hide a failure. The table is printed after every run and kept in table.txt.
import { flagValue, localConfig } from "./live_spike.ts";

// MARK: Hosts

export interface Host {
  /** The network's name in the table: supabase, google, fly, aws… */
  name: string;
  /** The live function's WebSocket URL on that host. */
  url: string;
  /** Sent as x-region (Supabase picks the function's region by it); null for none. */
  region: string | null;
}

const NAME = /^[a-z][a-z0-9-]{0,30}$/;

function checkedHost(name: string, url: string, region: string | null, where: string): Host {
  if (!NAME.test(name)) throw new Error(`${where}: "${name}" isn't a network name (lowercase letters, digits, dashes)`);
  if (!/^wss?:\/\/[^/\s]+\//.test(url)) throw new Error(`${where}: "${url}" isn't a ws:// or wss:// URL with a path`);
  return { name, url, region };
}

/** `name url [region]` lines; # starts a comment. */
export function parseHosts(text: string, source = "hosts file"): Host[] {
  const hosts: Host[] = [];
  text.split("\n").forEach((raw, index) => {
    const line = raw.replace(/#.*$/, "").trim();
    if (!line) return;
    const [name, url, region] = line.split(/\s+/);
    if (!url) throw new Error(`${source} line ${index + 1}: expected "name url [region]"`);
    hosts.push(checkedHost(name, url, region ?? null, `${source} line ${index + 1}`));
  });
  return hosts;
}

/** `--host name=url` or `--host name=url@region`. */
export function parseHostFlag(value: string): Host {
  const at = value.indexOf("=");
  if (at < 1) throw new Error(`--host ${value}: expected name=wss://…`);
  const [url, region] = value.slice(at + 1).split("@");
  return checkedHost(value.slice(0, at), url, region || null, `--host ${value}`);
}

/** Later lists replace earlier entries of the same name, keeping the first one's place. */
export function mergeHosts(...lists: Host[][]): Host[] {
  const merged = new Map<string, Host>();
  for (const host of lists.flat()) merged.set(host.name, host);
  return [...merged.values()];
}

// MARK: What each host is asked

export interface Plan {
  quick: boolean;
  pings: number;
  downloadKB: number;
  streams: number;
  seconds: number;
}

export function planFor(options: { quick?: boolean; streams?: number; seconds?: number }): Plan {
  const quick = options.quick ?? false;
  return {
    quick,
    pings: quick ? 20 : 200,
    downloadKB: quick ? 64 : 256,
    streams: Math.max(1, options.streams ?? (quick ? 1 : 5)),
    seconds: Math.max(1, options.seconds ?? (quick ? 10 : 60)),
  };
}

/** live_spike's --run: one entry per stream, so each one prints its own "Running" line. */
export function runList(plan: Plan): string {
  return ["handshake", `echo:${plan.pings}`, `download:${plan.downloadKB}`,
    ...Array.from({ length: plan.streams }, () => `stream:${plan.seconds}`)].join(",");
}

/** How long a host's test takes when every reply comes after `roundTripMs`. */
export function expectedMs(plan: Plan, roundTripMs = 80): number {
  return 2_000 + plan.pings * roundTripMs + Math.ceil(plan.downloadKB / 4) * roundTripMs +
    plan.streams * (plan.seconds * 1000 + 400);
}

/**
 * When a host's test is stopped as hung. Every wait inside live_spike has its own timeout (10 s for
 * a reply, 15 s for a download reply, 10 s for a stream's end), so a frozen host finishes on its
 * own well before this; only a host answering everything a second late reaches it.
 */
export function hardTimeoutMs(plan: Plan): number {
  return 30_000 + expectedMs(plan, 1000) + plan.streams * 12_000 + 60_000;
}

// MARK: What came back

/** The parts of live_spike.ts's report this reads. */
interface SpikeResult {
  run: string;
  ok?: boolean;
  headers?: { ok: boolean; openMs: number | null; readyMs: number | null; error: string | null; closeCode: number | null };
  answered?: number;
  asked?: number;
  roundTripMs?: { n: number; p50: number | null; p95: number | null; max: number | null };
  askedKB?: number;
  receivedKB?: number;
  ended?: string;
  framesSent?: number;
  framesAcked?: number;
  longestGapMs?: number | null;
  seconds?: number;
  error?: string | null;
  closeCode?: number | null;
}

export interface SpikeReport {
  label: string;
  at: string;
  url: string;
  results: SpikeResult[];
}

/** One host's test from one connection, as saved in the evening's folder. */
export interface RunRecord {
  kind: "network_test";
  v: 1;
  connection: string;
  network: string;
  url: string;
  region: string | null;
  /** The run it was part of (its start, local time), and the host's place in that run's list. */
  run?: string;
  order?: number;
  /** The network interface the Mac's traffic left by (en0…). */
  via: string | null;
  at: string;
  durationMs: number;
  plan: Plan;
  exit: { code: number | null; timedOut: boolean };
  /** The last lines live_spike wrote to stderr, for a test that didn't finish. */
  stderrTail: string[];
  /** live_spike's report; null when the test didn't finish. */
  report: SpikeReport | null;
}

/** A reason, in a few words for the table and in full for the lines under it. */
export interface Problem {
  short: string;
  long: string;
}

/** Whether a socket error says the host's name didn't resolve. */
function isDnsError(error: string): boolean {
  return /dns|lookup|nodename|not known|name or service|no address|resolve/i.test(error);
}

/** Why a host couldn't be reached, from the handshake's result. */
export function handshakeFailure(headers: NonNullable<SpikeResult["headers"]>): Problem {
  const error = (headers.error ?? "").replace(/\s+/g, " ").trim();
  const said = error ? ` (${error.slice(0, 120)})` : "";
  if (error && isDnsError(error)) return { short: "DNS: name didn't resolve", long: `the host's name didn't resolve${said}` };
  const status = error.match(/\b(401|403|404|429|5\d\d)\b/)?.[1];
  if (status === "401") return { short: "bench key refused (401)", long: `the host refused the bench key: a different LIVE_BENCH_KEY is set there${said}` };
  if (status === "404") return { short: "no test at this URL (404)", long: `nothing answers at this URL: check the path /functions/v1/live${said}` };
  if (status === "503") return { short: "test off on this host (503)", long: `the host has no LIVE_BENCH_KEY, or the function is off${said}` };
  if (status) return { short: `host answered ${status}`, long: `the host answered HTTP ${status}${said}` };
  if (/refused/i.test(error)) return { short: "connection refused", long: `connection refused${said}` };
  if (/reset/i.test(error)) return { short: "connection reset", long: `connection reset${said}` };
  if (/certificate|tls|ssl/i.test(error)) return { short: "TLS failed", long: `the TLS handshake failed${said}` };
  if (headers.openMs !== null) return { short: "froze before the test", long: "connected, then nothing came back: frozen right after the upgrade" };
  if (error) return { short: "never connected", long: `never connected${said}` };
  return { short: "never connected", long: "never connected: no answer in 10 s (blocked or frozen at the first packets)" };
}

/** Why one stream doesn't count as clean; null when it does. */
export function streamProblem(stream: SpikeResult): string | null {
  const gap = stream.longestGapMs ?? 0;
  if (stream.ended && stream.ended !== "final") {
    if (stream.ended === "no ready") return "never started";
    return `${stream.ended} after ${stream.seconds ?? "?"} s`;
  }
  if ((stream.framesAcked ?? 0) < (stream.framesSent ?? 0)) {
    return `${(stream.framesSent ?? 0) - (stream.framesAcked ?? 0)} of ${stream.framesSent} frames unanswered`;
  }
  if (gap > 2000) return `stalled ${(gap / 1000).toFixed(1)} s`;
  if (stream.ok === false) return "failed";
  return null;
}

/** One network on one connection, over every run of that pair this evening. */
export interface Cell {
  network: string;
  connection: string;
  runs: number;
  pass: boolean;
  /** The first reason it failed, short enough for the table; null when it passed. */
  reason: string | null;
  /** Every reason in full, for the lines under the table, including a stream failure within the 5% allowed. */
  reasons: string[];
  rttP50: number | null;
  rttP95: number | null;
  streamsClean: number;
  streamsTotal: number;
}

/** The share of streams that must be clean. */
const STREAM_SHARE = 0.95;

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : Math.round((sorted[middle - 1] + sorted[middle]) / 2);
}

function counted(problems: string[]): string {
  const counts = new Map<string, number>();
  for (const problem of problems) counts.set(problem, (counts.get(problem) ?? 0) + 1);
  return [...counts].map(([problem, count]) => count > 1 ? `${problem} (×${count})` : problem).join(", ");
}

export function judgeCell(records: RunRecord[]): Cell {
  const blocking: Problem[] = [];
  const notes: string[] = [];
  const streamProblems: string[] = [];
  const p50s: number[] = [];
  const p95s: number[] = [];
  let streamsClean = 0;
  let streamsTotal = 0;
  for (const record of records) {
    if (!record.report) {
      const minutes = Math.max(1, Math.round(record.durationMs / 60_000));
      blocking.push(record.exit.timedOut
        ? { short: "hung, stopped", long: `the test hung and was stopped after ${minutes} min` }
        : { short: "test didn't finish", long: `the test didn't finish: ${record.stderrTail.at(-1)?.slice(0, 120) ?? `exit ${record.exit.code}`}` });
      continue;
    }
    const results = record.report.results;
    const handshake = results.find((result) => result.run === "handshake");
    // When the host was never reached, what fails after it is the same failure again.
    const reached = handshake?.headers?.ok !== false;
    if (!reached) blocking.push(handshakeFailure(handshake!.headers!));
    for (const echo of results.filter((result) => result.run.startsWith("echo"))) {
      if (echo.roundTripMs?.p50 != null) p50s.push(echo.roundTripMs.p50);
      if (echo.roundTripMs?.p95 != null) p95s.push(echo.roundTripMs.p95);
      if (echo.ok === false && reached) {
        blocking.push(echo.answered
          ? { short: `froze after ${echo.answered}/${echo.asked} pings`, long: `froze after ${echo.answered} of ${echo.asked} pings` }
          : { short: "no ping answered", long: "connected, but no ping was answered" });
      }
    }
    for (const download of results.filter((result) => result.run.startsWith("download"))) {
      if (download.ok === false && reached) {
        const received = download.receivedKB ?? 0;
        const cut = received <= 24 ? ": the ~16 KB cut seen on some Russian networks" : "";
        blocking.push({
          short: `download cut at ${received} KB`,
          long: `the download stopped at ${received} of ${download.askedKB ?? "?"} KB${cut}`,
        });
      }
    }
    for (const stream of results.filter((result) => result.run.startsWith("stream"))) {
      streamsTotal++;
      const problem = streamProblem(stream);
      if (problem === null) streamsClean++;
      else if (reached) streamProblems.push(problem);
    }
  }
  const streamsOk = streamsTotal > 0 && streamsClean / streamsTotal >= STREAM_SHARE;
  const failed = streamsTotal - streamsClean;
  if (streamsTotal === 0) {
    if (blocking.length === 0) blocking.push({ short: "no stream ran", long: "no stream ran" });
  } else if (!streamsOk && streamProblems.length) {
    blocking.push({
      short: `${failed}/${streamsTotal} streams failed`,
      long: `${failed} of ${streamsTotal} streams failed (${counted(streamProblems)}); 95% must be clean`,
    });
  } else if (streamsOk && streamProblems.length) {
    notes.push(`${failed} of ${streamsTotal} streams failed, within the 5% allowed (${counted(streamProblems)})`);
  }
  const unique = (problems: Problem[]) => [...new Map(problems.map((problem) => [problem.long, problem])).values()];
  const reasons = unique(blocking);
  return {
    network: records[0]?.network ?? "",
    connection: records[0]?.connection ?? "",
    runs: records.length,
    pass: reasons.length === 0 && streamsOk,
    reason: reasons[0]?.short ?? null,
    reasons: [...reasons.map((problem) => problem.long), ...notes],
    rttP50: median(p50s),
    rttP95: p95s.length ? Math.max(...p95s) : null,
    streamsClean,
    streamsTotal,
  };
}

// MARK: The evening

export type Verdict = "PASS" | "FAIL" | "INCOMPLETE";

export interface NetworkRow {
  network: string;
  /** Today's Supabase: measured, not a candidate for the server. */
  reference: boolean;
  /** Nothing to maintain (a platform, not a server of our own): wins a tie. */
  managed: boolean;
  cells: Map<string, Cell>;
  verdict: Verdict;
  /** The highest 95th-percentile round trip over its connections. */
  worstP95: number | null;
}

export interface Evening {
  connections: string[];
  rows: NetworkRow[];
  winner: NetworkRow | null;
  spare: NetworkRow | null;
  /** Connections on which every network failed: the connection itself is suspect. */
  suspect: string[];
  runs: number;
}

const REFERENCE = new Set(["supabase"]);
const MANAGED = /^(fly|supabase|cloudrun|render|railway|koyeb)/;

/** Two round trips this close are a tie. */
function tie(a: number, b: number): boolean {
  return Math.abs(a - b) <= Math.max(5, 0.1 * Math.min(a, b));
}

export function judgeEvening(records: RunRecord[]): Evening {
  // In the order the runs were made, and in each run in the order its hosts were listed.
  const sorted = [...records].sort((a, b) =>
    (a.run ?? a.at).localeCompare(b.run ?? b.at) || (a.order ?? 0) - (b.order ?? 0) || a.at.localeCompare(b.at)
  );
  const connections = [...new Set(sorted.map((record) => record.connection))];
  const networks = [...new Set(sorted.map((record) => record.network))];
  const rows: NetworkRow[] = networks.map((network) => {
    const cells = new Map<string, Cell>();
    for (const connection of connections) {
      const pair = sorted.filter((record) => record.network === network && record.connection === connection);
      if (pair.length) cells.set(connection, judgeCell(pair));
    }
    const judged = [...cells.values()];
    const verdict: Verdict = judged.some((cell) => !cell.pass) ? "FAIL" : cells.size < connections.length ? "INCOMPLETE" : "PASS";
    const p95s = judged.map((cell) => cell.rttP95).filter((value): value is number => value !== null);
    return {
      network,
      reference: REFERENCE.has(network),
      managed: MANAGED.test(network),
      cells,
      verdict,
      worstP95: p95s.length ? Math.max(...p95s) : null,
    };
  });
  // Today's Supabase first, then the others in the order they were first measured.
  rows.sort((a, b) => Number(b.reference) - Number(a.reference));
  const ranked = rows
    .filter((row) => row.verdict === "PASS" && !row.reference)
    .sort((a, b) => {
      const pa = a.worstP95 ?? Infinity;
      const pb = b.worstP95 ?? Infinity;
      if (Number.isFinite(pa) && Number.isFinite(pb) && tie(pa, pb) && a.managed !== b.managed) return a.managed ? -1 : 1;
      return pa - pb || a.network.localeCompare(b.network);
    });
  const suspect = networks.length < 2 ? [] : connections.filter((connection) =>
    rows.every((row) => row.cells.get(connection)?.pass === false)
  );
  return { connections, rows, winner: ranked[0] ?? null, spare: ranked[1] ?? null, suspect, runs: records.length };
}

function cellText(cell: Cell | undefined): string {
  if (!cell) return "not run";
  const times = cell.runs > 1 ? ` ×${cell.runs}` : "";
  if (!cell.pass) return `FAIL ${cell.reason ?? ""}${times}`;
  const rtt = cell.rttP50 === null ? "" : ` ${cell.rttP50}/${cell.rttP95} ms`;
  return `PASS${rtt} ${cell.streamsClean}/${cell.streamsTotal}${times}`;
}

function verdictText(row: NetworkRow): string {
  const worst = row.worstP95 === null ? "" : `, worst p95 ${row.worstP95} ms`;
  const tag = row.reference ? " (today's path)" : "";
  if (row.verdict === "PASS") return `PASS${worst}${tag}`;
  if (row.verdict === "INCOMPLETE") return `not run everywhere yet${tag}`;
  return `FAIL${tag}`;
}

/** The evening as one table, the reasons under it, and what to use. */
export function renderEvening(evening: Evening, title: string): string {
  const MAX = 34;
  const clip = (text: string) => text.length > MAX ? `${text.slice(0, MAX - 1)}…` : text;
  const header = ["network", ...evening.connections, "verdict"];
  const body = evening.rows.map((row) => [
    row.network,
    ...evening.connections.map((connection) => clip(cellText(row.cells.get(connection)))),
    verdictText(row),
  ]);
  const widths = header.map((_, column) => Math.max(...[header, ...body].map((line) => line[column].length)));
  const line = (cells: string[]) => cells.map((cell, column) => cell.padEnd(widths[column])).join("   ").trimEnd();
  const out = [
    title,
    "",
    line(header),
    line(widths.map((width) => "─".repeat(width))),
    ...body.map(line),
    "",
    "PASS a/b ms n/m: round trip median / 95th percentile; clean streams of all streams. ×k: runs added together.",
  ];
  const failures = evening.rows.flatMap((row) =>
    [...row.cells.values()].filter((cell) => cell.reasons.length > 0)
      .map((cell) => `  ${row.network} on ${cell.connection}: ${cell.reasons.join("; ")}`)
  );
  if (failures.length) out.push("", "What went wrong:", ...failures);
  if (evening.suspect.length) {
    out.push("", `Every network failed on ${evening.suspect.join(", ")}: the connection itself is suspect ` +
      "(VPN on, weak signal, the Mac asleep). Run that connection again.");
  }
  out.push("");
  if (evening.winner) {
    out.push(`Use: ${evening.winner.network} (worst-connection p95 ${evening.winner.worstP95} ms).` +
      (evening.spare ? ` Spare: ${evening.spare.network} (${evening.spare.worstP95} ms).` : " No spare passed yet."));
  } else {
    const candidates = evening.rows.filter((row) => !row.reference);
    out.push(candidates.length === 0
      ? "No new host was measured yet: only today's Supabase."
      : candidates.some((row) => row.verdict === "INCOMPLETE")
      ? "No new host has passed on every connection yet."
      : "No new host passed. Keep today's Supabase and try another network (AWS, another region).");
  }
  const reference = evening.rows.find((row) => row.reference);
  if (reference) out.push(`Today's Supabase: ${verdictText(reference)}.`);
  return out.join("\n");
}

// MARK: Running it

/** The evening a moment belongs to: before 06:00 it is still the evening before. */
export function eveningOf(date: Date): string {
  const shifted = new Date(date.getTime() - 6 * 3600_000);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${shifted.getFullYear()}-${pad(shifted.getMonth() + 1)}-${pad(shifted.getDate())}`;
}

/** A VPN's or tunnel's interface: the test must measure the connection itself. */
export function isTunnel(name: string | null): boolean {
  return name !== null && /^(utun|ipsec|ppp|tun|tap|wg)/.test(name);
}

export function connectionLabel(text: string): string | null {
  const label = text.trim().toLowerCase().replace(/[\s_]+/g, "-");
  return /^[a-z0-9][a-z0-9-]{0,30}$/.test(label) ? label : null;
}

function stampOf(date: Date): string {
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

function clock(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

async function defaultInterface(): Promise<string | null> {
  try {
    const { success, stdout } = await new Deno.Command("route", { args: ["-n", "get", "default"], stdout: "piped", stderr: "null" }).output();
    if (!success) return null;
    return new TextDecoder().decode(stdout).match(/interface:\s*(\S+)/)?.[1] ?? null;
  } catch {
    return null;
  }
}

async function readRecords(dir: string): Promise<RunRecord[]> {
  const records: RunRecord[] = [];
  try {
    for await (const entry of Deno.readDir(dir)) {
      if (!entry.isFile || !entry.name.endsWith(".json")) continue;
      try {
        const record = JSON.parse(await Deno.readTextFile(`${dir}/${entry.name}`));
        if (record?.kind === "network_test") records.push(record);
      } catch {
        // Not one of ours.
      }
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  return records;
}

interface Progress {
  step: string;
  streams: number;
  done: boolean;
}

/** Runs live_spike.ts against one host; resolves with what it saved, or with why it saved nothing. */
async function testHost(
  host: Host,
  context: { connection: string; plan: Plan; key: string; rawDir: string; stamp: string; via: string | null; order: number },
  progress: Progress,
  onChange: () => void,
): Promise<RunRecord> {
  const spike = decodeURIComponent(new URL("./live_spike.ts", import.meta.url).pathname);
  const raw = `${context.rawDir}/${context.stamp}-${context.connection}-${host.name}.json`;
  const args = [
    "run", "--allow-net", "--allow-read", "--allow-write", "--allow-env", spike,
    "--url", host.url, "--no-token", "--label", `${host.name}-${context.connection}`,
    "--out", raw, "--run", runList(context.plan),
  ];
  if (host.region) args.push("--region", host.region);
  const startedAt = Date.now();
  // The key goes in the child's environment, not on its command line, where `ps` would show it.
  const child = new Deno.Command(Deno.execPath(), {
    args,
    env: { LIVE_BENCH_KEY: context.key },
    stdin: "null",
    stdout: "null",
    stderr: "piped",
  }).spawn();
  let timedOut = false;
  let saved = false;
  const hardTimer = setTimeout(() => {
    timedOut = true;
    try {
      child.kill("SIGKILL");
    } catch {
      // Already gone.
    }
  }, hardTimeoutMs(context.plan));
  let lingerTimer: ReturnType<typeof setTimeout> | undefined;
  const tail: string[] = [];
  const decoder = new TextDecoder();
  let pending = "";
  for await (const chunk of child.stderr) {
    pending += decoder.decode(chunk, { stream: true });
    const lines = pending.split("\n");
    pending = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      tail.push(line);
      if (tail.length > 8) tail.shift();
      const running = line.match(/^Running ([a-z]+)/);
      if (running) {
        progress.step = running[1];
        if (running[1] === "stream") progress.streams++;
        onChange();
      } else if (line.startsWith("Saved to")) {
        saved = true;
        // A socket that never opened can keep live_spike's process alive after it has saved.
        lingerTimer = setTimeout(() => {
          try {
            child.kill("SIGKILL");
          } catch {
            // Already gone.
          }
        }, 3000);
      }
    }
  }
  const status = await child.status;
  clearTimeout(hardTimer);
  clearTimeout(lingerTimer);
  progress.done = true;
  onChange();
  let report: SpikeReport | null = null;
  if (saved) {
    try {
      report = JSON.parse(await Deno.readTextFile(raw));
    } catch {
      report = null;
    }
  }
  return {
    kind: "network_test",
    v: 1,
    connection: context.connection,
    network: host.name,
    url: host.url,
    region: host.region,
    run: context.stamp,
    order: context.order,
    via: context.via,
    at: new Date(startedAt).toISOString(),
    durationMs: Date.now() - startedAt,
    plan: context.plan,
    exit: { code: saved ? 0 : status.code, timedOut: timedOut && !saved },
    stderrTail: tail.filter((line) => !line.startsWith("Running ")).slice(-5),
    report,
  };
}

function flagValues(name: string): string[] {
  return Deno.args.flatMap((arg, index) => arg === name && Deno.args[index + 1] !== undefined ? [Deno.args[index + 1]] : []);
}

/** The flags that take a value; the others (--quick, --report, --vpn-ok) stand alone. */
const VALUE_FLAGS = new Set(["--connection", "--streams", "--seconds", "--only", "--host", "--hosts-file", "--dir", "--bench"]);

/** The one argument that is neither a flag nor a flag's value: the connection, given without --connection. */
export function positionalArgument(args: string[]): string | undefined {
  return args.find((arg, index) => !arg.startsWith("--") && (index === 0 || !VALUE_FLAGS.has(args[index - 1])));
}

const HELP = `Usage: scripts/network_test.sh <connection> [options]
  <connection>         where this Mac is connected now: home-wifi, beeline, mts, megafon, tele2…
  --quick              a 1-minute check (20 pings, 64 KB, one 10 s stream), kept apart from the evening
  --streams N          60 s streams per host (5)
  --only a,b           only these networks
  --host name=url      add or replace a host (url@region pins x-region)
  --hosts-file <file>  the hosts list (scripts/out/network_test/hosts.txt)
  --dir <folder>       the evening's folder (scripts/out/network_test/<date>)
  --report             print the evening's table without running anything
  --vpn-ok             run even though the traffic leaves through a tunnel`;

async function main() {
  if (Deno.args.includes("--help") || Deno.args.includes("-h")) {
    console.log(HELP);
    return;
  }
  // Paths below are the repository's, wherever this was started from.
  Deno.chdir(decodeURIComponent(new URL("../..", import.meta.url).pathname));
  const quick = Deno.args.includes("--quick");
  const plan = planFor({
    quick,
    streams: Number(flagValue("--streams")) || undefined,
    seconds: Number(flagValue("--seconds")) || undefined,
  });
  const evening = flagValue("--dir") ?? `scripts/out/network_test/${eveningOf(new Date())}`;
  const dir = quick ? `${evening}/quick` : evening;

  if (Deno.args.includes("--report")) {
    const records = await readRecords(dir);
    if (!records.length) return console.log(`No runs in ${dir} yet.`);
    console.log(renderEvening(judgeEvening(records), `Network test, ${dir}: ${records.length} host runs`));
    return;
  }

  const config = await localConfig();
  const supabaseHost = (config.SUPABASE_HOST ?? "").replace(/^https?:\/\//, "").replace(/\/$/, "");
  const builtIn: Host[] = supabaseHost ? [{ name: "supabase", url: `wss://${supabaseHost}/functions/v1/live`, region: "eu-central-1" }] : [];
  const hostsFile = flagValue("--hosts-file") ?? "scripts/out/network_test/hosts.txt";
  let listed: Host[] = [];
  try {
    listed = parseHosts(await Deno.readTextFile(hostsFile), hostsFile);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  let hosts = mergeHosts(builtIn, listed, flagValues("--host").map(parseHostFlag));
  const only = flagValue("--only")?.split(",").map((name) => name.trim()).filter(Boolean);
  if (only) hosts = hosts.filter((host) => only.includes(host.name));
  if (!hosts.length) throw new Error(`No host to test: none in ${hostsFile}, none given with --host, or --only matched none.`);

  const key = flagValue("--bench") ?? Deno.env.get("LIVE_BENCH_KEY") ?? "";
  if (!key) throw new Error("LIVE_BENCH_KEY isn't set. Run this through scripts/network_test.sh, which loads scripts/out/live_bench.env.");

  let connection = connectionLabel(flagValue("--connection") ?? positionalArgument(Deno.args) ?? "");
  while (!connection) {
    const answer = prompt("Which connection is this Mac on now? (home-wifi, beeline, mts, megafon, tele2…)");
    if (answer === null) return;
    connection = connectionLabel(answer);
  }

  const via = await defaultInterface();
  if (isTunnel(via) && !Deno.args.includes("--vpn-ok")) {
    console.error(`This Mac's traffic leaves through ${via}, a VPN or tunnel. Turn it off, so the test measures the connection ` +
      "itself, and run this again (or add --vpn-ok if the tunnel is the point).");
    Deno.exit(2);
  }

  const rawDir = `${dir}/.raw`;
  await Deno.mkdir(rawDir, { recursive: true });
  const stamp = stampOf(new Date());
  const expected = expectedMs(plan);
  console.log(`Testing ${hosts.map((host) => host.name).join(", ")} from "${connection}"` +
    `${via ? ` (via ${via})` : ""}: ${plan.pings} pings, ${plan.downloadKB} KB, ${plan.streams} × ${plan.seconds} s streams ` +
    `per host, all hosts at once. About ${Math.ceil(expected / 60_000)} min. Keep the Mac awake and on this connection.`);

  const progress = new Map(hosts.map((host) => [host.name, { step: "starting", streams: 0, done: false } as Progress]));
  const startedAt = Date.now();
  const tty = Deno.stdout.isTerminal();
  let lastLine = "";
  const describe = () => {
    const parts = hosts.map((host) => {
      const state = progress.get(host.name)!;
      if (state.done) return `${host.name} done`;
      return state.step === "stream" ? `${host.name} stream ${state.streams}/${plan.streams}` : `${host.name} ${state.step}`;
    });
    return `${clock(Date.now() - startedAt)} of ~${clock(expected)} · ${parts.join(" · ")}`;
  };
  const show = () => {
    const line = describe();
    if (tty) {
      Deno.stdout.writeSync(new TextEncoder().encode(`\r\x1b[2K${line}`));
    } else if (line.replace(/^\S+ of \S+ · /, "") !== lastLine) {
      console.log(line);
    }
    lastLine = line.replace(/^\S+ of \S+ · /, "");
  };
  const ticker = tty ? setInterval(show, 1000) : undefined;
  const stop = () => {
    clearInterval(ticker);
    console.error("\nStopped. Nothing from this run was saved.");
    Deno.exit(130);
  };
  Deno.addSignalListener("SIGINT", stop);

  const records = await Promise.all(hosts.map((host, order) =>
    testHost(host, { connection: connection!, plan, key, rawDir, stamp, via, order }, progress.get(host.name)!, show)
  ));
  clearInterval(ticker);
  Deno.removeSignalListener("SIGINT", stop);
  if (tty) Deno.stdout.writeSync(new TextEncoder().encode("\r\x1b[2K"));
  for (const record of records) {
    await Deno.writeTextFile(`${dir}/${stamp}-${connection}-${record.network}.json`, JSON.stringify(record, null, 2));
  }
  console.log(`This run took ${clock(Date.now() - startedAt)}; saved in ${dir}.\n`);

  const all = await readRecords(dir);
  const table = renderEvening(judgeEvening(all),
    `Network test${quick ? " (quick check)" : ""}, ${dir}: ${new Set(all.map((r) => r.connection)).size} connection(s), ${all.length} host runs`);
  await Deno.writeTextFile(`${dir}/table.txt`, `${table}\n`);
  console.log(table);
  if (!quick) console.log(`\nNext connection: switch the Mac to it, turn any VPN off, and run scripts/network_test.sh <its name>.`);
}

if (import.meta.main) await main();
