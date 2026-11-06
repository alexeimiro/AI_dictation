import { assert, assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1";
import {
  cleanKeywords,
  isoLanguage,
  OpenAIError,
  openAIForm,
  parseTranscribeRequest,
  TRANSCRIBE_LIMITS,
  type TranscribeRequest,
  transcribeWithOpenAI,
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

Deno.test("the server key prefers the new secret keys", async () => {
  const { serverKey } = await import("../_shared/http.ts");
  assertEquals(serverKey('{"default":"sb_secret_new"}', "legacy"), "sb_secret_new");
  assertEquals(serverKey(undefined, "legacy"), "legacy");
  assertEquals(serverKey("not json", "legacy"), "legacy");
  assertEquals(serverKey('{"billing":"sb_secret_x"}', undefined), undefined);
});
