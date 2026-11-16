import { assertEquals } from "jsr:@std/assert@1";
import { buildCommandMessage, type CommandDeps, createCommandHandler, parseCommandMetadata, tidyCommandOutput } from "./command.ts";
import type { Preflight } from "./preflight.ts";

const ID = "6f1b8c2e-1a2b-4c3d-8e9f-0a1b2c3d4e5f";
const audio = new Uint8Array([1, 2, 3]) as Uint8Array<ArrayBuffer>;

Deno.test("metadata needs a UUID, a format and a selection", () => {
  assertEquals(parseCommandMetadata({ commandId: "x", format: "m4a", selection: "hi" }, audio).ok, false);
  assertEquals(parseCommandMetadata({ commandId: ID, format: "mp3", selection: "hi" }, audio).ok, false);
  assertEquals(parseCommandMetadata({ commandId: ID, format: "wav", selection: "  " }, audio).ok, false);
  assertEquals(parseCommandMetadata({ commandId: ID, format: "wav", selection: "x".repeat(8001) }, audio).ok, false);
  const ok = parseCommandMetadata({ commandId: ID.toUpperCase(), format: "wav", selection: "hi", language: "ru-RU", languages: ["en-US", "und", "ru"] }, audio);
  assertEquals(ok.ok && ok.value.commandId, ID);
  assertEquals(ok.ok && ok.value.language, "ru");
  assertEquals(ok.ok && ok.value.languageHints, ["en", "ru"]);
});

Deno.test("the message keeps the selection and the instruction apart", () => {
  assertEquals(buildCommandMessage("Hi team", "make it formal"),
    "<selection>\nHi team\n</selection>\n<instruction>\nmake it formal\n</instruction>");
});

Deno.test("echoed tags, fences and quotes come off", () => {
  assertEquals(tidyCommandOutput("<selection>\nShorter.\n</selection>", "Long text"), "Shorter.");
  assertEquals(tidyCommandOutput("```\nShorter.\n```", "Long text"), "Shorter.");
  assertEquals(tidyCommandOutput("“Shorter.”", "Long text"), "Shorter.");
  assertEquals(tidyCommandOutput("“Quoted”", "“Quoted original”"), "“Quoted”");
});

function deps(overrides: Partial<CommandDeps> = {}, preflight: Partial<Preflight> = {}): CommandDeps {
  return {
    config: { model: "gpt-test", effort: "low", transcribeModel: "gpt-transcribe", transcribeDeadlineMs: 1000, deadlineMs: 1000 },
    openAIKey: "sk-test",
    authenticate: () => Promise.resolve({ userId: "u1", isAnonymous: false }),
    preflight: () => Promise.resolve({ allowed: true, reason: null, plan: "pro", remaining: null, attempt: 1, ...preflight }),
    transcribe: () => Promise.resolve({ text: "make it shorter", languages: ["en"] }),
    rewrite: () => Promise.resolve({ text: "Short.", model: "gpt-test", usage: { input: 10, output: 2, cacheRead: 0, cacheWrite: 0 } }),
    recordUsage: () => Promise.resolve(),
    recordCost: () => Promise.resolve(),
    background: () => {},
    ...overrides,
  };
}

function request(selection = "A long sentence that says very little."): Request {
  const form = new FormData();
  form.append("metadata", JSON.stringify({ commandId: ID, format: "wav", selection }));
  form.append("audio", new Blob([new Uint8Array([1, 2, 3])]), "instruction.wav");
  return new Request("https://x/functions/v1/command", { method: "POST", body: form, headers: { "x-murmur-dictation": ID } });
}

Deno.test("a Pro user's selection comes back rewritten", async () => {
  const response = await createCommandHandler(deps())(request());
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals([body.status, body.text, body.instruction, body.words], ["rewritten", "Short.", "make it shorter", 1]);
});

Deno.test("Basic is told Command mode is Pro", async () => {
  const response = await createCommandHandler(deps({}, { plan: "free", remaining: 400 }))(request());
  assertEquals(response.status, 402);
  assertEquals((await response.json()).error, "pro_required");
});

Deno.test("nothing heard gives the selection back", async () => {
  const handler = createCommandHandler(deps({ transcribe: () => Promise.resolve({ text: " ", languages: [] }) }));
  const body = await (await handler(request("Keep me."))).json();
  assertEquals([body.status, body.text, body.reason], ["unchanged", "Keep me.", "nothing_heard"]);
});

Deno.test("anonymous and missing ids are refused", async () => {
  const anonymous = createCommandHandler(deps({ authenticate: () => Promise.resolve({ userId: "u", isAnonymous: true }) }));
  assertEquals((await anonymous(request())).status, 401);
  const noHeader = new Request("https://x/functions/v1/command", { method: "POST", body: new FormData() });
  assertEquals((await createCommandHandler(deps())(noHeader)).status, 400);
});

Deno.test("a model failure is a 502 that keeps the instruction", async () => {
  const handler = createCommandHandler(deps({ rewrite: () => Promise.reject(new Error("down")) }));
  const response = await handler(request());
  assertEquals(response.status, 502);
  assertEquals((await response.json()).instruction, "make it shorter");
});
