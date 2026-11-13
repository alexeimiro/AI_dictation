import { assert, assertAlmostEquals, assertEquals, assertFalse, assertStringIncludes } from "jsr:@std/assert@1";
import {
  audioCost,
  type CostRow,
  parseRows,
  priceFor,
  type Prices,
  report,
  rowCost,
  summarize,
  tokenCost,
  usd,
} from "./cost_report.ts";

const PRICES: Prices = {
  checked: "2026-11-13",
  speech: [
    { provider: "openai", model: "gpt-transcribe", usdPerMinute: 0.006, effective: "2026-01-01" },
    { provider: "openai", model: "gpt-transcribe", usdPerMinute: 0.0045, effective: "2026-06-01" },
    { provider: "soniox", model: "stt-rt", usdPerMinute: 0.002, effective: "2026-01-01" },
    { provider: "own", model: "", usdPerMinute: 0, effective: "2026-01-01" },
  ],
  text: [
    { provider: "openai", model: "gpt-6.1-terra", input: 1, cachedInput: 0.1, output: 5, effective: "2026-01-01" },
    { provider: "openai", model: "gpt-6", input: 10, cachedInput: 1, output: 50, effective: "2026-01-01" },
    { provider: "anthropic", model: "claude-haiku-5-5", input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5, effective: "2026-01-01" },
  ],
  fixed: [{ name: "Supabase Pro", usdPerMonth: 25 }, { name: "Apple Developer Program", usdPerMonth: 8.25 }],
  servers: [{ name: "A GPU of your own", usdPerMonth: 240 }],
  alternatives: [
    { name: "Soniox, live", usdPerMinute: 0.002 },
    { name: "Groq, Whisper turbo", usdPerMinute: 0.0006, minimumSeconds: 10 },
  ],
  revenue: { monthlyUsd: 9.99, yearlyUsd: 79.99, storeCommission: 0.15, note: "Small Business Program." },
};

const MIA = "9f1c";
const NOA = "4b7a";
let serial = 0;

/** A row at `at` (hours after 14 Nov 2026 09:00 UTC); `fields` replace its own. */
function row(at: number, fields: Partial<CostRow>): CostRow {
  return {
    created_at: new Date(Date.UTC(2026, 10, 14, 9) + at * 3_600_000).toISOString(),
    user: MIA,
    dictation_id: `d-${++serial}`,
    kind: "speech",
    path: "upload",
    host: "supabase",
    plan: "pro",
    provider: "openai",
    model: "gpt-transcribe",
    backup: false,
    audio_ms: null,
    input_tokens: null,
    cached_tokens: null,
    cache_write_tokens: null,
    output_tokens: null,
    ...fields,
  };
}

const speech = (at: number, seconds: number | null, fields: Partial<CostRow> = {}) =>
  row(at, { audio_ms: seconds === null ? null : seconds * 1000, ...fields });
const text = (at: number, fields: Partial<CostRow> = {}) =>
  row(at, {
    kind: "text",
    model: "gpt-6.1-terra-2026-10-01",
    input_tokens: 2000,
    cached_tokens: 1500,
    cache_write_tokens: 0,
    output_tokens: 100,
    ...fields,
  });

Deno.test("a row is priced by its provider's entry with the longest matching name, in force on its day", () => {
  const terra = priceFor(PRICES.text, { provider: "openai", model: "gpt-6.1-terra-2026-10-01", created_at: "2026-11-14T09:00:00Z" });
  assertEquals(terra?.input, 1, "the dated model name starts with the entry's");
  const astra = priceFor(PRICES.text, { provider: "openai", model: "gpt-6-astra", created_at: "2026-11-14T09:00:00Z" });
  assertEquals(astra?.input, 10, "a shorter name still matches");
  assertEquals(priceFor(PRICES.text, { provider: "anthropic", model: "gpt-6.1-terra", created_at: "2026-11-14T09:00:00Z" }), null);
  assertEquals(priceFor(PRICES.text, { provider: "openai", model: "o9", created_at: "2026-11-14T09:00:00Z" }), null);

  const march = priceFor(PRICES.speech, { provider: "openai", model: "gpt-transcribe", created_at: "2026-03-01T00:00:00Z" });
  const june = priceFor(PRICES.speech, { provider: "openai", model: "gpt-transcribe", created_at: "2026-06-01T00:00:00Z" });
  assertEquals([march?.usdPerMinute, june?.usdPerMinute], [0.006, 0.0045], "a price holds until a later one starts");
  assertEquals(priceFor(PRICES.speech, { provider: "openai", model: "gpt-transcribe", created_at: "2025-12-31T23:59:59Z" }), null);
  // An entry with an empty name prices every model of its provider.
  assertEquals(priceFor(PRICES.speech, { provider: "own", model: "qwen3-asr-1.7b", created_at: "2026-11-14T09:00:00Z" })?.usdPerMinute, 0);
});

Deno.test("audio is billed by the minute, and by a service's minimum per clip", () => {
  assertAlmostEquals(audioCost(60, { usdPerMinute: 0.0045 }), 0.0045);
  assertAlmostEquals(audioCost(7.8, { usdPerMinute: 0.0045 }), 0.000585);
  assertAlmostEquals(audioCost(4, { usdPerMinute: 0.0006, minimumSeconds: 10 }), 0.0001, 1e-12, "a 4 s clip billed as 10 s");
  assertAlmostEquals(audioCost(25, { usdPerMinute: 0.0006, minimumSeconds: 10 }), 0.00025);
});

Deno.test("tokens are billed fresh, cached, written to the cache and out, each at its own price", () => {
  // 2000 in, of which 1500 cached: 500 fresh at $1, 1500 at $0.10, 100 out at $5, per million.
  assertAlmostEquals(tokenCost(text(0), PRICES.text[0]), (500 * 1 + 1500 * 0.1 + 100 * 5) / 1e6);
  const claude = text(0, { provider: "anthropic", model: "claude-haiku-5-5", input_tokens: 2000, cached_tokens: 1200, cache_write_tokens: 300 });
  assertAlmostEquals(tokenCost(claude, PRICES.text[2]), (500 * 0.1 + 1200 * 0.01 + 300 * 0.125 + 100 * 0.5) / 1e6);
  // Without a price for cache writes they are input.
  assertAlmostEquals(tokenCost(text(0, { cached_tokens: 0, cache_write_tokens: 400 }), PRICES.text[0]), (1600 + 400 + 500) / 1e6);
  assertEquals(tokenCost(text(0, { input_tokens: null, cached_tokens: null, output_tokens: null }), PRICES.text[0]), 0);
});

Deno.test("a row that can't be priced is null, never zero", () => {
  assertAlmostEquals(rowCost(speech(0, 60), PRICES)!, 0.0045);
  assertEquals(rowCost(speech(0, null), PRICES), null, "audio of unknown length");
  assertEquals(rowCost(speech(0, 60, { provider: "deepgram", model: "nova-3" }), PRICES), null, "no price for the service");
  assertEquals(rowCost(text(0, { model: "o9-mini" }), PRICES), null, "no price for the model");
  assertEquals(rowCost(speech(0, 60, { provider: "own", model: "parakeet-v3" }), PRICES), 0, "your own model costs nothing a minute");
});

Deno.test("the export is read as an array, as the SQL editor's one cell, or a row a line", () => {
  const rows = [speech(0, 5), text(1)];
  assertEquals(parseRows(JSON.stringify(rows)), { rows, skipped: 0 });
  assertEquals(parseRows(JSON.stringify([{ cost_rows: rows }])), { rows, skipped: 0 });
  assertEquals(parseRows(rows.map((item) => JSON.stringify(item)).join("\n") + "\n"), { rows, skipped: 0 });
  const mixed = parseRows(`${JSON.stringify(rows[0])}\nnot json\n{"kind":"speech"}\n`);
  assertEquals([mixed.rows.length, mixed.skipped], [1, 2], "what isn't a row is counted, not costed");
  assertEquals(parseRows("[]"), { rows: [], skipped: 0 });
});

/** Two days: Mia on pro dictates 3 times (one rewritten, one with the backup), Noa on basic once. */
function sample(): CostRow[] {
  serial = 0;
  const rewritten = speech(1, 30);
  return [
    speech(0, 60),
    rewritten,
    text(1, { dictation_id: rewritten.dictation_id }),
    speech(24, 30, { backup: true, host: "edge-fi", path: "live", provider: "soniox", model: "stt-rt-v6" }),
    speech(48, 6, { user: NOA, plan: "basic" }),
    // No length in the file, an account since deleted, and a service the price file doesn't know.
    speech(30, null),
    speech(31, 60, { user: null, plan: null, dictation_id: null }),
    speech(32, 60, { provider: "deepgram", model: "nova-3" }),
  ];
}

Deno.test("the summary adds up the period, by service, dictation, person and plan", () => {
  const s = summarize(sample(), PRICES);
  assertEquals(s.days, 2);
  assertAlmostEquals(s.perMonth, 30.4375 / 2);
  // 60 + 30 + 6 + 60 s of gpt-transcribe at $0.0045, and 30 s of Soniox at $0.002.
  assertAlmostEquals(s.speechUsd, (156 / 60) * 0.0045 + 0.5 * 0.002);
  assertAlmostEquals(s.textUsd, 0.00115);
  assertEquals([s.transcriptions, s.textCalls, s.unknownAudio, s.backups], [7, 1, 1, 1]);
  // Every transcription of known length, priced or not.
  assertAlmostEquals(s.audioMinutes, (60 + 30 + 30 + 6 + 60 + 60) / 60);
  assertEquals(s.unpriced, [{ label: "speech deepgram nova-3", rows: 1 }]);

  assertEquals(s.dictations, 6, "the call that named no dictation isn't one");
  assertEquals(s.rewritten, 1);
  const together = 0.5 * 0.0045 + 0.00115;
  assert(s.perDictation.some((cost) => Math.abs(cost - together) < 1e-12), "a dictation is its calls together");
  assertAlmostEquals(Math.max(...s.perDictation), 0.0045, 1e-12, "the minute-long one costs the most");

  assertEquals(s.people.map((person) => [person.user, person.plan, person.dictations]), [[MIA, "pro", 5], [NOA, "basic", 1]]);
  const [pro, basic] = s.byPlan;
  assertEquals([pro.plan, pro.people, basic.plan, basic.people], ["pro", 1, "basic", 1]);
  assertAlmostEquals(pro.usdAMonth, (1.5 * 0.0045 + 0.5 * 0.002 + 0.00115) * (30.4375 / 2));
  assertAlmostEquals(basic.audioMinutesAMonth, 0.1 * (30.4375 / 2));
  assertEquals([pro.rewritten, basic.rewritten], [1 / 5, 0]);

  const [first] = s.byModel;
  assertEquals([first.kind, first.provider, first.model, first.calls, first.usdPerMinute], ["speech", "openai", "gpt-transcribe", 5, 0.0045]);
  assertEquals(s.byPath.map((line) => [line.label, line.calls]), [["upload on supabase", 7], ["live on edge-fi", 1]]);

  // The same audio elsewhere: 246 s at Soniox; at Groq the 6 s clip is billed as 10.
  assertAlmostEquals(s.alternatives[0].usd, (246 / 60) * 0.002);
  assertAlmostEquals(s.alternatives[1].usd, (250 / 60) * 0.0006);
});

Deno.test("a period given from outside sets the pace, so quiet days count", () => {
  const since = Date.UTC(2026, 10, 14);
  const until = Date.UTC(2026, 10, 21);
  const s = summarize(sample(), PRICES, { since, until });
  assertEquals([s.days, s.from, s.to], [7, since, until]);
  // Rows within an hour are a day like that one, not a month of such hours.
  assertEquals(summarize([speech(0, 60), speech(0.5, 60)], PRICES).days, 1);
});

Deno.test("dollars are written with the digits their size needs", () => {
  assertEquals([usd(0), usd(1234.5), usd(236.76), usd(8.4915), usd(0.0425), usd(0.000585)], [
    "$0", "$1,235", "$237", "$8.49", "$0.043", "$0.00059",
  ]);
});

Deno.test("the report says what was paid, what wasn't costed, and when a server of your own pays off", () => {
  const out = report(sample(), PRICES, { skipped: 2 });
  assertStringIncludes(out, "Dictation costs, 2026-11-14 to 2026-11-16 (2.0 days): 6 dictations by 2 people");
  assertStringIncludes(out, "Prices as checked on 2026-11-13");
  // $0.01385 in the period, $0.2108 a month at this pace, plus $33.25 fixed.
  assertStringIncludes(out, "a month at this pace: $0.211, plus $33.25 fixed = $33.46");
  assertStringIncludes(out, "speech  openai gpt-transcribe");
  assertStringIncludes(out, "at $0.00450 a minute");
  assertStringIncludes(out, "text  openai gpt-6.1-terra-2026-10-01");
  assertStringIncludes(out, "2,000 tokens in (1,500 cached), 100 out, 1 call");
  assertStringIncludes(out, "1 transcription whose file didn't state the audio's length (not costed)");
  assertStringIncludes(out, '1 call with no price for "speech deepgram nova-3": add it to scripts/prices.json');
  assertStringIncludes(out, "2 lines of the export that aren't rows");
  assertStringIncludes(out, "The backup answered 1 of 7 transcriptions.");
  assertStringIncludes(out, "A model wrote 17% of them.");
  assertStringIncludes(out, "Against a subscription: $9.99 a month leaves $8.49 after the store's 15%.");
  assertStringIncludes(out, "A person on pro costs");
  assertStringIncludes(out, "Small Business Program.");
  assertStringIncludes(out, "upload on supabase");
  assertStringIncludes(out, "The same audio at each service, a month at this pace (62 audio minutes)");
  assertStringIncludes(out, "Groq, Whisper turbo");
  // $240 a month against $0.01270 over 4.1 priced-or-not minutes.
  assertStringIncludes(out, "A server of your own instead of");
  assertStringIncludes(out, "times this pace)");
  assertFalse(out.includes("NaN") || out.includes("undefined") || out.includes("Infinity"));
});

Deno.test("a period with nothing in it says so, and a report with one service leaves out what doesn't apply", () => {
  assertStringIncludes(report([], PRICES), "No cost rows in this period");

  serial = 0;
  const own = report([speech(0, 60, { provider: "own", model: "parakeet-v3", host: "edge-fi" })], PRICES);
  assertStringIncludes(own, "speech  own parakeet-v3");
  assertStringIncludes(own, "What you paid");
  // Nothing is paid by the minute, so there is no break-even to state, and one path needs no table.
  assertFalse(own.includes("A server of your own instead"));
  assertFalse(own.includes("By path and home"));
  assertFalse(own.includes("Not in the total"));
  assert(!own.includes("NaN"));
});
