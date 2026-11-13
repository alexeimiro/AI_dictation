import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { type CostCall, costHost, createCostRecorder, textCall, textProvider, vouchedDictationId } from "./cost.ts";
import type { Caller } from "./http.ts";

const USER: Caller = { userId: "1b4e28ba-2fa1-41d2-883f-0016d3cca427", isAnonymous: false };
const DICTATION = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const SPEECH: CostCall = { kind: "speech", path: "upload", plan: "basic", provider: "openai", model: "gpt-transcribe", audioMs: 7800 };

/** A client whose `rpc` answers with `errors` in turn (none: success), and what it was asked. */
function fakeAdmin(errors: ({ code?: string } | null)[] = []) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      return Promise.resolve({ error: errors.shift() ?? null });
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

Deno.test("a text model's bill follows its name, as the call's routing does", () => {
  assertEquals(textProvider("claude-haiku-5-5"), "anthropic");
  assertEquals(textProvider("gpt-6.1-terra"), "openai");
  assertEquals(textProvider("gpt-6-astra-2026-09-01"), "openai");
});

Deno.test("a model's answer becomes a text call with every token count", () => {
  const outcome = { model: "gpt-6.1-terra-2026-10-01", usage: { input: 1950, output: 12, cacheRead: 1900, cacheWrite: 0 } };
  assertEquals(textCall(outcome, { path: "upload", plan: "pro" }), {
    kind: "text",
    path: "upload",
    plan: "pro",
    provider: "openai",
    model: "gpt-6.1-terra-2026-10-01",
    inputTokens: 1950,
    cachedTokens: 1900,
    cacheWriteTokens: 0,
    outputTokens: 12,
  });
});

Deno.test("a reply that names no model is billed as the one that was asked", () => {
  const outcome = { model: "", usage: { input: 10, output: 2, cacheRead: 0, cacheWrite: 0 } };
  const call = textCall(outcome, { path: "upload" }, "claude-haiku-5-5");
  assertEquals([call.model, call.provider], ["claude-haiku-5-5", "anthropic"]);
  assertEquals(textCall(outcome, { path: "upload" }).model, "unknown");
});

Deno.test("only an id the header vouches for is a dictation's own", () => {
  assertEquals(vouchedDictationId(DICTATION, DICTATION), DICTATION);
  assertEquals(vouchedDictationId(DICTATION, ` ${DICTATION.toUpperCase()} `), DICTATION);
  assertEquals(vouchedDictationId(DICTATION, null), null);
  assertEquals(vouchedDictationId(DICTATION, "3f2504e0-4f89-41d3-9a0c-0305e82c3301"), null);
  assertEquals(vouchedDictationId(null, DICTATION), null);
});

Deno.test("the home's name is MURMUR_HOST, and supabase without it", () => {
  assertEquals(costHost({ get: () => undefined }), "supabase");
  assertEquals(costHost({ get: () => "  " }), "supabase");
  assertEquals(costHost({ get: (name) => name === "MURMUR_HOST" ? "edge-fi" : undefined }), "edge-fi");
});

Deno.test("the calls go to record_cost in one round trip, each with this home's name", async () => {
  const { admin, calls } = fakeAdmin();
  const record = createCostRecorder(() => admin, { host: "edge-fi" });
  const text: CostCall = {
    kind: "text",
    path: "upload",
    provider: "openai",
    model: "gpt-6.1-terra",
    inputTokens: 1950,
    cachedTokens: 1900,
    cacheWriteTokens: 0,
    outputTokens: 12,
  };
  await record(USER, DICTATION, [SPEECH, text]);
  assertEquals(calls, [{
    name: "record_cost",
    args: {
      p_user: USER.userId,
      p_dictation: DICTATION,
      p_calls: [{ ...SPEECH, host: "edge-fi" }, { ...text, host: "edge-fi" }],
    },
  }]);
});

Deno.test("a call without a dictation of its own is recorded without one", async () => {
  const { admin, calls } = fakeAdmin();
  await createCostRecorder(() => admin, { host: "supabase" })(USER, null, [SPEECH]);
  assertEquals(calls[0].args.p_dictation, null);
});

Deno.test("nothing to record makes no round trip", async () => {
  const { admin, calls } = fakeAdmin();
  await createCostRecorder(() => admin, { host: "supabase" })(USER, DICTATION, []);
  assertEquals(calls, []);
});

Deno.test("the client is asked for on each call, not when the recorder is made", async () => {
  const { admin } = fakeAdmin();
  let asked = 0;
  const record = createCostRecorder(() => (asked++, admin), { host: "supabase" });
  assertEquals(asked, 0);
  await record(USER, DICTATION, [SPEECH]);
  await record(USER, DICTATION, [SPEECH]);
  assertEquals(asked, 2);
});

Deno.test("a database without record_cost is said once and left alone for ten minutes", async () => {
  const { admin, calls } = fakeAdmin([{ code: "PGRST202" }, { code: "PGRST202" }]);
  let now = 1_000_000;
  const warnings: string[] = [];
  const record = createCostRecorder(() => admin, { host: "supabase", now: () => now, warn: (message) => warnings.push(message) });

  await record(USER, DICTATION, [SPEECH]);
  await record(USER, DICTATION, [SPEECH]);
  now += 9 * 60_000;
  await record(USER, DICTATION, [SPEECH]);
  assertEquals([calls.length, warnings.length], [1, 1], "skipped while the function is missing");

  now += 2 * 60_000;
  await record(USER, DICTATION, [SPEECH]);
  assertEquals([calls.length, warnings.length], [2, 2], "asked again after ten minutes");

  now += 11 * 60_000;
  await record(USER, DICTATION, [SPEECH]);
  await record(USER, DICTATION, [SPEECH]);
  assertEquals([calls.length, warnings.length], [4, 2], "and recorded once the function is there");
});

Deno.test("any other failure is thrown for the caller's background handler to log", async () => {
  const { admin } = fakeAdmin([{ code: "23503" }, {}]);
  const record = createCostRecorder(() => admin, { host: "supabase" });
  await assertRejects(() => record(USER, DICTATION, [SPEECH]), Error, "record_cost failed: 23503");
  await assertRejects(() => record(USER, DICTATION, [SPEECH]), Error, "record_cost failed: unknown");
});
