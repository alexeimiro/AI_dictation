import {
  assert,
  assertEquals,
  assertFalse,
  assertNotMatch,
  assertRejects,
  assertStringIncludes,
} from "jsr:@std/assert@1";
import {
  buildInstructionParts,
  buildResponsesRequest,
  CleanupAPIError,
  describeCleanupError,
  runCleanup,
} from "../_shared/cleanup.ts";
import { cleanupConfig, translationConfig } from "../_shared/config.ts";
import {
  buildLanguageBlock,
  buildTranscriptMessage,
  buildTranslationContext,
  buildTranslationMessage,
  buildUserContext,
  CLEANUP_RULES,
  describeLanguage,
  LANGUAGE_RULES,
  resolveLanguage,
  TRANSLATION_RULES,
  TRANSLATION_STYLES,
} from "../_shared/prompt.ts";
import {
  countWords,
  cyrillicShare,
  guardOutput,
  guardTranslation,
  scriptOf,
  scriptShare,
  tidyOutput,
  wordOverlap,
} from "../_shared/text.ts";
import { type CleanupRequest, LIMITS, normalizeLanguageTag, parseCleanupRequest } from "../_shared/types.ts";

const request: CleanupRequest = {
  dictationId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  transcript: "um so can you send me the report by friday",
  language: "en-US",
  style: "casual",
  dictionary: [{ term: "Valerio", misspelling: "valeria" }, { term: "iOS" }],
  snippets: [{ token: "⟦s:1a2b3c4d⟧", trigger: "my calendar link" }],
};

const russianRequest: CleanupRequest = {
  dictationId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  transcript: "э-э ну короче можешь скинуть отчёт до пятницы вопросительный знак спасибо большое",
  language: "ru-RU",
  style: "casual",
};

// A signal that never fires: the deadline default (`AbortSignal.timeout`) would leave a timer
// behind, which Deno's test sanitizer reports as a leak.
const signal = new AbortController().signal;

interface Captured {
  url?: string;
  init?: RequestInit;
  body?: Record<string, unknown>;
}

/** A Responses API reply with the given text, merged with `overrides`. */
function reply(text: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    model: "gpt-6-astra-2026-09-01",
    status: "completed",
    incomplete_details: null,
    output: [
      { type: "reasoning", summary: [] },
      { type: "message", role: "assistant", content: [{ type: "output_text", text, annotations: [] }] },
    ],
    usage: { input_tokens: 1950, output_tokens: 12, input_tokens_details: { cached_tokens: 1900 } },
    ...overrides,
  };
}

/** Stands in for `fetch`, answering with `body` (or failing with `failure`). */
function fakeFetch(body: Record<string, unknown>, captured: Captured = {}, status = 200, failure?: Error) {
  return ((url: string, init: RequestInit) => {
    captured.url = url;
    captured.init = init;
    captured.body = JSON.parse(String(init.body));
    if (failure) return Promise.reject(failure);
    return Promise.resolve(Response.json(body, { status }));
  }) as unknown as typeof fetch;
}

function options(fetcher: typeof fetch) {
  return { model: "gpt-6-astra", effort: "low", apiKey: "sk-test", deadlineMs: 9000, signal, fetcher };
}

const cleaned = reply("Can you send me the report by Friday?");

Deno.test("sends the agreed request shape to OpenAI", async () => {
  const captured: Captured = {};
  await runCleanup(request, options(fakeFetch(cleaned, captured)));
  assertEquals(captured.url, "https://api.openai.com/v1/responses");
  assertEquals((captured.init!.headers as Record<string, string>).Authorization, "Bearer sk-test");
  assertEquals(captured.init!.signal, signal);
  const body = captured.body!;
  assertEquals(body.model, "gpt-6-astra");
  assertEquals(body.reasoning, { effort: "low" });
  assertEquals(body.store, false, "dictations are never stored as responses on OpenAI's side");
  assertEquals(body.max_output_tokens, 16000);
  assertEquals(body.prompt_cache_key, "murmur-cleanup-en");
  assertEquals(body.instructions, [
    CLEANUP_RULES,
    buildLanguageBlock(LANGUAGE_RULES.en),
    buildUserContext(request, resolveLanguage("en-US")),
  ].join("\n\n"));
  assertEquals(body.input, [{ role: "user", content: buildTranscriptMessage(request.transcript) }]);
});

Deno.test("returns the cleaned text, language and usage", async () => {
  const outcome = await runCleanup(request, options(fakeFetch(cleaned)));
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.text, "Can you send me the report by Friday?");
  assertEquals(outcome.language, "en");
  assertEquals(outcome.model, "gpt-6-astra-2026-09-01");
  assertEquals(outcome.stopReason, "completed");
  assertEquals(outcome.usage, { input: 1950, output: 12, cacheRead: 1900, cacheWrite: 0 });
  assertEquals(outcome.cacheReadTokens, 1900);
  assertEquals(outcome.ttftMs, null);
});

Deno.test("cache writes are read from the usage, and are 0 when it doesn't report them", async () => {
  const usage = { input_tokens: 1950, output_tokens: 12 };
  const written = reply("Can you send me the report by Friday?", {
    usage: { ...usage, input_tokens_details: { cached_tokens: 0, cache_write_tokens: 1920 } },
  });
  const unreported = reply("Can you send me the report by Friday?", { usage });
  const outcome = await runCleanup(request, options(fakeFetch(written)));
  assertEquals(outcome.usage, { input: 1950, output: 12, cacheRead: 0, cacheWrite: 1920 });
  const fallback = await runCleanup(request, options(fakeFetch(unreported)));
  assertEquals(fallback.usage, { input: 1950, output: 12, cacheRead: 0, cacheWrite: 0 });
});

Deno.test("a Russian request gets the Russian pack and its own cache key", async () => {
  const captured: Captured = {};
  const outcome = await runCleanup(
    russianRequest,
    options(fakeFetch(reply("Можешь скинуть отчёт до пятницы? Спасибо большое!"), captured)),
  );
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.language, "ru");
  assertEquals(captured.body!.prompt_cache_key, "murmur-cleanup-ru");
  const instructions = captured.body!.instructions as string;
  assertStringIncludes(instructions, buildLanguageBlock(LANGUAGE_RULES.ru));
  assertStringIncludes(instructions, "Language: ru-RU (");
});

const translationRequest: CleanupRequest = { ...russianRequest, targetLanguage: "tr-TR" };

Deno.test("a translation gets the translation prompt, not the cleanup rules and language pack", async () => {
  const captured: Captured = {};
  const outcome = await runCleanup(
    translationRequest,
    options(fakeFetch(reply("Raporu cuma gününe kadar gönderebilir misin? Çok teşekkürler!"), captured)),
  );
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.text, "Raporu cuma gününe kadar gönderebilir misin? Çok teşekkürler!");
  const body = captured.body!;
  const source = resolveLanguage("ru-RU", russianRequest.transcript);
  assertEquals(body.instructions, [TRANSLATION_RULES, buildTranslationContext(translationRequest, source)].join("\n\n"));
  assertEquals(body.prompt_cache_key, "murmur-translate");
  assertEquals(body.input, [{ role: "user", content: buildTranslationMessage(russianRequest.transcript, "tr-TR") }]);

  // The cleanup rules, the language pack and their 14 same-language examples all say to keep the
  // spoken language; with them in the prompt the model returned cleaned-up Russian.
  const instructions = body.instructions as string;
  assertFalse(instructions.includes(CLEANUP_RULES));
  assertFalse(instructions.includes(buildLanguageBlock(LANGUAGE_RULES.ru)));
  assertNotMatch(instructions, /keep the output in the language that was spoken|Keep it Russian/);
  assertStringIncludes(instructions, "Source language: Russian (Russia) [ru-RU].");
  assertStringIncludes(instructions, "Target language: Turkish (Türkiye) [tr-TR], written in Latin script.");
  const message = buildTranslationMessage(russianRequest.transcript, "tr-TR");
  assert(message.startsWith(buildTranscriptMessage(russianRequest.transcript)), message);
  assert(message.endsWith("\n\nTranslate the transcript into Turkish (Türkiye) [tr-TR]."), message);
});

Deno.test("a translation that comes back in the spoken language is rejected as untranslated", async () => {
  // The reported bug: translation on, and the model returned a cleanup of the Russian instead.
  const outcome = await runCleanup(
    translationRequest,
    options(fakeFetch(reply("Можешь скинуть отчёт до пятницы? Спасибо большое!"))),
  );
  assertEquals(outcome.status, "raw");
  assertEquals(outcome.reason, "untranslated");
  // The same reply is a good cleanup when nothing asked for a translation.
  const cleanup = await runCleanup(russianRequest, options(fakeFetch(reply("Можешь скинуть отчёт до пятницы? Спасибо большое!"))));
  assertEquals(cleanup.status, "cleaned");
});

Deno.test("translation context: the language pair, the target's style, the dictionary", () => {
  const auto = buildTranslationContext(
    { ...translationRequest, language: undefined },
    resolveLanguage(undefined, russianRequest.transcript),
  );
  assertStringIncludes(auto, "Source language: not given; it is whatever language the transcript is in.");

  // The style is the target language's: the output is written in it.
  const intoRussian = buildTranslationContext({ ...request, targetLanguage: "ru-RU", style: "veryCasual" }, resolveLanguage("en-US"));
  assertStringIncludes(intoRussian, "Style: " + LANGUAGE_RULES.ru.styles.veryCasual);
  const intoEnglish = buildTranslationContext(
    { ...russianRequest, targetLanguage: "en-US", style: "veryCasual" },
    resolveLanguage("ru-RU"),
  );
  assertStringIncludes(intoEnglish, "Style: " + LANGUAGE_RULES.en.styles.veryCasual);
  assertFalse(intoEnglish.includes("«я»"), "a Russian style rule must not reach an English translation");
  const intoTurkish = buildTranslationContext({ ...translationRequest, style: "formal" }, resolveLanguage("ru-RU"));
  assertStringIncludes(intoTurkish, "Style: " + TRANSLATION_STYLES.formal);

  const intoGerman = buildTranslationContext({ ...request, targetLanguage: "de-DE" }, resolveLanguage("en-US"));
  assertStringIncludes(intoGerman, "Valerio ← valeria");
  assertStringIncludes(intoGerman, '⟦s:1a2b3c4d⟧ — trigger phrase: "my calendar link"');
  const intoJapanese = buildTranslationContext({ ...request, targetLanguage: "ja-JP" }, resolveLanguage("en-US"));
  assertStringIncludes(intoJapanese, "Target language: Japanese (Japan) [ja-JP], written in Japanese script.");
  assertEquals(describeLanguage("zh-Hans-CN"), "Chinese (Simplified, China) [zh-Hans-CN]");
  assertEquals(describeLanguage("en-US"), "American English [en-US]");
});

Deno.test("the translation rules are a stable prefix that clears the caching minimum", () => {
  // ~4 characters per token for English prose; the Cyrillic and Japanese examples cost more.
  assert(TRANSLATION_RULES.length / 4 > 1100, `the translation prefix is only ~${Math.round(TRANSLATION_RULES.length / 4)} tokens`);
  assertFalse(/\$\{|\d{4}-\d{2}-\d{2}/.test(TRANSLATION_RULES), "no volatile content in the cached prefix");
  assertEquals(TRANSLATION_RULES.match(/<example source="[A-Za-z]+" target="[A-Za-z]+">/g)?.length, 8);
});

Deno.test("translation guard: a script change is expected, staying in the spoken script is not", () => {
  const ruToEn = { source: "ru-RU", target: "en-US" };
  const russian = russianRequest.transcript;
  assert(guardTranslation(russian, "Can you send me the report by Friday? Thanks a lot!", ruToEn).ok);
  assertEquals(guardTranslation(russian, "Можешь скинуть отчёт до пятницы? Спасибо большое!", ruToEn), {
    ok: false,
    reason: "untranslated",
  });
  // A cleanup that wrote the brands in Latin is still Russian.
  assertEquals(
    guardTranslation(
      "я запушил коммит в гитхаб и написал в телеграм что фича готова",
      "Я запушил коммит в GitHub и написал в Telegram, что фича готова.",
      ruToEn,
    ),
    { ok: false, reason: "untranslated" },
  );
  // An auto-detected Russian source is judged by its script just the same.
  assertEquals(guardTranslation(russian, "Можешь скинуть отчёт до пятницы? Спасибо большое!", { target: "en-US" }), {
    ok: false,
    reason: "untranslated",
  });

  const enToRu = { source: "en-US", target: "ru-RU" };
  assertEquals(guardTranslation(request.transcript, "Can you send me the report by Friday?", enToRu), {
    ok: false,
    reason: "untranslated",
  });
  // Brands, code and URLs stay Latin, so a translation into Cyrillic may keep plenty of Latin.
  assert(guardTranslation(
    "deploy the next js app to vercel with github actions",
    "Задеплой приложение Next.js на Vercel через GitHub Actions",
    enToRu,
  ).ok);
  assert(guardTranslation("open github actions", "Открой GitHub Actions", enToRu).ok);
  assert(guardTranslation("iphone seventeen pro", "iPhone 17 Pro", enToRu).ok, "too few letters to judge");
  assert(guardTranslation("you can book time here my calendar link", "Время можно забронировать здесь: ⟦s:1a2b3c4d⟧", enToRu).ok);

  const enToJa = { source: "en-US", target: "ja-JP" };
  assert(guardTranslation("send the pdf to tanaka on slack", "田中さんにSlackでPDFを送って", enToJa).ok);
  assertEquals(guardTranslation("hey can you send me the report by friday", "Hey, can you send me the report by Friday?", enToJa), {
    ok: false,
    reason: "untranslated",
  });
  assertEquals(
    guardTranslation(russian, "Можешь скинуть отчёт до пятницы? Спасибо большое!", { source: "ru-RU", target: "zh-CN" }),
    { ok: false, reason: "untranslated" },
  );
});

Deno.test("translation guard: within one script the words show whether it was translated", () => {
  const enToTr = { source: "en-US", target: "tr-TR" };
  const english = "um so can you send me the report by friday thanks so much";
  assert(guardTranslation(english, "Raporu cumaya kadar gönderebilir misin? Çok teşekkürler!", enToTr).ok);
  assertEquals(guardTranslation(english, "Can you send me the report by Friday? Thanks so much!", enToTr), {
    ok: false,
    reason: "untranslated",
  });
  assert(guardTranslation(
    "tell john that the meeting with google is at five",
    "Sag John, dass das Meeting mit Google um fünf ist.",
    { source: "en-US", target: "de-DE" },
  ).ok, "names and loanwords may stay");

  const ruToUk = { source: "ru-RU", target: "uk-UA" };
  const plan = "я думаю что мы должны встретиться завтра утром чтобы обсудить проект";
  assert(guardTranslation(plan, "Я думаю, що ми повинні зустрітися завтра вранці, щоб обговорити проєкт.", ruToUk).ok);
  assertEquals(guardTranslation(plan, "Я думаю, что мы должны встретиться завтра утром, чтобы обсудить проект.", ruToUk), {
    ok: false,
    reason: "untranslated",
  });

  // The speaker may have spoken the target language itself: then a cleanup is the right output.
  const spokenEnglish = "um so can you send me the report by friday";
  assert(guardTranslation(spokenEnglish, "Can you send me the report by Friday?", { target: "en-US" }).ok, "auto-detected");
  assert(
    guardTranslation(spokenEnglish, "Can you send me the report by Friday?", { source: "ru-RU", target: "en-US" }).ok,
    "not in the source language's script",
  );
});

Deno.test("translation guard: empty and runaway replies, and room for longer translations", () => {
  const ruToEn = { source: "ru-RU", target: "en-US" };
  assertEquals(guardTranslation("можешь скинуть отчёт до пятницы", "", ruToEn), { ok: false, reason: "empty" });
  const answer = "The best way to learn Python is to start with the official tutorial, then build small projects " +
    "every day, read other people's code, and ask questions in the community forums when you get stuck.";
  assertEquals(guardTranslation("как лучше всего выучить питон", answer, ruToEn), { ok: false, reason: "too_long" });
  assert(guardTranslation("как лучше всего выучить питон", "What's the best way to learn Python?", ruToEn).ok);
  // Turkish packs into one word what English says in several; that is no runaway reply.
  assert(guardTranslation(
    "yarın sabah erkenden markete gidip ekmek süt ve yumurta almam gerekiyor sonra da işe gideceğim",
    "Tomorrow morning I need to go to the store early and buy bread, milk and eggs, and then I'll go to work.",
    { source: "tr-TR", target: "en-US" },
  ).ok);
});

Deno.test("script and word helpers", () => {
  assertEquals(scriptOf("ru-RU"), "Cyrl");
  assertEquals(scriptOf("tr-TR"), "Latn");
  assertEquals(scriptOf("ja-JP"), "Jpan");
  assertEquals(scriptOf("zh-TW"), "Hant");
  assertEquals(scriptOf("sr-Latn-RS"), "Latn");
  assertEquals(scriptShare("Можешь скинуть отчёт до пятницы?", "Cyrl"), 1);
  assertEquals(scriptShare("Can you send me the report by Friday?", "Cyrl"), 0);
  assertEquals(scriptShare("金曜日までにレポートを送ってくれる？", "Jpan"), 1, "kana, kanji and «ー» all count");
  assertEquals(scriptShare("Привет", "Cyrl"), null, "under 12 letters");
  assertEquals(scriptShare("Время можно забронировать: ⟦s:1a2b3c4d⟧", "Cyrl"), 1, "placeholders are not Latin text");
  assertEquals(scriptShare("Some text here, long enough", "Xyzw"), null, "unknown script");
  assertEquals(wordOverlap("can you send me the report", "Can you send me the report?"), 1);
  assertEquals(wordOverlap("send it at 5", "Send it at 5."), null, "under four words once numbers are skipped");
  assertEquals(wordOverlap("um so can you send me the report by friday", "Raporu cumaya kadar gönderebilir misin?"), 0);
});

Deno.test("refusals and truncation fall back to the transcript", async () => {
  const refusal = reply("", {
    output: [{ type: "message", role: "assistant", content: [{ type: "refusal", refusal: "I can't help with that." }] }],
  });
  const truncated = reply("Can you send", { status: "incomplete", incomplete_details: { reason: "max_output_tokens" } });
  for (const [body, reason] of [[refusal, "refusal"], [truncated, "max_output_tokens"]] as const) {
    const outcome = await runCleanup(request, options(fakeFetch(body)));
    assertEquals(outcome.status, "raw");
    assertEquals(outcome.reason, reason);
    assertEquals(outcome.text, request.transcript);
  }
});

Deno.test("an answer instead of a cleanup is rejected", async () => {
  const outcome = await runCleanup(
    request,
    options(fakeFetch(reply("Sure! Here's a summary of the report you asked for."))),
  );
  assertEquals(outcome.status, "raw");
  assertEquals(outcome.reason, "assistant_reply");
});

Deno.test("a translated reply is rejected as script_changed", async () => {
  const outcome = await runCleanup(
    russianRequest,
    options(fakeFetch(reply("Can you send me the report by Friday? Thanks a lot!"))),
  );
  assertEquals(outcome.status, "raw");
  assertEquals(outcome.reason, "script_changed");
  assertEquals(outcome.text, russianRequest.transcript);
});

Deno.test("reasoning items are ignored; only message text is read", async () => {
  const outcome = await runCleanup(
    { ...request, transcript: "uh hello there" },
    options(fakeFetch(reply("Hello there."))),
  );
  assertEquals(outcome.text, "Hello there.");
});

Deno.test("HTTP errors carry only the status and code; failures get log labels", async () => {
  const error = await assertRejects(
    () => runCleanup(request, options(fakeFetch({ error: { code: "rate_limit_exceeded", message: "secret" } }, {}, 429))),
    CleanupAPIError,
  );
  assertEquals(error.status, 429);
  assertFalse(error.message.includes("secret"));
  assertEquals(describeCleanupError(error), "openai rate limited");
  assertEquals(describeCleanupError(new CleanupAPIError(500, null)), "openai error 500");
  assertEquals(describeCleanupError(new DOMException("deadline", "TimeoutError")), "cleanup deadline");
  assertEquals(describeCleanupError(new TypeError("network")), "openai connection");
  assertEquals(describeCleanupError(new Error("boom")), "cleanup failed");
  await assertRejects(
    () => runCleanup(request, options(fakeFetch({}, {}, 200, new DOMException("deadline", "TimeoutError")))),
    DOMException,
  );
});

Deno.test("the effort and model follow the options", () => {
  const body = buildResponsesRequest(request, resolveLanguage("en-US"), { model: "gpt-6.1-terra", effort: "none" });
  assertEquals(body.model, "gpt-6.1-terra");
  assertEquals(body.reasoning, { effort: "none" });
  assertEquals(buildResponsesRequest(request, resolveLanguage("en-US"), { model: "m" }).reasoning, { effort: "low" });
});

Deno.test("TRANSLATE_* change translations only; unset, translations keep today's cleanup settings", async () => {
  // What the hosted project sets today, then the same with a translation model on top.
  const today = new Map([["CLEANUP_MODEL", "gpt-6.1-terra"], ["CLEANUP_EFFORT", "none"], ["CLEANUP_DEADLINE_MS", "8000"]]);
  assertEquals(translationConfig(today), cleanupConfig(today));
  assertEquals(translationConfig(new Map()), cleanupConfig(new Map()), "and with nothing set at all");
  const luna = new Map([...today, ["TRANSLATE_MODEL", "gpt-6-luna"]]);
  assertEquals(cleanupConfig(luna), { model: "gpt-6.1-terra", effort: "none", deadlineMs: 8000 });
  assertEquals(translationConfig(luna), { model: "gpt-6-luna", effort: "none", deadlineMs: 8000 });

  // `cleanup` runs a request with the translation settings when it has a target, as index.ts picks them.
  const translated: Captured = {};
  const cleanedUp: Captured = {};
  const translation = reply("Raporu cuma gününe kadar gönderebilir misin? Çok teşekkürler!");
  await runCleanup(translationRequest, { ...translationConfig(luna), apiKey: "k", signal, fetcher: fakeFetch(translation, translated) });
  await runCleanup(russianRequest, { ...cleanupConfig(luna), apiKey: "k", signal, fetcher: fakeFetch(cleaned, cleanedUp) });
  assertEquals([translated.body!.model, translated.body!.reasoning], ["gpt-6-luna", { effort: "none" }]);
  assertEquals([cleanedUp.body!.model, cleanedUp.body!.reasoning], ["gpt-6.1-terra", { effort: "none" }]);
});

Deno.test({
  name: "without an injected signal the deadline arms AbortSignal.timeout",
  // The timer is awaited below, so nothing leaks; the sanitizer is only relaxed for the unref'd timer.
  sanitizeOps: false,
  async fn() {
    const captured: Captured = {};
    await runCleanup(request, { model: "gpt-6-astra", apiKey: "k", deadlineMs: 20, fetcher: fakeFetch(cleaned, captured) });
    const deadline = captured.init!.signal as AbortSignal;
    assert(deadline instanceof AbortSignal);
    assertFalse(deadline.aborted);
    await new Promise((resolve) => deadline.addEventListener("abort", resolve, { once: true }));
    assertEquals((deadline.reason as DOMException).name, "TimeoutError");
  },
});

Deno.test("language resolution from tags", () => {
  for (const tag of ["ru", "ru-RU", "ru-Cyrl-RU"]) {
    const resolved = resolveLanguage(tag);
    assertEquals(resolved.key, "ru", tag);
    assertEquals(resolved.tag, tag);
    assertEquals(resolved.rules, LANGUAGE_RULES.ru);
  }
  assertEquals(resolveLanguage("en-US").key, "en");
  assertEquals(resolveLanguage("de-DE"), { key: "en", tag: "de-DE", rules: LANGUAGE_RULES.en });
  assertEquals(resolveLanguage(undefined), { key: "en", tag: null, rules: LANGUAGE_RULES.en });
  assertEquals(resolveLanguage("und", russianRequest.transcript), {
    key: "ru", tag: null, rules: LANGUAGE_RULES.ru,
  });
});

Deno.test("the language block is byte-identical for every user of a language", () => {
  const ru = resolveLanguage("ru-RU");
  const alice = buildInstructionParts(russianRequest, ru);
  const bob = buildInstructionParts({
    ...russianRequest,
    dictationId: "11111111-2222-4333-8444-555555555555",
    transcript: "совсем другой текст",
    style: "formal",
    dictionary: [{ term: "Яндекс", misspelling: "индекс" }],
    snippets: [{ token: "⟦s:1a2b3c4d⟧", trigger: "моя ссылка" }],
  }, ru);
  assertEquals(alice.length, 3);
  assertEquals(alice[0], bob[0]);
  assertEquals(alice[1], bob[1]);
  assert(alice[2] !== bob[2], "only the per-user part differs, and it comes last");

  const block = buildLanguageBlock(LANGUAGE_RULES.ru);
  assertEquals(block, buildLanguageBlock(LANGUAGE_RULES.ru));
  assert(block.startsWith('<language key="ru" name="Russian" script="Cyrillic">'));
  assert(block.endsWith("</examples>\n</language>"));
  assertEquals(block.match(/<example>/g)?.length, 8, "eight Russian few-shot examples");
  assertEquals(block.match(/<\/example>/g)?.length, 8);
  for (const example of LANGUAGE_RULES.ru.examples) {
    assertStringIncludes(block, `<transcript>${example.transcript}</transcript>`);
    assertStringIncludes(block, `<output>${example.output}</output>`);
  }
  assertFalse(/\$\{|\d{4}-\d{2}-\d{2}/.test(block), "no volatile content in the cached prefix");
});

Deno.test("Russian styles replace English ones", () => {
  const ru = resolveLanguage("ru-RU");
  const veryCasual = buildUserContext({ ...russianRequest, style: "veryCasual" }, ru);
  assertStringIncludes(veryCasual, "Style: " + LANGUAGE_RULES.ru.styles.veryCasual);
  assertStringIncludes(veryCasual, "«я» stays lowercase");
  assertFalse(veryCasual.includes('"I"'), "the English capital-I rule must not reach Russian users");
  const formal = buildUserContext({ ...russianRequest, style: "formal" }, ru);
  assertStringIncludes(formal, "«Вы»");
  const english = buildUserContext({ ...request, style: "veryCasual" }, resolveLanguage("en-US"));
  assertStringIncludes(english, LANGUAGE_RULES.en.styles.veryCasual);
});

Deno.test("word for word style keeps the speaker's words and translates literally", () => {
  const parsed = parseCleanupRequest({ ...request, style: "verbatim" });
  assert(parsed.ok && parsed.value.style === "verbatim");

  const english = buildUserContext({ ...request, style: "verbatim" }, resolveLanguage("en-US"));
  assertStringIncludes(english, "Style: " + LANGUAGE_RULES.en.styles.verbatim);
  assertStringIncludes(english, "including self-corrections");
  const russian = buildUserContext({ ...russianRequest, style: "verbatim" }, resolveLanguage("ru-RU"));
  assertStringIncludes(russian, "Style: " + LANGUAGE_RULES.ru.styles.verbatim);

  const intoEnglish = buildTranslationContext(
    { ...russianRequest, targetLanguage: "en-US", style: "verbatim" },
    resolveLanguage("ru-RU"),
  );
  assertStringIncludes(intoEnglish, "translate literally");
  const intoTurkish = buildTranslationContext({ ...translationRequest, style: "verbatim" }, resolveLanguage("ru-RU"));
  assertStringIncludes(intoTurkish, "Style: " + TRANSLATION_STYLES.verbatim);
});

Deno.test("the context writes only the sanitized tag", () => {
  const parsed = parseCleanupRequest({ ...russianRequest, language: "ru-RU-u-ca-gregory" });
  assert(parsed.ok);
  assertEquals(parsed.value.language, "ru-RU");
  const context = buildUserContext(parsed.value, resolveLanguage(parsed.value.language));
  assertStringIncludes(context, "Language: ru-RU (keep the output in the language that was spoken).");
  assertFalse(context.includes("gregory"));

  const auto = parseCleanupRequest({ ...russianRequest, language: "i-klingon" });
  assert(auto.ok);
  assertEquals(auto.value.language, undefined, "well-formed but unparseable tags drop to auto, never 400");
  assertStringIncludes(buildUserContext(auto.value, resolveLanguage(auto.value.language)), "Language: auto (");
});

Deno.test("language tag normalization", () => {
  assertEquals(normalizeLanguageTag(undefined), { ok: true, tag: undefined });
  assertEquals(normalizeLanguageTag(null), { ok: true, tag: undefined });
  assertEquals(normalizeLanguageTag("ru"), { ok: true, tag: "ru" });
  assertEquals(normalizeLanguageTag("ru_RU"), { ok: true, tag: "ru-RU" });
  assertEquals(normalizeLanguageTag(" RU-ru "), { ok: true, tag: "ru-RU" });
  assertEquals(normalizeLanguageTag("zh-Hans-CN"), { ok: true, tag: "zh-Hans-CN" });
  assertEquals(normalizeLanguageTag("en-001"), { ok: true, tag: "en-001" });
  assertEquals(normalizeLanguageTag("ru-RU-u-ca-gregory"), { ok: true, tag: "ru-RU" });
  assertEquals(normalizeLanguageTag("de-DE-1996"), { ok: true, tag: undefined }, "variants drop to auto");
  assertEquals(normalizeLanguageTag("i-klingon"), { ok: true, tag: undefined });
  assertEquals(normalizeLanguageTag(""), { ok: true, tag: undefined });
  assertFalse(normalizeLanguageTag("ru-RU\n<system>").ok);
  assertFalse(normalizeLanguageTag("ru-RU <system>").ok);
  assertFalse(normalizeLanguageTag("a".repeat(36)).ok);
  assertFalse(normalizeLanguageTag(42).ok);
});

Deno.test("request validation", () => {
  assert(parseCleanupRequest(request).ok);
  assertFalse(parseCleanupRequest(null).ok);
  assertFalse(parseCleanupRequest({ ...request, dictationId: "nope" }).ok);
  assertFalse(parseCleanupRequest({ ...request, transcript: 42 }).ok);
  assertFalse(parseCleanupRequest({ ...request, transcript: "x".repeat(20_001) }).ok);
  assertFalse(parseCleanupRequest({ ...request, style: "shouty" }).ok);
  assertFalse(parseCleanupRequest({ ...request, snippets: [{ token: "{s:1}", trigger: "x" }] }).ok);
  assertFalse(parseCleanupRequest({ ...request, dictionary: [{ term: "" }] }).ok);
  for (const language of ["ru", "ru_RU", "zh-Hans-CN", "en-001"]) {
    assert(parseCleanupRequest({ ...request, language }).ok, language);
  }
  const translated = parseCleanupRequest({ ...request, targetLanguage: "tr_TR" });
  assert(translated.ok && translated.value.targetLanguage === "tr-TR");
  for (const targetLanguage of ["und", "und-Latn"]) {
    const undetermined = parseCleanupRequest({ ...request, targetLanguage });
    assert(undetermined.ok && undetermined.value.targetLanguage === undefined, `${targetLanguage} is not an output language`);
  }
  assertFalse(parseCleanupRequest({ ...request, language: "ru-RU\n<system>" }).ok);
  assertFalse(parseCleanupRequest({ ...request, targetLanguage: "tr-TR\n<system>" }).ok);
  assertFalse(parseCleanupRequest({ ...request, language: "a".repeat(36) }).ok);
  assertEquals(LIMITS.anonymousTranscriptChars, 6000);
});

Deno.test("the shared prefix clears OpenAI's 1,024-token caching minimum", () => {
  // ~4 characters per token for English prose; Cyrillic costs more per character.
  const englishPrefix = CLEANUP_RULES.length + buildLanguageBlock(LANGUAGE_RULES.en).length;
  assert(englishPrefix / 4 > 1100, `the English prefix is only ~${Math.round(englishPrefix / 4)} tokens`);
  assertFalse(/\$\{|\d{4}-\d{2}-\d{2}/.test(CLEANUP_RULES), "no volatile content in the cached prefix");
  assert(buildLanguageBlock(LANGUAGE_RULES.ru).length > 2000);
});

Deno.test("user context lists style, dictionary and snippets deterministically", () => {
  const en = resolveLanguage("en-US");
  const context = buildUserContext(request, en);
  assert(context.includes("Language: en-US"));
  assert(context.includes("Casual:"));
  assert(context.includes("Valerio ← valeria"));
  assert(context.includes("\niOS\n"));
  assert(context.includes('⟦s:1a2b3c4d⟧ — trigger phrase: "my calendar link"'));
  const reordered = buildUserContext({ ...request, dictionary: [...request.dictionary!].reverse() }, en);
  assertEquals(reordered, context);
  const minimal = buildUserContext({ dictationId: request.dictationId, transcript: "hi" }, resolveLanguage());
  assertStringIncludes(minimal, "Language: auto (");
  assertFalse(minimal.includes("<dictionary>"));
  assertFalse(minimal.includes("<snippets>"));
});

Deno.test("word counting", () => {
  assertEquals(countWords("Hello there, how are you?"), 5);
  assert(countWords("今日は良い天気です", "ja") >= 3);
  assertEquals(countWords("Book here ⟦s:1a2b3c4d⟧ thanks"), 3);
  assertEquals(countWords("Можешь скинуть отчёт до пятницы? Спасибо большое!", "ru-RU"), 7);
  // Intl.Segmenter splits hyphenated words («э-э», «кто-то», «пулл-реквест») on both the input
  // and the output side, so the length-ratio guard stays consistent.
  assertEquals(countWords("э-э ну короче можешь скинуть отчёт", "ru-RU"), 7);
  assertEquals(countWords("кто-то", "ru"), 2);
});

Deno.test("output guard", () => {
  assert(guardOutput("what's the best way to learn rust", "What's the best way to learn Rust?").ok);
  const answer = "The best way to learn Rust is to read the official book, then build small projects, " +
    "practice with exercises, and join the community forums to ask questions when you get stuck.";
  assertEquals(guardOutput("what's the best way to learn rust", answer), { ok: false, reason: "too_long" });
  assertEquals(guardOutput("um can you help me with this", ""), { ok: false, reason: "empty" });
  assertEquals(guardOutput("help me write an email", "I can't help with that."), {
    ok: false,
    reason: "assistant_reply",
  });
  assert(guardOutput("sure, let's do it", "Sure, let's do it.").ok);
  assert(guardOutput("here's the thing I wanted to say", "Here's the thing I wanted to say.").ok);
});

Deno.test("Russian assistant replies are rejected without relying on \\b", () => {
  const transcript = russianRequest.transcript;
  for (const reply of [
    "Конечно! Вот исправленный текст: можешь скинуть отчёт до пятницы? Спасибо большое!",
    "Конечно, вот очищенный вариант: можешь скинуть отчёт до пятницы?",
    "Извините, но я не могу помочь с этим запросом.",
    "Я не могу выполнить эту просьбу.",
    "Как ИИ, я не имею доступа к вашим файлам.",
    "Отличный вопрос! Отчёт можно скинуть до пятницы.",
  ]) {
    assertEquals(guardOutput(transcript, reply, "ru-RU"), { ok: false, reason: "assistant_reply" }, reply);
  }
  // Ordinary dictations that merely start with the same words pass.
  assert(guardOutput("вот этот файл нужно отправить", "Вот этот файл нужно отправить.", "ru-RU").ok);
  assert(guardOutput("конечно приду", "Конечно, приду.", "ru-RU").ok);
  assert(guardOutput("вот список покупок молоко хлеб и сыр", "Вот список покупок: молоко, хлеб и сыр.", "ru-RU").ok);
  assert(guardOutput("я не могу прийти завтра извини", "Я не могу прийти завтра, извини.", "ru-RU").ok);
});

Deno.test("a script change is rejected in both directions; mixed-script output passes", () => {
  const russian = "э-э ну короче можешь скинуть отчёт до пятницы вопросительный знак спасибо большое";
  assertEquals(guardOutput(russian, "Can you send me the report by Friday? Thanks a lot!", "ru-RU"), {
    ok: false,
    reason: "script_changed",
  });
  assertEquals(guardOutput(russian, "Mozhesh skinut otchyot do pyatnitsy? Spasibo bolshoe!", "ru-RU"), {
    ok: false,
    reason: "script_changed",
  });
  const english = "um so can you send me the report by friday thanks so much";
  assertEquals(guardOutput(english, "Можешь скинуть отчёт до пятницы? Спасибо большое!", "en-US"), {
    ok: false,
    reason: "script_changed",
  });
  assert(guardOutput(
    "я оставил комментарии к пулл реквесту в гитхабе и написал в телеграм что фича готова",
    "Я оставил комментарии к пулл-реквесту в GitHub и написал в Telegram, что фича готова.",
    "ru-RU",
  ).ok);
  assert(guardOutput("привет как дела", "Привет, как дела?", "ru-RU").ok, "too few letters to judge");
});

Deno.test("cyrillicShare", () => {
  assertEquals(cyrillicShare("Привет, как дела?"), null, "under 20 letters");
  assertEquals(cyrillicShare("Можешь скинуть отчёт до пятницы? Спасибо большое!"), 1);
  assertEquals(cyrillicShare("Can you send me the report by Friday?"), 0);
  const mixed = cyrillicShare("Пулл-реквест на GitHub и Telegram готов.");
  assert(mixed !== null && mixed > 0.3 && mixed < 0.7, String(mixed));
});

Deno.test("tidyOutput removes fences and wrapping quotes", () => {
  assertEquals(tidyOutput("```\nHello.\n```"), "Hello.");
  assertEquals(tidyOutput('"Hello there."'), "Hello there.");
  assertEquals(tidyOutput("“Hello there.”"), "Hello there.");
  assertEquals(tidyOutput('He said "hi" to me.'), 'He said "hi" to me.');
  assertEquals(tidyOutput("«Можешь скинуть отчёт до пятницы?»"), "Можешь скинуть отчёт до пятницы?");
  assertEquals(tidyOutput("„Можешь скинуть отчёт до пятницы?“"), "Можешь скинуть отчёт до пятницы?");
  assertEquals(tidyOutput("„Привет.”"), "Привет.");
  const quoted = "«Он сказал: «Я приду» — и ушёл.»";
  assertEquals(tidyOutput(quoted), quoted, "inner quotes of the same pair are the user's");
  const dialogue = "Он сказал: «Я приду» — и поставил точку в этом вопросе.";
  assertEquals(tidyOutput(dialogue), dialogue);
});
