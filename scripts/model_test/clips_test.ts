import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  chooseTestSet,
  type ClipEntry,
  coreDataDate,
  countClips,
  DEFAULT_TARGETS,
  emptyManifest,
  guessGroup,
  mergeClips,
  scriptWords,
  uuidFromHex,
  wavOf,
  wavSamples,
} from "./clips.ts";

function clip(id: string, fields: Partial<ClipEntry> = {}): ClipEntry {
  return {
    id, file: `audio/${id}.m4a`, source: "test", createdAt: "2026-11-10T10:00:00.000Z", audioMs: 6000, phoneText: "text",
    phoneLanguage: null, style: "verbatim", group: "en", selected: false, excluded: false, reference: null, checked: false,
    tags: [], note: "", ...fields,
  };
}

Deno.test("a text's group: Russian, English, or Russian with an English word in it", () => {
  assertEquals(guessGroup("Да, хорошо, давай так и сделаем.", null), "ru");
  assertEquals(guessGroup("OK, sounds good, thanks.", null), "en");
  assertEquals(guessGroup("Скинь мне pull request до пятницы", null), "mix");
  assertEquals(guessGroup("У нас завтра stand-up в десять", null), "mix");
  // No letters at all: the language the phone reported.
  assertEquals(guessGroup("15:30", "ru"), "ru");
  assertEquals(guessGroup("15:30", null), "en");
  assertEquals(scriptWords("кто-то сказал don't"), { cyrillic: 2, latin: 1 });
});

Deno.test("the first test set follows the targets and takes short clips first", () => {
  const clips: ClipEntry[] = [];
  for (let index = 0; index < 30; index++) {
    clips.push(clip(`ru-${index}`, { group: "ru", audioMs: index < 6 ? 3000 : 8000 + index * 100, createdAt: `2026-11-10T10:${String(index).padStart(2, "0")}:00Z` }));
    clips.push(clip(`en-${index}`, { group: "en", audioMs: index < 6 ? 2500 : 12_000, createdAt: `2026-11-11T10:${String(index).padStart(2, "0")}:00Z` }));
  }
  for (let index = 0; index < 3; index++) clips.push(clip(`mix-${index}`, { group: "mix", audioMs: 7000 }));
  // Too short to use, and private: never chosen.
  clips.push(clip("tiny", { group: "ru", audioMs: 500 }));
  clips.push(clip("private", { group: "en", excluded: true }));
  const chosen = chooseTestSet(clips, DEFAULT_TARGETS);
  const of = (prefix: string) => [...chosen].filter((id) => id.startsWith(prefix)).length;
  // Only 3 mixed clips: the Russian side's other 17 are Russian.
  assertEquals(of("mix-"), 3);
  assertEquals(of("ru-"), 17);
  assertEquals(of("en-"), 20);
  assert(!chosen.has("tiny") && !chosen.has("private"));
  const shorts = clips.filter((item) => chosen.has(item.id) && item.audioMs! >= 2000 && item.audioMs! <= 5000).length;
  assert(shorts >= DEFAULT_TARGETS.short, `short clips: ${shorts}`);
});

Deno.test("adding clips again keeps what you did to them", () => {
  const manifest = emptyManifest();
  mergeClips(manifest, [clip("a", { reference: null }), clip("b")]);
  manifest.clips.find((item) => item.id === "a")!.reference = "My words.";
  manifest.clips.find((item) => item.id === "a")!.checked = true;
  manifest.clips.find((item) => item.id === "a")!.group = "mix";
  const added = mergeClips(manifest, [clip("a", { phoneText: "other", group: "en" }), clip("c")]);
  assertEquals(added, ["c"]);
  const a = manifest.clips.find((item) => item.id === "a")!;
  assertEquals([a.reference, a.checked, a.group, a.phoneText], ["My words.", true, "mix", "text"]);
});

Deno.test("counts: in the test and checked, by group", () => {
  const counts = countClips([
    clip("1", { selected: true, group: "ru", audioMs: 3000, checked: true, reference: "x" }),
    clip("2", { selected: true, group: "mix" }),
    clip("3", { selected: true, group: "en", excluded: true }),
    clip("4", { selected: false, group: "en" }),
    // Checked without a reference doesn't count as checked.
    clip("5", { selected: true, group: "en", checked: true, reference: " " }),
  ]);
  assertEquals(counts.selected, { ru: 1, mix: 1, en: 1, short: 1, total: 3 });
  assertEquals(counts.checked, { ru: 1, mix: 0, en: 0, short: 1, total: 1 });
});

Deno.test("the app's ids and dates, as its history stores them", () => {
  assertEquals(uuidFromHex("BFD971FA183B4A908B4F8BC176BA6705"), "BFD971FA-183B-4A90-8B4F-8BC176BA6705");
  assertEquals(uuidFromHex("bfd971fa-183b-4a90-8b4f-8bc176ba6705"), "BFD971FA-183B-4A90-8B4F-8BC176BA6705");
  assertEquals(uuidFromHex("1234"), null);
  // A row the simulator wrote on 9 November 2026 at 07:30:21 UTC.
  assertEquals(coreDataDate(815902221.915495), "2026-11-09T07:30:21.915Z");
  assertEquals(coreDataDate(null), null);
});

Deno.test("a WAV made here reads back as the same samples", () => {
  const pcm = new Uint8Array(3200).map((_, index) => index % 251);
  assertEquals(wavSamples(wavOf(pcm)), pcm);
  assertEquals(wavSamples(new Uint8Array(10)), null);
});
