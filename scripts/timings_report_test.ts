import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  cleanupTrip,
  coldLaunch,
  type DictationTimings,
  liveActivityWait,
  networkMs,
  parseLog,
  pauseBefore,
  report,
  type RequestTiming,
  resultToInsert,
  routeOf,
  type ServerTiming,
  startThresholds,
  stat,
  thresholds,
  transcription,
  unexplained,
  warmupReachedWorker,
} from "./timings_report.ts";

const T0 = Date.UTC(2026, 10, 12, 9, 0, 0);

function request(name: string, totalMs: number, server: ServerTiming = {}, more: Partial<RequestTiming> = {}): RequestTiming {
  return { function: name, status: 200, totalMs, reused: true, waitMs: totalMs - 50, uploadMs: 40, server, ...more };
}

/** A Word for word dictation as today's build logs it: one `transcribe` request. */
function plain(index: number, more: Partial<DictationTimings> = {}): DictationTimings {
  const server: ServerTiming = {
    region: "eu-central-1", cold: false, executionId: "worker-a", authMs: 1, preflightMs: 180, transcribeMs: 800, totalMs: 1000,
  };
  return {
    requestId: `00000000-0000-0000-0000-${String(index).padStart(12, "0")}`,
    createdAt: T0 + index * 60_000,
    kind: "dictation",
    audioSeconds: 8,
    stopRequestedAt: T0 + index * 60_000 - 1300,
    tapToStopMs: 10,
    encodeMs: 15,
    audioBytes: 50_000,
    tokenMs: 1,
    stopToResultMs: 1300,
    requests: [request("transcribe", 1250, server)],
    status: "raw",
    insertable: true,
    cloudTranscript: true,
    ...more,
  };
}

Deno.test("the log's lines are read oldest first, and a line that isn't an entry is counted", () => {
  const lines = [JSON.stringify(plain(2)), "not json", "", JSON.stringify({ requests: "none" }), JSON.stringify(plain(1))];
  const { entries, skipped } = parseLog(lines.join("\n"));
  assertEquals(entries.map((entry) => entry.createdAt), [plain(1).createdAt, plain(2).createdAt]);
  assertEquals(skipped, 2);
});

Deno.test("a dictation's route comes from its style, or from its first request before styles were logged", () => {
  assertEquals(routeOf(plain(1)), "wordForWord");
  assertEquals(routeOf(plain(1, { requests: [request("dictate", 3000, { modelMs: 1800 })] })), "rewritten");
  assertEquals(routeOf(plain(1, { kind: "translation", requests: [request("dictate", 3000)] })), "translation");
  // Once Word for word goes through `dictate` too, the style tells them apart.
  assertEquals(routeOf(plain(1, { style: "verbatim", requests: [request("dictate", 1200)] })), "wordForWord");
  assertEquals(routeOf(plain(1, { style: "grammar", requests: [request("transcribe", 1200), request("cleanup", 2000)] })), "rewritten");
  // Every style but Word for word is written by the model, and must stay out of its numbers.
  for (const style of ["professional", "chat", "concise"]) {
    assertEquals(routeOf(plain(1, { style, requests: [request("dictate", 3000, { modelMs: 1800 })] })), "rewritten");
  }
});

Deno.test("a dictation without a cloud transcript, or without a request, has no route", () => {
  assertEquals(routeOf(plain(1, { cloudTranscript: false })), null);
  assertEquals(routeOf(plain(1, { requests: [] })), null);
  // From before `cloudTranscript` was logged: a cloud one, as the Debug screen counts it.
  assertEquals(routeOf(plain(1, { cloudTranscript: undefined })), "wordForWord");
});

Deno.test("the transcription request and the cleanup trip are told apart", () => {
  const entry = plain(1, { requests: [request("transcribe", 1200), request("cleanup", 3800)] });
  assertEquals(transcription(entry)?.function, "transcribe");
  assertEquals(cleanupTrip(entry)?.totalMs, 3800);
  assertEquals(cleanupTrip(plain(1)), undefined);
});

Deno.test("stat takes the nearest-rank median and 95th percentile of what was measured", () => {
  const values = [...Array.from({ length: 20 }, (_, index) => (index + 1) * 10), null, undefined, Number.NaN];
  assertEquals(stat(values), { n: 20, p50: 100, p95: 190 });
  assertEquals(stat([null, undefined]), { n: 0, p50: null, p95: null });
});

Deno.test("only an automatic insert counts as result → insert", () => {
  const entry = plain(1);
  assertEquals(resultToInsert({ ...entry, claimedAt: entry.createdAt + 42 }), 42);
  assertEquals(resultToInsert(entry), null);
  // "Insert last dictation", tapped later.
  assertEquals(resultToInsert({ ...entry, claimedAt: entry.createdAt + 30_000 }), null);
  // The keyboard's X while it waited claims before the result.
  assertEquals(resultToInsert({ ...entry, claimedAt: entry.createdAt - 500 }), null);
  assertEquals(resultToInsert({ ...entry, insertable: false, claimedAt: entry.createdAt + 42 }), null);
});

Deno.test("the network leg is the wait less the function's own time", () => {
  assertEquals(networkMs(plain(1)), 200);
  assertEquals(networkMs(plain(1, { requests: [request("transcribe", 1250, {})] })), null);
});

Deno.test("what no phase covers is stop → result less the encode and the requests", () => {
  assertEquals(unexplained(plain(1)), 1300 - 15 - 1250);
  assertEquals(unexplained(plain(1, { stopToResultMs: undefined })), null);
});

Deno.test("the pause before a dictation leaves out its own audio", () => {
  const previous = plain(1);
  const entry = plain(2);
  // Stopped 58.7 s after the last result, having spoken for 8 s.
  assertEquals(Math.round(pauseBefore(entry, previous)! * 10) / 10, 50.7);
  assertEquals(pauseBefore(entry, undefined), null);
});

Deno.test("a warm-up counts only when it reached the worker that served the dictation", () => {
  const warm = (executionId: string) => request("dictate", 900, { executionId });
  assertEquals(warmupReachedWorker(plain(1, { warmup: warm("worker-a") })), true);
  assertEquals(warmupReachedWorker(plain(1, { warmup: warm("worker-b") })), false);
  assertEquals(warmupReachedWorker(plain(1)), null);
});

function fired(entries: DictationTimings[]): string[] {
  return thresholds(entries).filter((item) => item.fires).map((item) => item.name);
}

Deno.test("no threshold fires on warm, quick dictations in the database's region", () => {
  const entries = Array.from({ length: 40 }, (_, index) => plain(index, { claimedAt: T0 + index * 60_000 + 30 }));
  assertEquals(fired(entries), []);
});

Deno.test("each threshold fires on the numbers the plan names", () => {
  const base = Array.from({ length: 40 }, (_, index) => plain(index));
  assertEquals(fired(base.map((entry) => ({ ...entry, encodeMs: 90 }))), ["Encode while recording"]);
  // 4 of 40 paid the second request.
  const paying = base.map((entry, index) =>
    index < 4 ? { ...entry, requests: [...entry.requests, request("cleanup", 3800)], stopToResultMs: 5100 } : entry
  );
  assertEquals(fired(paying), ["Cue words (the second request)"]);
  const cold = base.map((entry, index) =>
    index < 5 ? { ...entry, requests: [request("transcribe", 1250, { ...entry.requests[0].server, cold: true })] } : entry
  );
  assertEquals(fired(cold), ["Cold workers at stop"]);
  // A quarter ran in Paris, where the reply took 100 ms longer to come back.
  const away = base.map((entry, index) =>
    index % 4 === 0
      ? {
        ...entry,
        stopToResultMs: 1400,
        requests: [request("transcribe", 1350, { ...entry.requests[0].server, region: "eu-west-3" })],
      }
      : entry
  );
  assertEquals(fired(away), ["Pin the function's region"]);
  assertEquals(fired(base.map((entry) => ({ ...entry, claimedAt: entry.createdAt + 200 }))), ["Keyboard's result poll"]);
  assertEquals(fired(base.map((entry) => ({ ...entry, tapToStopMs: 120 }))), ["Main-thread stalls at stop"]);
  assertEquals(fired(base.map((entry) => ({ ...entry, stopToResultMs: 1700 }))), ["Something isn't measured"]);
});

Deno.test("the report counts each route and survives an empty log", () => {
  assertStringIncludes(report([]), "Timings log: 0 dictations");
  const entries = [
    plain(0),
    plain(1, { requests: [request("dictate", 3200, { transcribeMs: 800, modelMs: 2000, totalMs: 3000 })] }),
    plain(2, { kind: "translation", requests: [request("dictate", 3200, { transcribeMs: 800, modelMs: 2000, totalMs: 3000 })] }),
    plain(3, { cloudTranscript: false }),
    plain(4, { style: "concise", requests: [request("dictate", 3200, { transcribeMs: 800, modelMs: 2000, totalMs: 3000 })] }),
    plain(5, { style: "concise", requests: [request("dictate", 3200, { transcribeMs: 800, modelMs: 2000, totalMs: 3000 })] }),
    plain(6, { style: "chat", requests: [request("dictate", 3200, { transcribeMs: 800, modelMs: 2000, totalMs: 3000 })] }),
  ];
  const text = report(entries, 1);
  assertStringIncludes(text, "Word for word 1, rewritten styles 4, translations 1.");
  assertStringIncludes(text, "== Rewritten styles (4) ==\nBy style: concise 2, chat 1\n");
  assertStringIncludes(text, "Left out (on-device, too short, or failed): 1.");
  assertStringIncludes(text, "1 lines skipped");
  assert(!text.includes("NaN") && !text.includes("undefined"), text);
});

/** A dictation the keyboard opened the app for, every step timed from the tap. */
function jump(index: number, more: NonNullable<DictationTimings["jump"]> = {}, total = 2600): DictationTimings {
  return plain(index, {
    startPath: "jump",
    tapToStartMs: 2300,
    tapToListeningMs: total,
    jump: { linkMs: 900, appAgeMs: 180_000, audioSessionMs: 1300, engineMs: 1500, readyMs: 1800, liveActivityMs: 2250, returnMs: 2400, ...more },
  });
}

Deno.test("a jump is a cold launch when its link started the app, and it waits for the Live Activity", () => {
  assertEquals(coldLaunch(jump(1)), false);
  assertEquals(coldLaunch(jump(1, { appAgeMs: 420 })), true);
  assertEquals(coldLaunch(plain(1, { startPath: "jump" })), null);
  assertEquals(liveActivityWait(jump(1)), 450);
  assertEquals(liveActivityWait(jump(1, { liveActivityMs: undefined })), null);
});

Deno.test("the start's thresholds fire on the numbers the plan names", () => {
  const fired = (entries: DictationTimings[]) => startThresholds(entries).filter((item) => item.fires).map((item) => item.name);
  const hot = (listening: number) => plain(1, { startPath: "hot", tapToStartMs: 20, tapToListeningMs: listening });
  assertEquals(fired([hot(40), hot(60), hot(65)]), []);
  assertEquals(fired([hot(90), hot(120), hot(65)]), ["Show Listening at once"]);
  // A Live Activity that answers quickly, a warm app, the app opened at once: nothing to do.
  const quick = jump(1, { liveActivityMs: 1850 });
  assertEquals(fired([quick, quick, quick, quick]), []);
  assertEquals(fired([jump(1), jump(2)]), ["Record before the Live Activity"]);
  assertEquals(fired([quick, quick, quick, jump(4, { liveActivityMs: 1850, appAgeMs: 100 })]), ["Trim the cold launch"]);
  assertEquals(fired([quick, jump(2, { liveActivityMs: 1850, waitedMs: 500 })]), ["Catch a dead app before the tap"]);
  // Nothing timed: nothing fires, and nothing reads as a number.
  assertEquals(fired([plain(1)]), []);
});

Deno.test("the report adds the start only for a log that timed it", () => {
  assert(!report([plain(0)]).includes("== The start"));
  const text = report([
    plain(0, { startPath: "hot", tapToStartMs: 18, tapToListeningMs: 52 }),
    plain(1, { startPath: "hot", tapToStartMs: 22, tapToListeningMs: 61 }),
    plain(2, { startPath: "queued", tapToStartMs: 900, tapToListeningMs: 940 }),
    jump(3, { waitedMs: 500 }),
    // An in-app dictation: no start to time.
    plain(4),
  ]);
  assertStringIncludes(text, "== The start (4 dictations the keyboard asked for) ==");
  assertStringIncludes(text, "Session on");
  assertStringIncludes(text, "Waited for the dictation before");
  assertStringIncludes(text, "-- Opening the app, each step from the tap (1) --");
  assertStringIncludes(text, "Keyboard listening again");
  assertStringIncludes(text, "Record before the Live Activity");
  assert(!text.includes("NaN") && !text.includes("undefined"), text);
});
