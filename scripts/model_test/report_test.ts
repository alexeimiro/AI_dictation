import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import type { ClipEntry, Manifest } from "./clips.ts";
import {
  ballot,
  buildReport,
  qualify,
  rankByVotes,
  type ResultLine,
  scoreVotes,
  textsOf,
  type Votes,
  weighted,
} from "./report.ts";

function clip(id: string, group: ClipEntry["group"], reference: string, fields: Partial<ClipEntry> = {}): ClipEntry {
  return {
    id, file: `audio/${id}.m4a`, source: "test", createdAt: null, audioMs: 6000, phoneText: reference, phoneLanguage: null,
    style: null, group, selected: true, excluded: false, reference, checked: true, tags: [], note: "", ...fields,
  };
}

function manifest(clips: ClipEntry[]): Manifest {
  return { version: 1, createdAt: "", updatedAt: "", targets: { ru: 12, mix: 8, en: 20, short: 8, total: 40 }, clips };
}

function line(candidate: string, clipId: string, text: string | null, fields: Partial<ResultLine> = {}): ResultLine {
  return {
    clip: clipId, candidate, attempt: 1, text, language: null, ms: 300, serverMs: null, audioMs: 6000,
    error: text === null ? "server HTTP 500" : null, run: "2026-11-13T10:00:00Z", at: "2026-11-13T10:00:01Z", ...fields,
  };
}

const RU = "Привет, я задержусь на работе.";
const MIX = "Скинь мне pull request до пятницы.";
const EN = "I'm running about ten minutes late.";
const CLIPS = [clip("r1", "ru", RU), clip("m1", "mix", MIX), clip("e1", "en", EN)];

Deno.test("a re-run's answer replaces an older one; a clip never answered is null", () => {
  const texts = textsOf(new Map([["a", [
    line("a", "r1", "old text"),
    line("a", "r1", "new text", { run: "2026-11-13T11:00:00Z", at: "2026-11-13T11:00:01Z" }),
    line("a", "r1", "second try", { run: "2026-11-13T11:00:00Z", attempt: 2 }),
    line("a", "m1", null),
    line("a", "e1", "warm-up only", { attempt: 0 }),
  ]]]));
  assertEquals(texts.get("a")!.get("r1"), "new text");
  assertEquals(texts.get("a")!.get("m1"), null);
  assertEquals(texts.get("a")!.has("e1"), false);
});

Deno.test("qualifying: empty, invented, lost mix and missing punctuation each fail it", () => {
  const good = new Map([["r1", RU], ["m1", MIX], ["e1", EN]]);
  assertEquals(qualify(CLIPS, good, new Map()).qualifies, true);

  const empty = qualify(CLIPS, new Map([...good, ["e1", ""]]), new Map());
  assertEquals([empty.qualifies, empty.empty], [false, 1]);

  const made = qualify(CLIPS, new Map([...good, ["e1", `${EN} Thanks for watching, please subscribe.`]]), new Map());
  assertEquals([made.qualifies, made.invented], [false, 1]);

  // "pull request" written in Cyrillic: the mixed clip lost its English.
  const lost = qualify(CLIPS, new Map([...good, ["m1", "Скинь мне пул реквест до пятницы."]]), new Map());
  assertEquals([lost.qualifies, lost.mixedKept, lost.mixedClips], [false, 0, 1]);

  const bare = qualify(CLIPS, new Map([["r1", "привет я задержусь на работе"], ["m1", "скинь мне pull request до пятницы"], ["e1", "im running about ten minutes late"]]), new Map());
  assertEquals(bare.qualifies, false);
  assert(bare.reasons.some((reason) => reason.includes("punctuation")));

  const failed = qualify(CLIPS, new Map<string, string | null>([...good, ["e1", null]]), new Map([["e1", "server HTTP 500"]]));
  assertEquals(failed.qualifies, false);
  assert(failed.reasons[0].includes("server HTTP 500"));

  const missing = qualify(CLIPS, new Map([["r1", RU]]), new Map());
  assertEquals([missing.qualifies, missing.missing], [false, 2]);
});

Deno.test("votes weigh the Russian side 0.6 and the English 0.4", () => {
  const texts = new Map([
    ["own", new Map([["r1", RU], ["m1", MIX], ["e1", "wrong"]])],
    ["service", new Map([["r1", "wrong"], ["m1", "wrong too"], ["e1", EN]])],
  ]);
  const votes: Votes = {
    version: 1, salt: "s", votes: {
      r1: { best: [RU], unusable: [], skipped: false, at: "" },
      m1: { best: [MIX], unusable: ["wrong too"], skipped: false, at: "" },
      e1: { best: [EN], unusable: [], skipped: false, at: "" },
    },
  };
  const scores = new Map(scoreVotes(manifest(CLIPS), texts, votes).map((score) => [score.candidate, score]));
  assertEquals(scores.get("own")!.points, 60);
  assertEquals(scores.get("service")!.points, 40);
  assertEquals(scores.get("service")!.unusable, 1);
  assertEquals(weighted(null, 50), 50);
  assertEquals(weighted(null, null), null);
});

Deno.test("your own model wins a tie within 3 points, and only then", () => {
  assertEquals(rankByVotes([{ name: "soniox", own: false, points: 70 }, { name: "parakeet", own: true, points: 67 }]), ["parakeet", "soniox"]);
  assertEquals(rankByVotes([{ name: "soniox", own: false, points: 70 }, { name: "parakeet", own: true, points: 66.9 }]), ["soniox", "parakeet"]);
  assertEquals(rankByVotes([{ name: "a", own: true, points: 50 }, { name: "b", own: false, points: 52 }, { name: "c", own: true, points: 49 }]), ["a", "b", "c"]);
});

Deno.test("the ballot is blind: one option per distinct text, ids that say nothing, a stable order", async () => {
  const texts = new Map([
    ["openai", new Map([["r1", RU], ["m1", MIX], ["e1", EN]])],
    ["parakeet", new Map([["r1", RU], ["m1", "Скинь мне пул реквест до пятницы."], ["e1", EN]])],
    ["broken", new Map<string, string | null>([["r1", RU], ["m1", MIX], ["e1", null]])],
  ]);
  const votes: Votes = { version: 1, salt: "0123", votes: {} };
  const first = await ballot(manifest(CLIPS), texts, votes);
  const again = await ballot(manifest(CLIPS), texts, votes);
  assertEquals(first, again);
  const byId = new Map(first.map((item) => [item.id, item]));
  assertEquals(byId.get("r1")!.options.length, 1);
  assertEquals(byId.get("r1")!.same, true);
  assertEquals(byId.get("m1")!.options.length, 2);
  // One candidate failed: not "the same", though the others agree.
  assertEquals(byId.get("e1")!.same, false);
  const serialized = JSON.stringify(first);
  for (const name of ["openai", "parakeet", "broken"]) assert(!serialized.includes(name));
  const other = await ballot(manifest(CLIPS), texts, { ...votes, salt: "4567" });
  assertNotEquals(other.find((item) => item.id === "m1")!.options[0].id, byId.get("m1")!.options[0].id);
});

Deno.test("the report: provisional by error rate before votes, then by votes, and why some don't qualify", () => {
  const results = new Map([
    ["openai", [line("openai", "r1", RU), line("openai", "m1", MIX), line("openai", "e1", "I'm running about ten minutes late, sorry.")]],
    ["parakeet", [line("parakeet", "r1", RU, { serverMs: 80 }), line("parakeet", "m1", MIX, { serverMs: 90 }), line("parakeet", "e1", EN, { serverMs: 70 })]],
    ["gigaam", [line("gigaam", "r1", "привет я задержусь на работе"), line("gigaam", "m1", "скинь мне пул реквест до пятницы"), line("gigaam", "e1", "")]],
  ]);
  const candidates = [
    { name: "openai", kind: "openai" as const, model: "gpt-transcribe", usdPerMinute: 0.0045 },
    { name: "parakeet", kind: "openai-compatible" as const, model: "parakeet", url: "http://x", own: true },
    { name: "gigaam", kind: "openai-compatible" as const, model: "gigaam", url: "http://y", own: true },
  ];
  const before = buildReport(manifest(CLIPS), results, { version: 1, salt: "s", votes: {} }, candidates);
  assertEquals(before.rankedBy, "error rate");
  assertEquals(before.ranking, ["parakeet", "openai"]);
  assert(before.verdict.startsWith("Provisional"));
  const gigaam = before.candidates.find((item) => item.name === "gigaam")!;
  assertEquals(gigaam.qualification.qualifies, false);
  assertEquals(before.candidates.find((item) => item.name === "parakeet")!.speed.serverMedianMs, 80);
  assertEquals(before.candidates.find((item) => item.name === "openai")!.cost.usdPer1000Minutes, 4.5);

  const votes: Votes = {
    version: 1, salt: "s", votes: {
      r1: { best: [RU], unusable: [], skipped: false, at: "" },
      e1: { best: ["I'm running about ten minutes late, sorry."], unusable: [], skipped: false, at: "" },
    },
  };
  const after = buildReport(manifest(CLIPS), results, votes, candidates);
  assertEquals(after.rankedBy, "votes");
  // openai 100 (both voted clips) against parakeet 60 (only the Russian one): more than 3 points.
  assertEquals(after.ranking, ["openai", "parakeet"]);
  assert(after.verdict.includes("more than 3 points"));
});
