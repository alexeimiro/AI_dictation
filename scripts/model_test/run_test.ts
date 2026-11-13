import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { type ClipEntry, emptyManifest, writeManifest } from "./clips.ts";
import { main } from "./run.ts";

function clip(id: string, group: ClipEntry["group"], reference: string): ClipEntry {
  return {
    id, file: `audio/${id}.wav`, source: "test", createdAt: null, audioMs: 1000, phoneText: reference, phoneLanguage: null,
    style: null, group, selected: true, excluded: false, reference, checked: true, tags: [], note: "",
  };
}

/** A work folder with two clips (a WAV each: nobody decodes them here) and a candidates file. */
async function folder(candidates: unknown): Promise<string> {
  const dir = await Deno.makeTempDir();
  await Deno.mkdir(`${dir}/audio`);
  for (const id of ["a", "b"]) await Deno.writeFile(`${dir}/audio/${id}.wav`, new Uint8Array(64));
  const manifest = emptyManifest();
  manifest.clips = [clip("a", "ru", "Привет, мир."), clip("b", "en", "Hello, world.")];
  await writeManifest(dir, manifest);
  await Deno.writeTextFile(`${dir}/candidates.json`, JSON.stringify(candidates));
  return dir;
}

async function lines(path: string) {
  return (await Deno.readTextFile(path)).trim().split("\n").map((line) => JSON.parse(line));
}

Deno.test("the runner: a warm-up, every clip, a report; a second run picks up where it stopped", async () => {
  let calls = 0;
  let failB = true;
  const server = Deno.serve({ hostname: "127.0.0.1", port: 0, onListen: () => {} }, async (request) => {
    calls++;
    const form = await request.formData();
    const name = (form.get("file") as File).name;
    assertEquals(name, "dictation.wav");
    // The second clip fails the first time round.
    const size = (form.get("file") as File).size;
    if (failB && calls === 3) return Response.json({ error: { type: "server_error" } }, { status: 500 });
    return Response.json({ text: size ? (calls % 2 ? "Hello, world." : "Привет, мир.") : "" }, { headers: { "x-processing-ms": "12" } });
  });
  const url = `http://127.0.0.1:${server.addr.port}`;
  const dir = await folder({ candidates: [{ name: "local", kind: "openai-compatible", model: "m", url, own: true }] });
  try {
    const log: string[] = [];
    await main(["--dir", dir], (line) => log.push(line));
    let results = await lines(`${dir}/results/local.jsonl`);
    assertEquals(results.map((line) => [line.clip, line.attempt, line.error === null]), [["a", 0, true], ["a", 1, true], ["b", 1, false]]);
    assertEquals(results[1].serverMs, 12);
    assertStringIncludes(await Deno.readTextFile(`${dir}/report.md`), "| local | yes |");

    // Again: only the clip that failed runs (after its warm-up).
    failB = false;
    await main(["--dir", dir], (line) => log.push(line));
    results = await lines(`${dir}/results/local.jsonl`);
    assertEquals(results.slice(3).map((line) => [line.clip, line.attempt]), [["b", 0], ["b", 1]]);

    // Nothing left: no calls at all.
    const before = calls;
    await main(["--dir", dir], (line) => log.push(line));
    assertEquals(calls, before);
    assert(log.some((line) => line.includes("every clip already has an answer")));

    // --rerun runs everything again.
    await main(["--dir", dir, "--rerun", "--repeat", "2"], (line) => log.push(line));
    results = await lines(`${dir}/results/local.jsonl`);
    assertEquals(results.slice(5).map((line) => [line.clip, line.attempt]), [["a", 0], ["a", 1], ["a", 2], ["b", 1], ["b", 2]]);
  } finally {
    await server.shutdown();
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("a candidate without its key is skipped, not the run; --dry-run sends nothing", async () => {
  const dir = await folder({ candidates: [{ name: "openai", kind: "openai", model: "gpt-transcribe", keyEnv: "MODEL_TEST_NO_SUCH_KEY" }] });
  try {
    const log: string[] = [];
    const result = await main(["--dir", dir, "--dry-run"], (line) => log.push(line));
    assertEquals(result.skipped, [{ name: "openai", why: "no MODEL_TEST_NO_SUCH_KEY in the environment" }]);
    assertEquals(await Deno.stat(`${dir}/results`).catch(() => null), null);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("--serve starts a candidate's own server, waits for it, and stops it afterwards", async () => {
  const port = 18000 + Math.floor(Math.random() * 1000);
  const script = await Deno.makeTempFile({ suffix: ".ts" });
  // A stand-in model server: answers health and transcriptions until it is told to stop.
  await Deno.writeTextFile(script, `
    Deno.serve({ hostname: "127.0.0.1", port: ${port}, onListen: () => console.log("listening") }, async (request) => {
      if (new URL(request.url).pathname === "/health") return Response.json({ ok: true });
      await request.formData();
      return Response.json({ text: "Hello, world." });
    });
    Deno.addSignalListener("SIGTERM", () => { console.log("stopping"); Deno.exit(0); });
  `);
  const dir = await folder({
    candidates: [{
      name: "served", kind: "openai-compatible", model: "m", url: `http://127.0.0.1:${port}`, own: true,
      serve: { command: [Deno.execPath(), "run", `--allow-net=127.0.0.1:${port}`, script], ready: `http://127.0.0.1:${port}/health`, timeoutMs: 30_000 },
    }],
  });
  try {
    const log: string[] = [];
    const result = await main(["--dir", dir, "--serve"], (line) => log.push(line));
    assertEquals(result.ran, ["served"]);
    assert(log.includes("served: server ready"));
    const serverLog = await Deno.readTextFile(`${dir}/results/served.server.log`);
    assertStringIncludes(serverLog, "listening");
    assertStringIncludes(serverLog, "stopping");
    // Stopped: nothing answers any more.
    const after = await fetch(`http://127.0.0.1:${port}/health`).then(() => "up", () => "down");
    assertEquals(after, "down");
  } finally {
    await Deno.remove(dir, { recursive: true });
    await Deno.remove(script);
  }
});
