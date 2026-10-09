import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type Anthropic from "npm:@anthropic-ai/sdk@0.132.1";
import { runCleanup } from "../_shared/cleanup.ts";
import { buildTranscriptMessage, buildUserContext, CLEANUP_RULES } from "../_shared/prompt.ts";
import { countWords, guardOutput, tidyOutput } from "../_shared/text.ts";
import { type CleanupRequest, parseCleanupRequest } from "../_shared/types.ts";

const request: CleanupRequest = {
  dictationId: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  transcript: "um so can you send me the report by friday",
  language: "en-US",
  style: "casual",
  dictionary: [{ term: "Valerio", misspelling: "valeria" }, { term: "iOS" }],
  snippets: [{ token: "⟦s:1a2b3c4d⟧", trigger: "my calendar link" }],
};

interface Captured {
  params?: Record<string, unknown>;
  options?: Record<string, unknown>;
}

/** Minimal stand-in for `client.beta.messages.stream(...)`. */
function fakeClient(reply: Record<string, unknown>, captured: Captured = {}): Anthropic {
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
              textHandlers.forEach((handler) => handler("x"));
              return Promise.resolve({
                model: "claude-opus-5-5",
                stop_reason: "end_turn",
                usage: { cache_read_input_tokens: 0 },
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

Deno.test("sends the agreed request shape to Claude", async () => {
  const captured: Captured = {};
  await runCleanup(fakeClient({}, captured), request, { model: "claude-opus-5-5", timeoutMs: 6000 });
  const params = captured.params!;
  assertEquals(params.model, "claude-opus-5-5");
  assertEquals(params.max_tokens, 16000);
  assertEquals(params.betas, ["server-side-fallback-2026-07-01"]);
  assertEquals(params.fallbacks, "default");
  assertEquals(params.output_config, { effort: "low" });
  assertFalse("thinking" in params, "Opus 5.5 rejects explicit thinking config; effort controls it");
  const system = params.system as Array<{ text: string; cache_control?: unknown }>;
  assertEquals(system.length, 2);
  assertEquals(system[0].text, CLEANUP_RULES);
  assertEquals(system[0].cache_control, { type: "ephemeral" });
  assertEquals(system[1].cache_control, { type: "ephemeral" });
  const messages = params.messages as Array<{ role: string; content: string }>;
  assertEquals(messages, [{ role: "user", content: buildTranscriptMessage(request.transcript) }]);
  assertEquals(captured.options, { timeout: 6000, maxRetries: 1 });
});

Deno.test("returns the cleaned text and timing", async () => {
  const outcome = await runCleanup(fakeClient({}), request, { model: "claude-opus-5-5", timeoutMs: 6000 });
  assertEquals(outcome.status, "cleaned");
  assertEquals(outcome.text, "Can you send me the report by Friday?");
  assert(outcome.ttftMs !== null);
});

Deno.test("refusals and truncation fall back to the transcript", async () => {
  for (const stopReason of ["refusal", "max_tokens"]) {
    const outcome = await runCleanup(
      fakeClient({ stop_reason: stopReason, content: [] }),
      request,
      { model: "claude-opus-5-5", timeoutMs: 6000 },
    );
    assertEquals(outcome.status, "raw");
    assertEquals(outcome.reason, stopReason);
    assertEquals(outcome.text, request.transcript);
  }
});

Deno.test("an answer instead of a cleanup is rejected", async () => {
  const outcome = await runCleanup(
    fakeClient({ content: [{ type: "text", text: "Sure! Here's a summary of the report you asked for." }] }),
    request,
    { model: "claude-opus-5-5", timeoutMs: 6000 },
  );
  assertEquals(outcome.status, "raw");
  assertEquals(outcome.reason, "assistant_reply");
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
    { model: "claude-opus-5-5", timeoutMs: 6000 },
  );
  assertEquals(outcome.text, "Hello there.");
});

Deno.test("the shared rules stay above the 512-token cache minimum", () => {
  // ~4 characters per token for English prose.
  assert(CLEANUP_RULES.length / 4 > 600, `rules are only ~${Math.round(CLEANUP_RULES.length / 4)} tokens`);
  assertFalse(/\$\{|\d{4}-\d{2}-\d{2}/.test(CLEANUP_RULES), "no volatile content in the cached prefix");
});

Deno.test("user context lists style, dictionary and snippets deterministically", () => {
  const context = buildUserContext(request);
  assert(context.includes("Language: en-US"));
  assert(context.includes("Casual:"));
  assert(context.includes("Valerio ← valeria"));
  assert(context.includes("\niOS\n"));
  assert(context.includes('⟦s:1a2b3c4d⟧ — trigger phrase: "my calendar link"'));
  const reordered = buildUserContext({ ...request, dictionary: [...request.dictionary!].reverse() });
  assertEquals(reordered, context);
  const minimal = buildUserContext({ dictationId: request.dictationId, transcript: "hi" });
  assertFalse(minimal.includes("<dictionary>"));
  assertFalse(minimal.includes("<snippets>"));
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
});

Deno.test("word counting", () => {
  assertEquals(countWords("Hello there, how are you?"), 5);
  assert(countWords("今日は良い天気です", "ja") >= 3);
  assertEquals(countWords("Book here ⟦s:1a2b3c4d⟧ thanks"), 3);
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
});

Deno.test("tidyOutput removes fences and wrapping quotes", () => {
  assertEquals(tidyOutput("```\nHello.\n```"), "Hello.");
  assertEquals(tidyOutput('"Hello there."'), "Hello there.");
  assertEquals(tidyOutput('He said "hi" to me.'), 'He said "hi" to me.');
});
