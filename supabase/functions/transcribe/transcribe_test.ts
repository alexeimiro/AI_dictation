import { assert, assertEquals, assertFalse, assertRejects, assertStrictEquals } from "jsr:@std/assert@1";
import {
  cleanKeywords,
  cleanLanguageHints,
  isoLanguage,
  OpenAIError,
  openAIForm,
  parseTranscribeRequest,
  TRANSCRIBE_LIMITS,
  type TranscribeRequest,
  transcribeWithOpenAI,
  transcriptUsage,
} from "../_shared/transcribe.ts";

const audio = btoa("fake m4a bytes");

Deno.test("parses a valid request and maps the language to ISO-639-1", () => {
  const parsed = parseTranscribeRequest({
    dictationId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    audio,
    format: "m4a",
    language: "ru_RU",
    keywords: ["Valerio", "  iOS  ", "valerio", "<b>", "two\nlines", 42],
  });
  assert(parsed.ok);
  assertEquals(parsed.value.language, "ru");
  assertEquals(parsed.value.keywords, ["Valerio", "iOS"]);
  assertEquals(new TextDecoder().decode(parsed.value.audio), "fake m4a bytes");
});

Deno.test("rejects malformed requests", () => {
  for (const body of [
    null,
    { audio, format: "mp3" },
    { audio: "", format: "m4a" },
    { audio: "not base64!", format: "m4a" },
    { audio, format: "wav", dictationId: "nope" },
    { audio, format: "wav", language: 12 },
  ]) {
    assertFalse(parseTranscribeRequest(body).ok, JSON.stringify(body));
  }
});

Deno.test("rejects audio over the size limit before decoding it", () => {
  const huge = "A".repeat(Math.ceil(TRANSCRIBE_LIMITS.maxAudioBytes / 3) * 4 + 4);
  const parsed = parseTranscribeRequest({ audio: huge, format: "wav" });
  assertFalse(parsed.ok);
  if (!parsed.ok) assertEquals(parsed.error, "audio too large");
});

Deno.test("language is optional and odd tags fall back to detection", () => {
  const parsed = parseTranscribeRequest({ audio, format: "wav" });
  assert(parsed.ok);
  assertEquals(parsed.value.language, null);
  assertEquals(isoLanguage("en-US"), "en");
  assertEquals(isoLanguage("yue-Hant"), null);
  assertEquals(isoLanguage("nb-NO"), "no");
  assertEquals(isoLanguage("fil-PH"), "tl");
  assertEquals(isoLanguage(undefined), null);
});

Deno.test("the user's languages become ISO-639-1 hints, deduplicated and capped", () => {
  const parsed = parseTranscribeRequest({ audio, format: "m4a", languages: ["en-US", "ru_RU", "en-GB", "nb-NO"] });
  assert(parsed.ok);
  assertEquals(parsed.value.language, null);
  assertEquals(parsed.value.languageHints, ["en", "ru", "no"]);
  // Not a list, or odd items: skipped, never refused.
  assertEquals(cleanLanguageHints("en-US"), []);
  assertEquals(cleanLanguageHints([42, "yue-Hant", "", "uk-UA"]), ["uk"]);
  const many = ["en", "ru", "de", "fr", "es", "it", "pt", "nl", "pl", "uk", "tr", "ja"];
  assertEquals(cleanLanguageHints(many).length, TRANSCRIBE_LIMITS.maxLanguageHints);
});

Deno.test("keywords are capped and deduplicated", () => {
  const many = Array.from({ length: 150 }, (_, index) => `term${index}`);
  assertEquals(cleanKeywords(many).length, TRANSCRIBE_LIMITS.maxKeywords);
  assertEquals(cleanKeywords(["x".repeat(60)]), []);
  assertEquals(cleanKeywords("Valerio"), []);
});

const request: TranscribeRequest = {
  dictationId: null,
  audio: new TextEncoder().encode("audio"),
  format: "m4a",
  language: "ru",
  languageHints: [],
  keywords: ["Valerio", "Okafor"],
};

Deno.test("gpt-transcribe gets languages[] and keywords[]", () => {
  const form = openAIForm(request, "gpt-transcribe");
  assertEquals(form.get("model"), "gpt-transcribe");
  assertEquals(form.getAll("languages[]"), ["ru"]);
  assertEquals(form.getAll("keywords[]"), ["Valerio", "Okafor"]);
  assertEquals(form.get("language"), null);
  const file = form.get("file") as File;
  assertEquals(file.name, "dictation.m4a");
  assertEquals(file.type, "audio/mp4");
});

Deno.test("without a language, gpt-transcribe gets the user's languages to detect it among", () => {
  const form = openAIForm({ ...request, language: null, languageHints: ["en", "ru"] }, "gpt-transcribe");
  assertEquals(form.getAll("languages[]"), ["en", "ru"]);
  // A pinned language wins over the hints.
  assertEquals(openAIForm({ ...request, languageHints: ["en", "ru"] }, "gpt-transcribe").getAll("languages[]"), ["ru"]);
  // No language and no hints: any language.
  assertEquals(openAIForm({ ...request, language: null }, "gpt-transcribe").getAll("languages[]"), []);
});

Deno.test("older models take one hint as the language, and detect among several", () => {
  assertEquals(openAIForm({ ...request, language: null, languageHints: ["de"] }, "whisper-1").get("language"), "de");
  assertEquals(openAIForm({ ...request, language: null, languageHints: ["de", "en"] }, "whisper-1").get("language"), null);
});

Deno.test("older models get language and the terms as a prompt", () => {
  const form = openAIForm({ ...request, format: "wav" }, "gpt-4o-transcribe");
  assertEquals(form.get("language"), "ru");
  assertEquals(form.get("prompt"), "Valerio, Okafor");
  assertEquals(form.getAll("keywords[]"), []);
  assertEquals((form.get("file") as File).type, "audio/wav");
});

Deno.test("returns the transcript and detected languages", async () => {
  const fetcher = (() =>
    Promise.resolve(Response.json({ text: " Привет, мир. ", languages: [{ code: "ru" }] }))) as typeof fetch;
  const result = await transcribeWithOpenAI(request, { apiKey: "k", model: "gpt-transcribe", deadlineMs: 1000, fetcher });
  assertEquals(result, { text: "Привет, мир.", languages: ["ru"] });
});

Deno.test("surfaces OpenAI errors without the response body", async () => {
  const fetcher = (() =>
    Promise.resolve(Response.json({ error: { type: "invalid_request_error", message: "secret detail" } }, { status: 400 }))) as typeof fetch;
  const error = await assertRejects(
    () => transcribeWithOpenAI(request, { apiKey: "k", model: "gpt-transcribe", deadlineMs: 1000, fetcher }),
    OpenAIError,
  );
  assertEquals(error.status, 400);
  assertFalse(error.message.includes("secret detail"));
});

Deno.test("a caller's signal replaces the deadline timer", async () => {
  const sent: (AbortSignal | null | undefined)[] = [];
  const fetcher = ((_url: string, init: RequestInit) => {
    sent.push(init.signal);
    return Promise.resolve(Response.json({ text: "Привет.", languages: [{ code: "ru" }] }));
  }) as unknown as typeof fetch;
  const signal = new AbortController().signal;
  await transcribeWithOpenAI(request, { apiKey: "k", model: "gpt-transcribe", deadlineMs: 1000, signal, fetcher });
  await transcribeWithOpenAI(request, { apiKey: "k", model: "gpt-transcribe", deadlineMs: 1000, fetcher });
  // Identity, not equality: two signals that haven't fired compare as equal objects.
  assertStrictEquals(sent[0], signal);
  assert(sent[1] instanceof AbortSignal && sent[1] !== signal, "without one, the deadline arms its own");
});

const DICTATION = "7c9e6679-7425-40de-944b-e07fc1f90ae7";

Deno.test("a transcript's words are counted under the dictation the header vouches for", () => {
  const named = { ...request, dictationId: DICTATION };
  const heard = { text: "Привет, мир. Как дела?", languages: ["ru"] };
  assertEquals(transcriptUsage(named, DICTATION, heard), { dictationId: DICTATION, words: 4 });
  // The header's case and padding don't matter; the id is recorded as the body gave it.
  assertEquals(transcriptUsage(named, ` ${DICTATION.toUpperCase()} `, heard), { dictationId: DICTATION, words: 4 });
});

Deno.test("nothing is counted without the header, with another dictation's, or for silence", () => {
  const named = { ...request, dictationId: DICTATION };
  const heard = { text: "See you at five.", languages: ["en"] };
  // Builds before the header sent a random id here, and `cleanup` then reports the real one.
  assertEquals(transcriptUsage(named, null, heard), null);
  assertEquals(transcriptUsage(named, "", heard), null);
  assertEquals(transcriptUsage(named, "11111111-2222-4333-8444-555555555555", heard), null);
  assertEquals(transcriptUsage({ ...request, dictationId: null }, DICTATION, heard), null);
  assertEquals(transcriptUsage(named, DICTATION, { text: "", languages: [] }), null);
  assertEquals(transcriptUsage(named, DICTATION, { text: "…", languages: ["en"] }), null);
});

Deno.test("words are counted in the language asked for, else the one heard first", () => {
  const japanese = { text: "今日は良い天気ですね", languages: ["ja"] };
  const detected = transcriptUsage({ ...request, dictationId: DICTATION, language: null }, DICTATION, japanese);
  const pinned = transcriptUsage({ ...request, dictationId: DICTATION, language: "ja" }, DICTATION, japanese);
  assert(detected && pinned);
  // Segmented as Japanese either way, not as one unbroken English "word".
  assert(detected.words > 1, `detected: ${detected.words}`);
  assertEquals(pinned.words, detected.words);
  // Nothing asked for and nothing heard: counted as English.
  const unknown = transcriptUsage(
    { ...request, dictationId: DICTATION, language: null },
    DICTATION,
    { text: "see you at five", languages: [] },
  );
  assertEquals(unknown?.words, 4);
});

Deno.test("the server key prefers the new secret keys", async () => {
  const { serverKey } = await import("../_shared/http.ts");
  assertEquals(serverKey('{"default":"sb_secret_new"}', "legacy"), "sb_secret_new");
  assertEquals(serverKey(undefined, "legacy"), "legacy");
  assertEquals(serverKey("not json", "legacy"), "legacy");
  assertEquals(serverKey('{"billing":"sb_secret_x"}', undefined), undefined);
});
