// deno test --allow-net=127.0.0.1 scripts/bench/live_bench_test.ts
// The dictations here go through the real relay and its Soniox adapter, on localhost (live_standin.ts).
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { checks, type Clip, dictate, framesOf, groupOf, pcmOfWav, report, type SessionResult, startGate, summarize } from "./live_bench.ts";
import { LOCAL_TOKEN, serveRelay, serveStandIn, type StandInOptions } from "./live_standin.ts";

/** A WAV file from its chunks: [tag, body] each, padded to an even length as the format asks. */
function wav(chunks: [string, Uint8Array][]): Uint8Array {
  const body = chunks.flatMap(([tag, bytes]) => {
    const header = new Uint8Array(8);
    header.set(new TextEncoder().encode(tag));
    new DataView(header.buffer).setUint32(4, bytes.byteLength, true);
    return [...header, ...bytes, ...(bytes.byteLength % 2 ? [0] : [])];
  });
  const file = new Uint8Array(12 + body.length);
  file.set(new TextEncoder().encode("RIFF"));
  new DataView(file.buffer).setUint32(4, 4 + body.length, true);
  file.set(new TextEncoder().encode("WAVE"), 8);
  file.set(body, 12);
  return file;
}

function format(rate = 16000, channels = 1, bits = 16, code = 1): Uint8Array {
  const bytes = new Uint8Array(16);
  const view = new DataView(bytes.buffer);
  view.setUint16(0, code, true);
  view.setUint16(2, channels, true);
  view.setUint32(4, rate, true);
  view.setUint32(8, rate * channels * (bits / 8), true);
  view.setUint16(12, channels * (bits / 8), true);
  view.setUint16(14, bits, true);
  return bytes;
}

/** The 40-byte form of `format`, which names the real format (`code`) in its extension: what afconvert writes from AAC. */
function extensible(code: number): Uint8Array {
  const bytes = new Uint8Array(40);
  bytes.set(format(16000, 1, 16, 0xfffe));
  const view = new DataView(bytes.buffer);
  view.setUint16(16, 22, true);
  view.setUint16(18, 16, true);
  view.setUint32(20, 4, true);
  // The sub-format's id starts with the format's code; the rest of it is the same for every one.
  view.setUint16(24, code, true);
  bytes.set([0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71], 26);
  return bytes;
}

/** A clip of silence that long. */
function clip(audioMs: number, more: Partial<Clip> = {}): Clip {
  return { name: "ru-test", group: "ru", pcm: new Uint8Array(audioMs * 32), audioMs, reference: null, ...more };
}

Deno.test("a WAV file's samples are found past the chunks a writer adds before them", () => {
  const data = Uint8Array.from({ length: 640 }, (_, index) => index % 251);
  // afconvert and say write a filler chunk first; an odd-sized chunk is padded.
  const file = wav([["FLLR", new Uint8Array(37)], ["fmt ", format()], ["LIST", new Uint8Array(5)], ["data", data]]);
  assertEquals(pcmOfWav(file), data);
  // A size left open by the writer: the data runs to the end of the file, in whole samples.
  const open = wav([["fmt ", format()], ["data", data.subarray(0, 321)]]);
  new DataView(open.buffer).setUint32(open.byteLength - 322 - 4, 0xffffffff, true);
  assertEquals(pcmOfWav(open)?.byteLength, 322);
  // PCM named in the format's extension, as afconvert writes it from an AAC recording.
  assertEquals(pcmOfWav(wav([["fmt ", extensible(1)], ["FLLR", new Uint8Array(12)], ["data", data]])), data);
});

Deno.test("a WAV file that isn't what the app sends is left to the converter", () => {
  const data = new Uint8Array(64);
  assertEquals(pcmOfWav(wav([["fmt ", format(44100)], ["data", data]])), null);
  assertEquals(pcmOfWav(wav([["fmt ", format(16000, 2)], ["data", data]])), null);
  assertEquals(pcmOfWav(wav([["fmt ", format(16000, 1, 32, 3)], ["data", data]])), null);
  // Floating-point samples behind the extension are no more PCM16 than without it.
  assertEquals(pcmOfWav(wav([["fmt ", extensible(3)], ["data", data]])), null);
  assertEquals(pcmOfWav(wav([["data", data]])), null);
  assertEquals(pcmOfWav(new TextEncoder().encode("not a wav file at all")), null);
});

Deno.test("a clip is cut into 100 ms frames, and its name gives its group", () => {
  assertEquals(framesOf(new Uint8Array(250 * 32)).map((frame) => frame.byteLength), [3200, 3200, 1600]);
  assertEquals(framesOf(new Uint8Array(0)), []);
  assertEquals(groupOf("ru-say-03"), "ru");
  assertEquals(groupOf("MIX-standup"), "mix");
  assertEquals(groupOf("recording 12"), "other");
});

Deno.test("starts are held back to the caller's count for a minute", async () => {
  let clock = 0;
  const waits: number[] = [];
  const gate = startGate(2, () => clock, (ms) => {
    waits.push(ms);
    clock += ms;
    return Promise.resolve();
  });
  await gate();
  clock = 10_000;
  await gate();
  assertEquals(waits, []);
  // The third must wait until the first is a minute old.
  clock = 20_000;
  await gate();
  assertEquals(waits, [40_050]);
  assertEquals(clock, 60_050);
});

/** The relay and its stand-in service on localhost, shut down after `work`. */
async function withRelay(
  options: StandInOptions & { authMs?: number },
  work: (relay: ReturnType<typeof serveRelay>, service: ReturnType<typeof serveStandIn>) => Promise<void>,
) {
  const service = serveStandIn(options);
  const relay = serveRelay(service, { benchKey: "bench-key", authMs: options.authMs });
  try {
    await work(relay, service);
  } finally {
    await relay.shutdown();
    await service.shutdown();
  }
}

const headers = { Authorization: `Bearer ${LOCAL_TOKEN}` };
const session = { headers, provider: null, language: null, languages: ["ru", "en"], keywords: ["Окафор"], pace: 20 };

Deno.test("a clip played through the relay ends in the service's text, timed from the tap on done", async () => {
  await withRelay({ finalizeMs: 120 }, async (relay, service) => {
    const result = await dictate(clip(3000, { reference: "раз два три четыре пять шесть семь восемь девять десять" }), { ...session, url: relay.url });
    assertEquals(result.outcome, "final");
    assertEquals(result.provider, "soniox");
    assertEquals(result.closeCode, 1000);
    // The text is the stand-in's settled text, as the relay trims it.
    const heard = service.sessions[0];
    assertEquals(result.text, heard.text.trim());
    assertEquals(result.languages, ["ru"]);
    assertEquals(result.words, 10);
    assertEquals(result.difference, { words: 10, changed: 0, missing: 0, added: 0 });
    assertEquals(result.differs, "");
    assertEquals(result.settledHeld, true);
    // All of the clip reached the service, and the 200 ms of silence the adapter adds before a finalize.
    assertEquals(heard.audioBytes, 3000 * 32 + 6400);
    assertEquals((heard.config as { language_hints: string[]; context: unknown }).language_hints, ["ru", "en"]);
    assertEquals((heard.config as { context: unknown }).context, { terms: ["Окафор"] });
    // The wait is at least the service's own, and what the relay measured is inside it.
    assert(result.doneToFinalMs !== null && result.doneToFinalMs >= 120 && result.doneToFinalMs < 1000, `done → text took ${result.doneToFinalMs} ms`);
    assert((result.relay?.finalizeMs as number) >= 120 && (result.relay?.finalizeMs as number) <= result.doneToFinalMs + 5);
    assert(result.partials > 0 && result.firstWordsMs !== null && result.firstSettledMs !== null && result.readyMs !== null);
    assert(result.openMs !== null && result.openMs <= result.readyMs);
    assertEquals(result.budgetSeconds, 140);
    assertEquals(relay.usage.length, 1);
    assertEquals(relay.usage[0].words, 10);
    assertEquals(relay.logs[0].outcome, "final");
  });
});

Deno.test("audio spoken before the socket opened goes out after it, and a clip that ends first is still finalized", async () => {
  // The token check holds the upgrade for 60 ms; at this pace the whole clip is spoken in under 10.
  await withRelay({ authMs: 60 }, async (relay, service) => {
    const result = await dictate(clip(900), { ...session, url: relay.url, pace: 100 });
    assertEquals(result.outcome, "final");
    assertEquals(result.backlogFrames, 9);
    assert(result.openMs !== null && result.openMs >= 60);
    assertEquals(service.sessions[0].audioBytes, 900 * 32 + 6400);
    assertEquals(result.text, service.sessions[0].text.trim());
  });
});

Deno.test("a bench socket may choose its service; an unknown one gets no socket", async () => {
  await withRelay({}, async (relay) => {
    const bench = { ...headers, "x-murmur-bench": "bench-key" };
    const chosen = await dictate(clip(600), { ...session, url: relay.url, headers: bench, provider: "soniox" });
    assertEquals([chosen.outcome, chosen.asked, chosen.provider], ["final", "soniox", "soniox"]);
    const unknown = await dictate(clip(600), { ...session, url: relay.url, headers: bench, provider: "nobody" });
    assertEquals(unknown.outcome, "refused:503");
    assertEquals(unknown.doneToFinalMs, null);
    // Without the bench key the name is ignored: the relay's own service answers.
    const ignored = await dictate(clip(600), { ...session, url: relay.url, provider: "nobody" });
    assertEquals([ignored.outcome, ignored.provider], ["final", "soniox"]);
  });
});

Deno.test("a refused token and a failing service are told apart", async () => {
  await withRelay({ failAfterFrames: 3 }, async (relay) => {
    const stranger = await dictate(clip(600), { ...session, url: relay.url, headers: { Authorization: "Bearer someone-else" } });
    assertEquals(stranger.outcome, "refused:401");
    assertEquals(stranger.text, null);
    const failed = await dictate(clip(2000), { ...session, url: relay.url });
    assertEquals(failed.outcome, "error:provider");
    assertEquals(failed.retryable, true);
    assertEquals(failed.closeCode, 1011);
    assertEquals(failed.doneToFinalMs, null);
    assertEquals(relay.usage, []);
  });
});

/** A result as `dictate` returns it, for the summary's tests. */
function result(more: Partial<SessionResult>): SessionResult {
  return {
    clip: "ru-a", group: "ru", asked: "soniox", provider: "soniox", outcome: "final", retryable: null, closeCode: 1000, socketError: null,
    audioMs: 6000, openMs: 200, readyMs: 400, firstWordsMs: 900, firstSettledMs: 1200, doneToFinalMs: 300, partials: 12, longestQuietMs: 300,
    backlogFrames: 2, budgetSeconds: 140, relay: null, text: "раз два", languages: ["ru"], words: 2, settledHeld: true,
    reference: "раз два", difference: { words: 2, changed: 0, missing: 0, added: 0 }, differs: "",
    ...more,
  };
}

Deno.test("the summary has a row a service and one a group, and counts what the plan asks about", () => {
  const results = [
    result({ relay: { finalizeMs: 250 } }),
    result({ doneToFinalMs: 1400, relay: { finalizeMs: 1350 } }),
    result({ clip: "en-a", group: "en", doneToFinalMs: 500, difference: { words: 8, changed: 1, missing: 0, added: 1 }, settledHeld: false }),
    result({ clip: "en-b", group: "en", outcome: "error:provider", doneToFinalMs: null, text: null, difference: null, settledHeld: null }),
    result({ provider: null, asked: "deepgram", outcome: "refused:503", openMs: null, readyMs: null, firstWordsMs: null, doneToFinalMs: null, text: null, difference: null }),
  ];
  const rows = summarize(results);
  assertEquals(rows.map((row) => [row.provider, row.group, row.sessions, row.finals]), [
    ["soniox", "all", 4, 3],
    ["soniox", "en", 2, 1],
    ["soniox", "ru", 2, 2],
    ["deepgram", "all", 1, 0],
  ]);
  const all = rows[0];
  assertEquals(all.doneToFinalMs, { n: 3, p50: 500, p95: 1400, max: 1400 });
  // Only the finals whose relay said how long it took.
  assertEquals(all.atRelayMs, { n: 2, p50: 250, p95: 1350, max: 1350 });
  assertEquals(all.overHedge, 1);
  assertEquals(all.settledBroken, 1);
  assertEquals(all.difference, { words: 12, changed: 1, missing: 0, added: 1 });
  assertEquals(all.differenceRate, 2 / 12);
  assertEquals(all.audioMinutes, 0.4);
  assertEquals(Math.round(all.cost! * 10000), 8);

  const verdicts = Object.fromEntries(checks(all).map((check) => [check.name, check.passes]));
  assertEquals(verdicts, {
    "Dictations that end in text": false,
    "Done → text, median": false,
    "Done → text, 95th percentile": false,
    "The same, to qualify in the bake-off": false,
    "Tap → ready, 95th percentile": true,
    "Tap → first words, 95th percentile": true,
    "Settled words never revised": false,
  });
  // Nothing measured is neither a pass nor a failure.
  assertEquals(checks(rows[3]).map((check) => check.passes), [false, null, null, null, null, null, null]);

  const text = report(results);
  assertStringIncludes(text, "-- soniox against the plan's numbers --");
  assertStringIncludes(text, "Without a final text: error:provider 1, refused:503 1");
  assert(!text.includes("NaN") && !text.includes("undefined") && !text.includes("null"), text);
});
