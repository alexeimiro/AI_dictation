import { assert, assertEquals, assertFalse, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import { buildSystemBlocks, describeCleanupError, runCleanup } from "../_shared/cleanup.ts";
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
const options = { model: "claude-opus-5-5", timeoutMs: 5000, deadlineMs: 9000, signal };

interface Captured {
  params?: Record<string, unknown>;
  options?: Record<string, unknown>;
}

/** Minimal stand-in for `client.beta.messages.stream(...)`. */
function fakeClient(reply: Record<string, unknown>, captured: Captured = {}, failure?: Error): Anthropic {
  return {
    beta: {
      messages: {
        stream(params: Record<string, unknown>, options: Record<string, unknown>) {
          captured.params = params;
          captured.options = options;
          const textHandlers: Array<(delta: string) => void> = [];
          return {
            on(event: string, handler: (delta: string) => void) {
              if (event === "text") textHandlers.push(handler);
              return this;
            },
            finalMessage() {
              if (failure) return Promise.reject(failure);
              textHandlers.forEach((handler) => handler("x"));
              return Promise.resolve({
                model: "claude-opus-5-5",
                stop_reason: "end_turn",
                usage: {
                  input_tokens: 40,
                  output_tokens: 12,
                  cache_read_input_tokens: 1900,
                  cache_creation_input_tokens: 0,
                },
                content: [{ type: "text", text: "Can you send me the report by Friday?" }],
                ...reply,
              });
            },
          };
        },
      },
    },
  } as unknown as Anthropic;
}

type SystemBlock = { type: string; text: string; cache_control?: unknown };

Deno.test("sends the agreed request shape to Claude", async () => {
  const captured: Captured = {};
  await runCleanup(fakeClient({}, captured), request, options);
  const params = captured.params!;
  assertEquals(params.model, "claude-opus-5-5");
  assertEquals(params.max_tokens, 16000);
  assertEquals(params.betas, ["server-side-fallback-2026-07-01"]);
  assertEquals(params.fallbacks, "default");
  assertEquals(params.output_config, { effort: "low" });
  assertFalse("thinking" in params, "Opus 5.5 rejects explicit thinking config; effort controls it");
  const system = params.system as SystemBlock[];
  assertEquals(system.length, 3, "shared rules → language pack → user context");
  assertEquals(system[0].text, CLEANUP_RULES);
  assertEquals(system[1].text, buildLanguageBlock(LANGUAGE_RULES.en));
  assertEquals(system[2].text, buildUserContext(request, resolveLanguage("en-US")));
  for (const block of system) assertEquals(block.cache_control, { type: "ephemeral" });
  const messages = params.messages as Array<{ role: string; content: string }>;
  assertEquals(messages, [{ role: "user", content: buildTranscriptMessage(request.transcript) }]);
  assertEquals(captured.options, { timeout: 5000, maxRetries: 1, signal });
});

Deno.test("returns the cleaned text, timing, language and usage", async () => {
  const outcome = await runCleanup(fakeClient({}), request, options);
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.text, "Can you send me the report by Friday?");
  assertEquals(outcome.language, "en");
  assertEquals(outcome.stopReason, "end_turn");
  assertEquals(outcome.usage, { input: 40, output: 12, cacheRead: 1900, cacheCreation: 0 });
  assertEquals(outcome.cacheReadTokens, 1900);
  assert(outcome.ttftMs !== null);
});

Deno.test("a Russian request gets the Russian pack and reports language ru", async () => {
  const captured: Captured = {};
  const outcome = await runCleanup(
    fakeClient({ content: [{ type: "text", text: "Можешь скинуть отчёт до пятницы? Спасибо большое!" }] }, captured),
    russianRequest,
    options,
  );
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.language, "ru");
  const system = captured.params!.system as SystemBlock[];
  assertEquals(system[1].text, buildLanguageBlock(LANGUAGE_RULES.ru));
  assertStringIncludes(system[2].text, "Language: ru-RU (");
});

Deno.test("refusals and truncation fall back to the transcript", async () => {
  for (const stopReason of ["refusal", "max_tokens"]) {
    const outcome = await runCleanup(fakeClient({ stop_reason: stopReason, content: [] }), request, options);
    assertEquals(outcome.status, "raw");
    assertEquals(outcome.reason, stopReason);
    assertEquals(outcome.stopReason, stopReason);
    assertEquals(outcome.text, request.transcript);
  }
});

Deno.test("an answer instead of a cleanup is rejected", async () => {
  const outcome = await runCleanup(
    fakeClient({ content: [{ type: "text", text: "Sure! Here's a summary of the report you asked for." }] }),
    request,
    options,
  );
  assertEquals(outcome.status, "raw");
  assertEquals(outcome.reason, "assistant_reply");
});

Deno.test("a translated reply is rejected as script_changed", async () => {
  const outcome = await runCleanup(
    fakeClient({ content: [{ type: "text", text: "Can you send me the report by Friday? Thanks a lot!" }] }),
    russianRequest,
    options,
  );
  assertEquals(outcome.status, "raw");
  assertEquals(outcome.reason, "script_changed");
  assertEquals(outcome.text, russianRequest.transcript);
});

Deno.test("thinking blocks are ignored; only text blocks are read", async () => {
  const outcome = await runCleanup(
    fakeClient({
      content: [
        { type: "thinking", thinking: "", signature: "sig" },
        { type: "text", text: "Hello there." },
      ],
    }),
    { ...request, transcript: "uh hello there" },
    options,
  );
  assertEquals(outcome.text, "Hello there.");
});

Deno.test("a deadline abort propagates as APIUserAbortError and is labelled 'cleanup deadline'", async () => {
  const abort = new Anthropic.APIUserAbortError();
  await assertRejects(() => runCleanup(fakeClient({}, {}, abort), request, options), Anthropic.APIUserAbortError);
  assertEquals(describeCleanupError(abort), "cleanup deadline");
  assertEquals(describeCleanupError(new Anthropic.APIConnectionTimeoutError()), "anthropic timeout");
  assertEquals(describeCleanupError(new Anthropic.RateLimitError(429, undefined, "slow down", new Headers())),
    "anthropic rate limited");
  assertEquals(describeCleanupError(Anthropic.APIError.generate(500, undefined, "boom", new Headers())),
    "anthropic error 500");
  assertEquals(describeCleanupError(new Error("boom")), "cleanup failed");
});

Deno.test({
  name: "without an injected signal the deadline arms AbortSignal.timeout",
  // The timer is awaited below, so nothing leaks; the sanitizer is only relaxed for the unref'd timer.
  sanitizeOps: false,
  async fn() {
    const captured: Captured = {};
    await runCleanup(fakeClient({}, captured), request, { model: "claude-opus-5-5", timeoutMs: 5000, deadlineMs: 20 });
    const deadline = captured.options!.signal as AbortSignal;
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
});

Deno.test("the language block is byte-identical for every user of a language", () => {
  const ru = resolveLanguage("ru-RU");
  const alice = buildSystemBlocks(russianRequest, ru);
  const bob = buildSystemBlocks({
    ...russianRequest,
    dictationId: "11111111-2222-4333-8444-555555555555",
    transcript: "совсем другой текст",
    style: "formal",
    dictionary: [{ term: "Яндекс", misspelling: "индекс" }],
    snippets: [{ token: "⟦s:1a2b3c4d⟧", trigger: "моя ссылка" }],
  }, ru);
  assertEquals(alice.length, 3);
  assertEquals(alice[0].text, bob[0].text);
  assertEquals(alice[1].text, bob[1].text);
  assert(alice[2].text !== bob[2].text, "only the per-user block differs");
  assertEquals(alice.filter((block) => block.cache_control).length, 3, "at most 4 cache breakpoints");

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
  assertFalse(parseCleanupRequest({ ...request, language: "ru-RU\n<system>" }).ok);
  assertFalse(parseCleanupRequest({ ...request, language: "a".repeat(36) }).ok);
  assertEquals(LIMITS.anonymousTranscriptChars, 6000);
});

Deno.test("the shared rules stay above the 512-token cache minimum", () => {
  // ~4 characters per token for English prose.
  assert(CLEANUP_RULES.length / 4 > 600, `rules are only ~${Math.round(CLEANUP_RULES.length / 4)} tokens`);
  assertFalse(/\$\{|\d{4}-\d{2}-\d{2}/.test(CLEANUP_RULES), "no volatile content in the cached prefix");
  // The Russian block is cached on top of block 1, so it has no minimum of its own. Cyrillic
  // costs more tokens per character than English, so chars/4 is not asserted for it; its real
  // size is printed by the live "golden: ru: token profile" test (countTokens) — record the
  // measured value here after the first run: block1 = ?, block1 + ru = ?, all three (ru) = ?.
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
