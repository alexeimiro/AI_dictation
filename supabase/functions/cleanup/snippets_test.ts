import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { countedWords, runCleanup } from "../_shared/cleanup.ts";
import { markSnippets, repairSnippets } from "../_shared/snippets.ts";
import type { CleanupRequest, SnippetRef } from "../_shared/types.ts";

const email: SnippetRef = { token: "⟦s:1a2b3c4d⟧", trigger: "my email address" };
const link: SnippetRef = { token: "⟦s:2b3c4d5e⟧", trigger: "my calendar link" };
const home: SnippetRef = { token: "⟦s:3c4d5e6f⟧", trigger: "my home address" };
const courier: SnippetRef = { token: "⟦s:5e6f7a8b⟧", trigger: "мой адрес" };
const all = [email, link, home, courier];

Deno.test("a trigger said word for word is marked, whole phrase and in any capitals", () => {
  assertEquals(
    markSnippets("Hey, can you send the invoice to my email address by Friday? Thanks.", all),
    "Hey, can you send the invoice to ⟦s:1a2b3c4d⟧ by Friday? Thanks.",
  );
  assertEquals(
    markSnippets("My home address is where the parcel should go, so please confirm it.", all),
    "⟦s:3c4d5e6f⟧ is where the parcel should go, so please confirm it.",
  );
  assertEquals(
    markSnippets("Пришли курьера на Мой Адрес до пятницы, пожалуйста.", all),
    "Пришли курьера на ⟦s:5e6f7a8b⟧ до пятницы, пожалуйста.",
  );
  assertEquals(
    markSnippets("Please send the contract to my email address, and book a call using my calendar link.", all),
    "Please send the contract to ⟦s:1a2b3c4d⟧, and book a call using ⟦s:2b3c4d5e⟧.",
  );
});

Deno.test("other words are left alone: part of a trigger, another form of it, a longer word", () => {
  for (
    const text of [
      "I need to check my email before the meeting about the calendar on Friday.",
      "Скинь договор на мою почту и пришли курьера по моему адресу.",
      "Those are my email addresses.",
      "",
    ]
  ) {
    assertEquals(markSnippets(text, all), text);
  }
  assertEquals(markSnippets("Send it to my email address.", []), "Send it to my email address.");
});

Deno.test("the longer of two triggers wins, and «ё» matches «е»", () => {
  const work: SnippetRef = { token: "⟦s:aaaaaaaa⟧", trigger: "my work email" };
  const personal: SnippetRef = { token: "⟦s:bbbbbbbb⟧", trigger: "my email" };
  assertEquals(
    markSnippets("Write to my work email, not my email.", [personal, work]),
    "Write to ⟦s:aaaaaaaa⟧, not ⟦s:bbbbbbbb⟧.",
  );
  const report: SnippetRef = { token: "⟦s:cccccccc⟧", trigger: "мой отчёт" };
  assertEquals(markSnippets("Вот мой отчет за неделю.", [report]), "Вот ⟦s:cccccccc⟧ за неделю.");
});

Deno.test("a placeholder already in the text stays as it is, and a trigger of symbols is literal", () => {
  const letter: SnippetRef = { token: "⟦s:dddddddd⟧", trigger: "s" };
  assertEquals(markSnippets("Write to ⟦s:1a2b3c4d⟧.", [email, letter]), "Write to ⟦s:1a2b3c4d⟧.");
  const symbols: SnippetRef = { token: "⟦s:eeeeeeee⟧", trigger: "c++ (the best)" };
  assertEquals(markSnippets("I like C++ (the best) most.", [symbols]), "I like ⟦s:eeeeeeee⟧ most.");
});

Deno.test("a reply's stray trigger words beside their own placeholder go", () => {
  assertEquals(
    repairSnippets("My ⟦s:3c4d5e6f⟧ is where the parcel should go.", all),
    "⟦s:3c4d5e6f⟧ is where the parcel should go.",
  );
  assertEquals(repairSnippets("Send it to my home ⟦s:3c4d5e6f⟧ today.", all), "Send it to ⟦s:3c4d5e6f⟧ today.");
  assertEquals(repairSnippets("Send it to ⟦s:3c4d5e6f⟧ address today.", all), "Send it to ⟦s:3c4d5e6f⟧ today.");
  assertEquals(
    repairSnippets("Пришли курьера на мой адрес ⟦s:5e6f7a8b⟧ до пятницы.", all),
    "Пришли курьера на ⟦s:5e6f7a8b⟧ до пятницы.",
  );
  // Words that aren't the trigger's stay, and so does a part set off by a comma.
  assertEquals(repairSnippets("Send it to our ⟦s:3c4d5e6f⟧ today.", all), "Send it to our ⟦s:3c4d5e6f⟧ today.");
  assertEquals(repairSnippets("Is that my, ⟦s:3c4d5e6f⟧?", all), "Is that my, ⟦s:3c4d5e6f⟧?");
});

Deno.test("a trigger the reply still has as words is marked", () => {
  assertEquals(
    repairSnippets("Скинь договор на мою почту и пришли курьера на мой адрес.", all),
    "Скинь договор на мою почту и пришли курьера на ⟦s:5e6f7a8b⟧.",
  );
});

// --- The call itself ---

const signal = new AbortController().signal;

/** A Responses API reply with `text`. */
function reply(text: string): Record<string, unknown> {
  return {
    model: "gpt-6-astra-2026-09-01",
    status: "completed",
    incomplete_details: null,
    output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text, annotations: [] }] }],
    usage: { input_tokens: 1950, output_tokens: 12, input_tokens_details: { cached_tokens: 1900 } },
  };
}

function fakeFetch(body: Record<string, unknown>, captured: { input?: string } = {}) {
  return ((_url: string, init: RequestInit) => {
    const sent = JSON.parse(String(init.body)) as { input: Array<{ content: string }> };
    captured.input = sent.input[0].content;
    return Promise.resolve(Response.json(body));
  }) as unknown as typeof fetch;
}

function options(fetcher: typeof fetch) {
  return { model: "gpt-6-astra", effort: "low", apiKey: "sk-test", deadlineMs: 9000, signal, fetcher };
}

const request: CleanupRequest = {
  dictationId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  transcript: "My home address is where the parcel should go, so please confirm it.",
  language: "en-US",
  style: "professional",
  snippets: all,
};

Deno.test("the model reads the transcript with the snippets already marked", async () => {
  const captured: { input?: string } = {};
  const outcome = await runCleanup(
    request,
    options(fakeFetch(reply("⟦s:3c4d5e6f⟧ is where the parcel should go, so please confirm it."), captured)),
  );
  assertStringIncludes(captured.input!, "<transcript>\n⟦s:3c4d5e6f⟧ is where the parcel should go, so please confirm it.");
  assert(!captured.input!.includes("My home address"), "the trigger's words never reach the model");
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.text, "⟦s:3c4d5e6f⟧ is where the parcel should go, so please confirm it.");
  // The placeholder is no word: the snippet's text is the user's own and isn't counted.
  assertEquals(countedWords(outcome, request), 10);
});

Deno.test("a translation keeps the placeholder too", async () => {
  const captured: { input?: string } = {};
  const translation: CleanupRequest = {
    ...request,
    transcript: "скинь договор на мой адрес до пятницы пожалуйста",
    language: "ru-RU",
    targetLanguage: "en-US",
    style: "grammar",
  };
  const outcome = await runCleanup(
    translation,
    options(fakeFetch(reply("Please send the contract to ⟦s:5e6f7a8b⟧ by Friday."), captured)),
  );
  assertStringIncludes(captured.input!, "скинь договор на ⟦s:5e6f7a8b⟧ до пятницы пожалуйста");
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.text, "Please send the contract to ⟦s:5e6f7a8b⟧ by Friday.");
});

Deno.test("a reply that half replaced a trigger comes back repaired", async () => {
  const outcome = await runCleanup(
    { ...request, transcript: "Send the parcel to our office, not to the home address we used before, okay?" },
    options(fakeFetch(reply("Please send the parcel to our office, not to my ⟦s:3c4d5e6f⟧, as before."))),
  );
  assertEquals(outcome.text, "Please send the parcel to our office, not to ⟦s:3c4d5e6f⟧, as before.");
});

Deno.test("a reply the guards refuse returns the transcript as it was heard", async () => {
  // An answer instead of a cleanup: far longer than what was said.
  const answer = "Sure! " + "Here is a long answer about parcels and addresses. ".repeat(6);
  const outcome = await runCleanup(request, options(fakeFetch(reply(answer))));
  assertEquals(outcome.status, "raw");
  assertEquals(outcome.text, request.transcript, "the app inserts its own text from the words it heard");
  assertEquals(countedWords(outcome, request), 13);
});

Deno.test("nothing but a snippet was said: no model is asked, and the placeholder is the reply", async () => {
  const unasked = (() => Promise.reject(new Error("the model must not be asked"))) as unknown as typeof fetch;
  const alone: CleanupRequest = { ...request, transcript: "My home address, my email address." };
  const outcome = await runCleanup(alone, options(unasked));
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.text, "⟦s:3c4d5e6f⟧, ⟦s:1a2b3c4d⟧.");
  assertEquals(outcome.stopReason, "snippets_only");
  assertEquals(outcome.usage, { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 });
  assertEquals(countedWords(outcome, alone), 0, "a snippet's text is the user's own: nothing is counted");
  // A translation of one has nothing to translate either.
  const translated = await runCleanup({ ...alone, targetLanguage: "ru-RU" }, options(unasked));
  assertEquals(translated.text, "⟦s:3c4d5e6f⟧, ⟦s:1a2b3c4d⟧.");
});

Deno.test("a request without snippets is sent as it was", async () => {
  const captured: { input?: string } = {};
  const plain: CleanupRequest = { ...request, snippets: undefined };
  await runCleanup(plain, options(fakeFetch(reply("My home address is where the parcel should go."), captured)));
  assertStringIncludes(captured.input!, "<transcript>\nMy home address is where the parcel should go, so please confirm it.");
});
