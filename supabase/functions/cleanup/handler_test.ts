import { assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { type CleanupDeps, createCleanupHandler } from "../_shared/cleanup_handler.ts";
import { cleanupConfig, translationConfig } from "../_shared/config.ts";
import type { CostCall } from "../_shared/cost.ts";
import type { Caller } from "../_shared/http.ts";

const ENDPOINT = "http://localhost/functions/v1/cleanup";
const DICTATION = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const USER: Caller = { userId: "1b4e28ba-2fa1-41d2-883f-0016d3cca427", isAnonymous: false };
const GUEST: Caller = { userId: "6fa459ea-ee8a-4ca4-894e-db77e160355e", isAnonymous: true };
const TRANSCRIPT = "можешь скинуть отчёт до пятницы спасибо большое";
const CLEANED = "Можешь скинуть отчёт до пятницы? Спасибо большое!";
const TRANSLATION = "Can you send the report by Friday? Thanks a lot!";

const cleanupBody = { dictationId: DICTATION, transcript: TRANSCRIPT, language: "ru-RU", style: "grammar" };
const translationBody = { ...cleanupBody, targetLanguage: "en-US" };

/** A Responses API reply with the given text. */
function responsesReply(text: string, model: string): Record<string, unknown> {
  return {
    model,
    status: "completed",
    incomplete_details: null,
    output: [{ type: "message", role: "assistant", content: [{ type: "output_text", text, annotations: [] }] }],
    usage: { input_tokens: 1950, output_tokens: 12, input_tokens_details: { cached_tokens: 1900, cache_write_tokens: 0 } },
  };
}

type Answer = { data?: unknown; error?: unknown };

interface Setup {
  /** `cleanup_preflight`'s answer over an allowed call on Basic with 870 words left. */
  preflight?: Answer;
  env?: Record<string, string>;
  /** The model's reply; by default the cleaned text, or the translation when the request has a target. */
  model?: (body: Record<string, unknown>) => Response | Promise<Response>;
  keys?: Record<string, string>;
  deps?: Partial<CleanupDeps>;
}

/** A handler on fakes, and everything it did. */
function setup(options: Setup = {}) {
  const recorded = {
    rpcs: [] as { name: string; args: Record<string, unknown> }[],
    fetches: [] as { path: string; body: Record<string, unknown> }[],
    costs: [] as { caller: Caller; dictationId: string; calls: CostCall[] }[],
    background: [] as PromiseLike<unknown>[],
    logs: [] as Record<string, unknown>[],
  };
  const answers: Record<string, Answer> = {
    cleanup_preflight: options.preflight ?? { data: { allowed: true, reason: null, plan: "basic", remaining: 870 } },
    record_usage: {},
  };
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      recorded.rpcs.push({ name, args });
      const answer = { data: null, error: null, ...answers[name] };
      return Object.assign(Promise.resolve(answer), { single: () => Promise.resolve(answer) });
    },
  } as unknown as Pick<SupabaseClient, "rpc">;
  const fetcher = ((input: string | URL, init: RequestInit = {}) => {
    const body = JSON.parse(String(init.body)) as Record<string, unknown>;
    recorded.fetches.push({ path: new URL(String(input)).pathname, body });
    const translated = JSON.stringify(body).includes("en-US");
    return Promise.resolve(
      options.model?.(body) ?? Response.json(responsesReply(translated ? TRANSLATION : CLEANED, String(body.model))),
    );
  }) as unknown as typeof fetch;

  const env = new Map(Object.entries(options.env ?? {}));
  const keys: Record<string, string> = options.keys ?? { OPENAI_API_KEY: "sk-test" };
  const handler = createCleanupHandler({
    admin,
    cleanup: cleanupConfig(env),
    translation: translationConfig(env),
    disabled: false,
    key: (name) => keys[name],
    authenticate: (request) => {
      const token = request.headers.get("Authorization");
      return Promise.resolve(token === "Bearer user" ? USER : token === "Bearer guest" ? GUEST : null);
    },
    recordCost: (caller, dictationId, calls) => {
      recorded.costs.push({ caller, dictationId, calls });
      return Promise.resolve();
    },
    background: (work) => void recorded.background.push(work),
    fetcher,
    worker: () => ({ cold: false, workerAgeMs: 41210, region: "eu-central-1", executionId: "worker-a" }),
    log: (line) => void recorded.logs.push(JSON.parse(line)),
    ...options.deps,
  });
  return { handler, recorded };
}

function request(body: Record<string, unknown> | string = cleanupBody, token: string | null = "user", method = "POST"): Request {
  return new Request(ENDPOINT, {
    method,
    headers: { "Content-Type": "application/json", ...(token === null ? {} : { Authorization: `Bearer ${token}` }) },
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  });
}

/** Runs `work` with console.error silenced: the failure paths log on purpose. */
async function quietly<T>(work: () => Promise<T>): Promise<T> {
  const original = console.error;
  console.error = () => {};
  try {
    return await work();
  } finally {
    console.error = original;
  }
}

const rpcNames = (recorded: { rpcs: { name: string }[] }) => recorded.rpcs.map((rpc) => rpc.name);

Deno.test("a cleanup is checked, written by the model, counted and costed, and answered in one reply", async () => {
  const { handler, recorded } = setup({ env: { CLEANUP_MODEL: "gpt-6.1-terra", CLEANUP_EFFORT: "none" } });
  const response = await handler(request());
  assertEquals(response.status, 200);
  const reply = await response.json();
  assertEquals(Object.keys(reply), ["text", "status", "reason", "targetLanguage", "words", "model", "ttftMs", "totalMs", "remaining", "timings"]);
  assertEquals([reply.text, reply.status, reply.reason, reply.targetLanguage, reply.words, reply.model, reply.remaining], [
    CLEANED, "cleaned", null, null, 7, "gpt-6.1-terra", 863,
  ]);

  assertEquals(rpcNames(recorded), ["cleanup_preflight", "record_usage"]);
  assertEquals(recorded.rpcs[0].args, { p_user: USER.userId }, "a signed-in caller keeps the SQL default of 40 a minute");
  assertEquals(recorded.rpcs[1].args, { p_user: USER.userId, p_dictation: DICTATION, p_words: 7 });
  assertEquals(recorded.fetches.map((fetched) => [fetched.path, fetched.body.model]), [["/v1/responses", "gpt-6.1-terra"]]);
  assertEquals(recorded.costs, [{
    caller: USER,
    dictationId: DICTATION,
    calls: [{
      kind: "text",
      path: "upload",
      plan: "basic",
      provider: "openai",
      model: "gpt-6.1-terra",
      inputTokens: 1950,
      cachedTokens: 1900,
      cacheWriteTokens: 0,
      outputTokens: 12,
    }],
  }]);
  assertEquals(recorded.background.length, 2);

  const [line] = recorded.logs;
  assertEquals([line.event, line.status, line.model, line.style, line.inWords, line.outWords, line.inputTokens, line.cachedTokens], [
    "cleanup", "cleaned", "gpt-6.1-terra", "grammar", 7, 7, 1950, 1900,
  ]);
  assertFalse(JSON.stringify(line).includes("отчёт"), "the log never holds what was said");
});

Deno.test("a translation runs with the translation settings and is counted in the language it is written in", async () => {
  const { handler, recorded } = setup({ env: { CLEANUP_MODEL: "gpt-6.1-terra", TRANSLATE_MODEL: "gpt-6-luna" } });
  const reply = await (await handler(request(translationBody))).json();
  assertEquals([reply.text, reply.status, reply.targetLanguage, reply.words, reply.model], [TRANSLATION, "cleaned", "en-US", 10, "gpt-6-luna"]);
  assertEquals(recorded.fetches[0].body.model, "gpt-6-luna");
  assertEquals(recorded.rpcs[1].args.p_words, 10);
  assertEquals(recorded.costs[0].calls[0].model, "gpt-6-luna");
});

Deno.test("an anonymous caller gets the tighter limit and the shorter transcript", async () => {
  const { handler, recorded } = setup();
  assertEquals((await handler(request(cleanupBody, "guest"))).status, 200);
  assertEquals(recorded.rpcs[0].args, { p_user: GUEST.userId, p_per_minute: 10 });

  const long = await handler(request({ ...cleanupBody, transcript: "слово ".repeat(1200) }, "guest"));
  assertEquals([long.status, await long.json()], [400, { error: "bad_request", detail: "transcript too long" }]);
  assertEquals(rpcNames(recorded), ["cleanup_preflight", "record_usage"], "refused before its preflight");
});

Deno.test("no caller is 401 and a body that isn't a request is 400, before any check", async () => {
  const { handler, recorded } = setup();
  assertEquals((await handler(request(cleanupBody, null))).status, 401);
  assertEquals((await handler(request("not json"))).status, 400);
  assertEquals((await handler(request({ transcript: TRANSCRIPT }))).status, 400);
  assertEquals(recorded.rpcs, []);
  assertEquals(recorded.fetches, []);
});

Deno.test("a refused preflight is 429 or 402, and one that fails is 503: nothing is sent to the model", async () => {
  const cases: [Answer, number, Record<string, unknown>][] = [
    [{ data: { allowed: false, reason: "rate_limited", plan: "basic", remaining: 870 } }, 429, { error: "rate_limited" }],
    [{ data: { allowed: false, reason: "limit_reached", plan: "basic", remaining: 0 } }, 402, { error: "limit_reached" }],
    [{ error: { code: "PGRST000" } }, 503, { error: "cleanup_unavailable" }],
    [{ data: null }, 503, { error: "cleanup_unavailable" }],
  ];
  for (const [preflight, status, body] of cases) {
    const { handler, recorded } = setup({ preflight });
    const response = await quietly(() => handler(request()));
    assertEquals([response.status, await response.json()], [status, body]);
    assertEquals(recorded.fetches, []);
    assertEquals(recorded.costs, []);
    assertEquals(recorded.background, []);
  }
});

Deno.test("an empty transcript is answered as it is, with no model call and nothing counted", async () => {
  const { handler, recorded } = setup();
  const reply = await (await handler(request({ ...cleanupBody, transcript: " … " }))).json();
  assertEquals([reply.text, reply.status, reply.reason, reply.words, reply.model, reply.remaining], ["", "raw", "empty", 0, null, 870]);
  assertEquals(recorded.fetches, []);
  assertEquals(rpcNames(recorded), ["cleanup_preflight"]);
  assertEquals(recorded.costs, []);
});

Deno.test("the kill switch and a missing key answer 503, and a failed model call 502", async () => {
  const off = setup({ deps: { disabled: true } });
  const disabled = await off.handler(request());
  assertEquals([disabled.status, await disabled.json()], [503, { error: "cleanup_unavailable" }]);
  assertEquals(off.recorded.rpcs, [], "before any database call");

  // A Claude model needs Anthropic's key, whatever OpenAI's is.
  const keyless = setup({ env: { CLEANUP_MODEL: "claude-haiku-5-5" }, keys: { OPENAI_API_KEY: "sk-test" } });
  assertEquals((await quietly(() => keyless.handler(request()))).status, 503);
  assertEquals(keyless.recorded.fetches, []);

  const failing = setup({ model: () => Response.json({ error: { code: "server_error" } }, { status: 500 }) });
  const response = await quietly(() => failing.handler(request()));
  assertEquals([response.status, await response.json()], [502, { error: "cleanup_unavailable" }]);
  assertEquals(rpcNames(failing.recorded), ["cleanup_preflight"], "nothing is counted");
  assertEquals(failing.recorded.costs, []);
});

Deno.test("an output the guard rejects comes back raw, counted as the transcript, and still costs its tokens", async () => {
  // The model answered the dictation instead of cleaning it up.
  const { handler, recorded } = setup({
    model: (body) => Response.json(responsesReply("Конечно! Вот исправленный текст: отчёт будет готов к пятнице.", String(body.model))),
  });
  const reply = await (await handler(request())).json();
  assertEquals([reply.status, reply.text], ["raw", TRANSCRIPT]);
  assertEquals(recorded.rpcs[1].args.p_words, 7);
  assertEquals(recorded.costs.length, 1);
});

Deno.test("OPTIONS answers with the CORS headers; any other method but POST gets 405", async () => {
  const { handler, recorded } = setup();
  const preflight = await handler(request(cleanupBody, "user", "OPTIONS"));
  assertEquals([preflight.status, preflight.headers.get("Access-Control-Allow-Methods")], [200, "POST, OPTIONS"]);
  assertEquals((await handler(request(cleanupBody, "user", "GET"))).status, 405);
  assertEquals(recorded.rpcs, []);
});

Deno.test("without a cost recorder the function works as before, with one task after the reply", async () => {
  const { handler, recorded } = setup({ deps: { recordCost: undefined } });
  assertEquals((await handler(request())).status, 200);
  assertEquals(recorded.background.length, 1);
});
