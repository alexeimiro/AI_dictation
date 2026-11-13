// deno test scripts/bench/network_test_test.ts
import { assert, assertEquals, assertMatch, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import {
  connectionLabel,
  eveningOf,
  expectedMs,
  handshakeFailure,
  hardTimeoutMs,
  isTunnel,
  judgeCell,
  judgeEvening,
  mergeHosts,
  parseHostFlag,
  parseHosts,
  planFor,
  positionalArgument,
  renderEvening,
  type RunRecord,
  runList,
  streamProblem,
} from "./network_test.ts";

// MARK: Fixtures shaped like live_spike.ts's report

const handshakeOk = { run: "handshake", headers: { ok: true, openMs: 40, readyMs: 60, error: null, closeCode: null } };
const echoOk = (p50 = 50, p95 = 70) => ({ run: "echo:200", ok: true, answered: 200, asked: 200, roundTripMs: { n: 200, p50, p95, max: p95 + 10 } });
const downloadOk = { run: "download:256", ok: true, askedKB: 256, receivedKB: 258 };
const streamOk = { run: "stream:60", ok: true, ended: "final", framesSent: 600, framesAcked: 600, longestGapMs: 180, seconds: 60.4 };
const stalled = (gapMs: number) => ({ ...streamOk, longestGapMs: gapMs });

let clock = Date.parse("2026-11-13T18:00:00Z");

function record(network: string, connection: string, results: unknown[] | null, extra: Partial<RunRecord> = {}): RunRecord {
  clock += 1000;
  return {
    kind: "network_test",
    v: 1,
    connection,
    network,
    url: `wss://${network}.example/functions/v1/live`,
    region: null,
    via: "en0",
    at: new Date(clock).toISOString(),
    durationMs: 330_000,
    plan: planFor({}),
    exit: { code: 0, timedOut: false },
    stderrTail: [],
    report: results === null ? null : { label: `${network}-${connection}`, at: "", url: "", results: results as never },
    ...extra,
  };
}

const good = (p50 = 50, p95 = 70) => [handshakeOk, echoOk(p50, p95), downloadOk, streamOk, streamOk, streamOk, streamOk, streamOk];

// MARK: Hosts

Deno.test("hosts file: names, URLs, an optional region, comments", () => {
  const hosts = parseHosts("# the evening's hosts\ngoogle wss://34-88-1-2.sslip.io/functions/v1/live\n\nfly  wss://murmur-edge-ab12.fly.dev/functions/v1/live  # Stockholm\naws wss://x.example/functions/v1/live eu-north-1\n");
  assertEquals(hosts.map((host) => host.name), ["google", "fly", "aws"]);
  assertEquals(hosts[1].url, "wss://murmur-edge-ab12.fly.dev/functions/v1/live");
  assertEquals(hosts[2].region, "eu-north-1");
  assertEquals(hosts[0].region, null);
});

Deno.test("hosts file: a bad line is refused with its number", () => {
  assertThrows(() => parseHosts("google\n"), Error, "line 1");
  assertThrows(() => parseHosts("google https://x.example/functions/v1/live"), Error, "ws://");
  assertThrows(() => parseHosts("Google wss://x.example/functions/v1/live"), Error, "network name");
});

Deno.test("--host name=url[@region], and later hosts replace earlier ones by name", () => {
  assertEquals(parseHostFlag("aws=wss://a.example/functions/v1/live@eu-north-1"), { name: "aws", url: "wss://a.example/functions/v1/live", region: "eu-north-1" });
  assertThrows(() => parseHostFlag("wss://a.example/x"), Error);
  const merged = mergeHosts(
    [{ name: "supabase", url: "wss://s.example/f/live", region: "eu-central-1" }, { name: "google", url: "wss://old.example/f/live", region: null }],
    [{ name: "google", url: "wss://new.example/f/live", region: null }],
  );
  assertEquals(merged.map((host) => [host.name, host.url]), [["supabase", "wss://s.example/f/live"], ["google", "wss://new.example/f/live"]]);
});

// MARK: The plan

Deno.test("the evening's plan: 200 pings, 256 KB, five 60 s streams, one --run entry per stream", () => {
  const plan = planFor({});
  assertEquals(runList(plan), "handshake,echo:200,download:256,stream:60,stream:60,stream:60,stream:60,stream:60");
  const minutes = expectedMs(plan) / 60_000;
  assert(minutes > 5 && minutes < 7, `about six minutes, not ${minutes}`);
  assertEquals(runList(planFor({ quick: true })), "handshake,echo:20,download:64,stream:10");
  assertEquals(planFor({ streams: 10 }).streams, 10);
  // A host that froze finishes on live_spike's own timeouts long before it is stopped as hung.
  const frozenWorstMs = 20_000 + 10_000 + 15_000 + plan.streams * 70_200;
  assert(hardTimeoutMs(plan) > frozenWorstMs + 120_000);
});

Deno.test("the connection: a label, given first or with --connection", () => {
  assertEquals(connectionLabel(" Home WiFi "), "home-wifi");
  assertEquals(connectionLabel("MTS"), "mts");
  assertEquals(connectionLabel("../etc"), null);
  assertEquals(connectionLabel(""), null);
  assertEquals(positionalArgument(["beeline", "--quick"]), "beeline");
  assertEquals(positionalArgument(["--quick", "beeline"]), "beeline");
  assertEquals(positionalArgument(["--streams", "3", "--only", "google"]), undefined);
});

Deno.test("an evening runs past midnight; a tunnel is spotted by its interface", () => {
  assertEquals(eveningOf(new Date(2026, 10, 13, 23, 50)), "2026-11-13");
  assertEquals(eveningOf(new Date(2026, 10, 14, 1, 30)), "2026-11-13");
  assertEquals(eveningOf(new Date(2026, 10, 14, 7, 0)), "2026-11-14");
  assert(isTunnel("utun4"));
  assert(isTunnel("ipsec0"));
  assert(!isTunnel("en0"));
  assert(!isTunnel(null));
});

// MARK: One cell

Deno.test("a clean run passes, with its round trip", () => {
  const cell = judgeCell([record("google", "home-wifi", good(48, 71))]);
  assert(cell.pass);
  assertEquals([cell.rttP50, cell.rttP95, cell.streamsClean, cell.streamsTotal], [48, 71, 5, 5]);
  assertEquals(cell.reason, null);
});

Deno.test("why a host was never reached", () => {
  const failure = (error: string | null, openMs: number | null = null) =>
    handshakeFailure({ ok: false, openMs, readyMs: null, error, closeCode: 1006 }).short;
  assertEquals(failure("NetworkError: failed to connect to WebSocket: dns error: failed to lookup address information: nodename nor servname provided, or not known"), "DNS: name didn't resolve");
  assertEquals(failure("NetworkError: failed to connect to WebSocket: Connection refused (os error 61)"), "connection refused");
  assertEquals(failure("NetworkError: failed to connect to WebSocket: HTTP error: 401 Unauthorized"), "bench key refused (401)");
  assertEquals(failure("NetworkError: failed to connect to WebSocket: HTTP error: 503 Service Unavailable"), "test off on this host (503)");
  assertEquals(failure(null), "never connected");
  assertEquals(failure(null, 35), "froze before the test");
});

Deno.test("a host never reached fails once, not once per step", () => {
  const unreached = { run: "handshake", headers: { ok: false, openMs: null, readyMs: null, error: null, closeCode: null } };
  const never = { run: "stream:60", ok: false, ended: "no ready", seconds: 0 };
  const cell = judgeCell([record("fly", "beeline", [unreached, { run: "echo:200", ok: false }, { run: "download:256", ok: false }, never, never])]);
  assert(!cell.pass);
  assertEquals(cell.reason, "never connected");
  assertEquals(cell.reasons.length, 1);
  assertEquals(cell.streamsTotal, 2);
});

Deno.test("frozen after a few packets: pings stop, the download is cut near 16 KB", () => {
  const cell = judgeCell([record("hetzner", "mts", [
    handshakeOk,
    { run: "echo:200", ok: false, answered: 12, asked: 200, roundTripMs: { n: 12, p50: 60, p95: 80, max: 90 } },
    { run: "download:256", ok: false, askedKB: 256, receivedKB: 16 },
    { ...streamOk, ok: false, ended: "no final in 10 s", framesAcked: 41 },
  ])]);
  assertEquals(cell.reason, "froze after 12/200 pings");
  assertStringIncludes(cell.reasons.join("\n"), "16 KB cut");
  assertStringIncludes(cell.reasons.join("\n"), "1 of 1 streams failed (no final in 10 s after 60.4 s)");
});

Deno.test("streams: a stall over 2 s counts; 95% must be clean", () => {
  assertEquals(streamProblem(stalled(2400)), "stalled 2.4 s");
  assertEquals(streamProblem(stalled(1900)), null);
  assertEquals(streamProblem({ ...streamOk, framesAcked: 598 }), "2 of 600 frames unanswered");
  assertEquals(streamProblem({ ...streamOk, ok: false, ended: "budget", seconds: 41 }), "budget after 41 s");

  const one = judgeCell([record("supabase", "home-wifi", [handshakeOk, echoOk(), downloadOk, streamOk, streamOk, stalled(2400), streamOk, streamOk])]);
  assert(!one.pass, "1 of 5 is 80%");
  assertEquals(one.reason, "1/5 streams failed");

  // Four runs of five: 19 of 20 clean is exactly 95%.
  const runs = [
    record("supabase", "home-wifi", [handshakeOk, echoOk(), downloadOk, streamOk, streamOk, stalled(2400), streamOk, streamOk]),
    record("supabase", "home-wifi", good()),
    record("supabase", "home-wifi", good()),
    record("supabase", "home-wifi", good()),
  ];
  const cell = judgeCell(runs);
  assert(cell.pass);
  assertEquals([cell.streamsClean, cell.streamsTotal, cell.runs], [19, 20, 4]);
  assertStringIncludes(cell.reasons[0], "within the 5% allowed");
});

Deno.test("a retry adds to a failure instead of replacing it", () => {
  const cell = judgeCell([
    record("fly", "tele2", [handshakeOk, echoOk(), { run: "download:256", ok: false, askedKB: 256, receivedKB: 17 }, streamOk, streamOk, streamOk, streamOk, streamOk]),
    record("fly", "tele2", good()),
  ]);
  assert(!cell.pass);
  assertEquals(cell.reason, "download cut at 17 KB");
  assertEquals(cell.runs, 2);
});

Deno.test("a test that hung or crashed fails the cell", () => {
  const hung = judgeCell([record("google", "megafon", null, { exit: { code: null, timedOut: true }, durationMs: 780_000 })]);
  assertEquals([hung.pass, hung.reason], [false, "hung, stopped"]);
  assertStringIncludes(hung.reasons[0], "13 min");
  const crashed = judgeCell([record("google", "megafon", null, { exit: { code: 1, timedOut: false }, stderrTail: ["error: Uncaught TypeError: Invalid URL"] })]);
  assertStringIncludes(crashed.reasons[0], "Invalid URL");
});

Deno.test("round trips over several runs: the median of medians, the worst 95th percentile", () => {
  const cell = judgeCell([record("google", "home-wifi", good(40, 60)), record("google", "home-wifi", good(50, 90)), record("google", "home-wifi", good(44, 70))]);
  assertEquals([cell.rttP50, cell.rttP95], [44, 90]);
});

// MARK: The evening

Deno.test("the evening: a network passes only where every connection passed; the lowest worst p95 wins", () => {
  const evening = judgeEvening([
    record("supabase", "home-wifi", good(60, 90)),
    record("google", "home-wifi", good(40, 60)),
    record("fly", "home-wifi", good(45, 65)),
    record("supabase", "beeline", good(70, 120)),
    record("google", "beeline", good(55, 95)),
    record("fly", "beeline", good(50, 140)),
    record("aws", "home-wifi", good(30, 40)),
  ]);
  assertEquals(evening.connections, ["home-wifi", "beeline"]);
  assertEquals(evening.rows.map((row) => [row.network, row.verdict]), [["supabase", "PASS"], ["google", "PASS"], ["fly", "PASS"], ["aws", "INCOMPLETE"]]);
  assertEquals(evening.winner?.network, "google");
  assertEquals(evening.spare?.network, "fly");
  const table = renderEvening(evening, "Network test");
  assertStringIncludes(table, "Use: google (worst-connection p95 95 ms). Spare: fly (140 ms).");
  assertStringIncludes(table, "Today's Supabase: PASS, worst p95 120 ms (today's path).");
  assertMatch(table, /aws\s+PASS 30\/40 ms 5\/5\s+not run\s+not run everywhere yet/);
});

Deno.test("a tie goes to the network with nothing to maintain; Supabase is never the pick", () => {
  const evening = judgeEvening([
    record("supabase", "home-wifi", good(20, 30)),
    record("google", "home-wifi", good(40, 100)),
    record("fly", "home-wifi", good(42, 104)),
  ]);
  assertEquals(evening.winner?.network, "fly");
  assertEquals(evening.spare?.network, "google");
});

Deno.test("when every network fails on one connection, the connection is suspect", () => {
  const cut = [handshakeOk, echoOk(), { run: "download:256", ok: false, askedKB: 256, receivedKB: 16 }, streamOk];
  const evening = judgeEvening([
    record("supabase", "mts", cut),
    record("google", "mts", cut),
    record("supabase", "home-wifi", good()),
    record("google", "home-wifi", good()),
  ]);
  assertEquals(evening.suspect, ["mts"]);
  assertEquals(evening.winner, null);
  const table = renderEvening(evening, "Network test");
  assertStringIncludes(table, "Every network failed on mts");
  assertStringIncludes(table, "google on mts: the download stopped at 16 of 256 KB");
  assertStringIncludes(table, "No new host passed.");
});
