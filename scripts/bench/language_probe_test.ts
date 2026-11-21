// Offline: the speech languages the app offers are ones the server can name to the recognizer.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { probeCodes, silentWav, swiftLanguageList } from "./language_probe.ts";

const source = await Deno.readTextFile(
  new URL("../../Packages/MurmurKit/Sources/MurmurCore/Text/DictationLanguage.swift", import.meta.url),
);

Deno.test("the probe reads the app's own lists from the Swift source", () => {
  const speech = swiftLanguageList(source, "speechLanguages");
  const textOnly = swiftLanguageList(source, "textOnlyLanguages");
  assertEquals(speech.length, 65);
  assertEquals(textOnly.length, 26);
  assert(speech.includes("ru-RU") && speech.includes("yue-CN") && speech.includes("bn-BD"));
  assertEquals(speech.filter((tag) => textOnly.includes(tag)), []);
});

Deno.test("every speech language maps to a code the server sends; no two to the same one", () => {
  const codes = probeCodes(swiftLanguageList(source, "speechLanguages"));
  assertEquals(codes.filter(({ code }) => code === null).map(({ tag }) => tag), []);
  const sent = codes.map(({ code }) => code);
  assertEquals(new Set(sent).size, sent.length);
  assertEquals(codes.find(({ tag }) => tag === "tl-PH")?.code, "tl");
  assertEquals(codes.find(({ tag }) => tag === "nb-NO")?.code, "no");
  assertEquals(codes.find(({ tag }) => tag === "yue-CN")?.code, "yue");
});

Deno.test("the probe's audio is a one-second WAV", () => {
  const wav = silentWav();
  assertEquals(new TextDecoder().decode(wav.slice(0, 4)), "RIFF");
  assertEquals(new TextDecoder().decode(wav.slice(8, 12)), "WAVE");
  assertEquals(wav.length, 44 + 32_000);
});
