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
import {
  buildLanguageBlock,
  buildTranscriptMessage,
  buildUserContext,
  CLEANUP_RULES,
  LANGUAGE_RULES,
  resolveLanguage,
} from "../_shared/prompt.ts";
import { countWords, cyrillicShare, guardOutput, tidyOutput } from "../_shared/text.ts";
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
  assertEquals(outcome.usage, { input: 1950, output: 12, cacheRead: 1900, cacheCreation: 0 });
  assertEquals(outcome.cacheReadTokens, 1900);
  assertEquals(outcome.ttftMs, null);
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

Deno.test("translation requests name the target and allow the expected script change", async () => {
  const translatedRequest: CleanupRequest = { ...russianRequest, targetLanguage: "tr-TR" };
  const captured: Captured = {};
  const outcome = await runCleanup(
    translatedRequest,
    options(fakeFetch(reply("Raporu cuma gününe kadar gönderebilir misin? Çok teşekkürler!"), captured)),
  );
  assertEquals(outcome.status, "cleaned");
  const instructions = captured.body!.instructions as string;
  assertStringIncludes(instructions, "Source language: ru-RU.");
  assertStringIncludes(instructions, "Translation target: Turkish");
  assertStringIncludes(instructions, "(tr-TR). Translation mode is ON.");
  assertStringIncludes(instructions, "never return the source-language transcript");
  assertNotMatch(instructions, /Language: ru-RU \(keep the output in the language that was spoken\)/);
  assert(guardOutput(russianRequest.transcript, outcome.text, "ru-RU", true).ok);
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
