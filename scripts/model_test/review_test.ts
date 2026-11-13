import { assert, assertEquals } from "jsr:@std/assert@1";
import { type ClipEntry, emptyManifest, readManifest, writeManifest } from "./clips.ts";
import { createReviewHandler } from "./review.ts";

const PORT = 8790;
const ORIGIN = `http://127.0.0.1:${PORT}`;

function clip(id: string, fields: Partial<ClipEntry> = {}): ClipEntry {
  return {
    id, file: `audio/${id}.wav`, source: "test", createdAt: null, audioMs: 3000, phoneText: "Привет, мир.", phoneLanguage: "ru",
    style: "verbatim", group: "ru", selected: true, excluded: false, reference: null, checked: false, tags: [], note: "", ...fields,
  };
}

async function folder(): Promise<string> {
  const dir = await Deno.makeTempDir();
  await Deno.mkdir(`${dir}/audio`);
  await Deno.mkdir(`${dir}/results`);
  await Deno.writeFile(`${dir}/audio/a.wav`, new Uint8Array(100).map((_, index) => index));
  const manifest = emptyManifest();
  manifest.clips = [clip("a"), clip("b", { group: "en", phoneText: "Hello world." })];
  await writeManifest(dir, manifest);
  return dir;
}

function call(handler: (request: Request) => Promise<Response>, path: string, init: RequestInit & { host?: string } = {}) {
  const headers = new Headers(init.headers);
  headers.set("host", init.host ?? `127.0.0.1:${PORT}`);
  if (init.body) headers.set("content-type", "application/json");
  return handler(new Request(`${ORIGIN}${path}`, { ...init, headers }));
}

Deno.test("only this Mac's own page may read or write", async () => {
  const dir = await folder();
  try {
    const handler = createReviewHandler(dir, PORT);
    assertEquals((await call(handler, "/api/clips", { host: "evil.example:8790" })).status, 403);
    const crossSite = await call(handler, "/api/clips/a", { method: "PUT", body: "{}", headers: { origin: "https://evil.example" } });
    assertEquals(crossSite.status, 403);
    const plain = await handler(new Request(`${ORIGIN}/api/clips/a`, { method: "PUT", body: "{}", headers: { host: `127.0.0.1:${PORT}`, "content-type": "text/plain" } }));
    assertEquals(plain.status, 415);
    assertEquals((await call(handler, "/api/clips")).status, 200);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("a correction is saved; checking needs a text; a private clip leaves the test", async () => {
  const dir = await folder();
  try {
    const handler = createReviewHandler(dir, PORT);
    const put = (body: unknown) => call(handler, "/api/clips/a", { method: "PUT", body: JSON.stringify(body), headers: { origin: ORIGIN } });
    let response = await put({ reference: "Привет, мир!", checked: true, group: "mix", tags: ["names"] });
    assertEquals(response.status, 200);
    const saved = await response.json();
    assertEquals(saved.counts.checked.total, 1);
    let stored = (await readManifest(dir)).clips.find((item) => item.id === "a")!;
    assertEquals([stored.reference, stored.checked, stored.group, stored.tags], ["Привет, мир!", true, "mix", ["names"]]);

    // An empty text can't stay checked.
    await put({ reference: "  " });
    stored = (await readManifest(dir)).clips.find((item) => item.id === "a")!;
    assertEquals(stored.checked, false);

    await put({ excluded: true });
    stored = (await readManifest(dir)).clips.find((item) => item.id === "a")!;
    assertEquals([stored.excluded, stored.selected], [true, false]);

    for (const bad of [{ group: "de" }, { tags: ["secret"] }, { phoneText: "x" }, { checked: "yes" }]) {
      assertEquals((await put(bad)).status, 400, JSON.stringify(bad));
    }
    assertEquals((await call(handler, "/api/clips/zzz", { method: "PUT", body: "{}" })).status, 404);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("the audio comes whole, or in the ranges Safari asks for", async () => {
  const dir = await folder();
  try {
    const handler = createReviewHandler(dir, PORT);
    const whole = await call(handler, "/audio/a");
    assertEquals([whole.status, whole.headers.get("content-type"), (await whole.arrayBuffer()).byteLength], [200, "audio/wav", 100]);
    const part = await call(handler, "/audio/a", { headers: { range: "bytes=10-19" } });
    assertEquals(part.status, 206);
    assertEquals(part.headers.get("content-range"), "bytes 10-19/100");
    assertEquals([...new Uint8Array(await part.arrayBuffer())], [10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);
    const tail = await call(handler, "/audio/a", { headers: { range: "bytes=-5" } });
    assertEquals([...new Uint8Array(await tail.arrayBuffer())], [95, 96, 97, 98, 99]);
    assertEquals((await call(handler, "/audio/a", { headers: { range: "bytes=200-" } })).status, 416);
    assertEquals((await call(handler, "/audio/b")).status, 404);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("the ballot never names a candidate; a vote is kept as texts; the reveal ranks them", async () => {
  const dir = await folder();
  try {
    const manifest = await readManifest(dir);
    for (const item of manifest.clips) Object.assign(item, { reference: item.phoneText, checked: true });
    await writeManifest(dir, manifest);
    const line = (candidate: string, clipId: string, text: string) =>
      JSON.stringify({ clip: clipId, candidate, attempt: 1, text, language: null, ms: 100, serverMs: null, audioMs: 3000, error: null, run: "r", at: "t" });
    await Deno.writeTextFile(`${dir}/results/alpha.jsonl`, [line("alpha", "a", "Привет, мир."), line("alpha", "b", "Hello world.")].join("\n") + "\n");
    await Deno.writeTextFile(`${dir}/results/beta.jsonl`, [line("beta", "a", "Привет мир"), line("beta", "b", "Hello world.")].join("\n") + "\n");
    const handler = createReviewHandler(dir, PORT);
    const response = await call(handler, "/api/ballot");
    const text = await response.text();
    assert(!text.includes("alpha") && !text.includes("beta"));
    const ballot = JSON.parse(text);
    assertEquals(ballot.progress, { total: 1, voted: 0, same: 1 });
    const a = ballot.clips.find((item: { id: string }) => item.id === "a");
    const best = a.options.find((option: { text: string }) => option.text === "Привет, мир.").id;
    const worse = a.options.find((option: { text: string }) => option.text === "Привет мир").id;
    const vote = await call(handler, "/api/votes/a", { method: "PUT", body: JSON.stringify({ best: [best], unusable: [worse] }) });
    assertEquals(vote.status, 200);
    const votes = JSON.parse(await Deno.readTextFile(`${dir}/votes.json`));
    assertEquals(votes.votes.a.best, ["Привет, мир."]);
    assertEquals(votes.votes.a.unusable, ["Привет мир"]);
    assertEquals((await call(handler, "/api/votes/a", { method: "PUT", body: JSON.stringify({ best: ["nope"] }) })).status, 400);
    const again = await (await call(handler, "/api/ballot")).json();
    assertEquals(again.clips.find((item: { id: string }) => item.id === "a").vote.best, [best]);
    const reveal = await (await call(handler, "/api/reveal")).json();
    assertEquals(reveal.rankedBy, "votes");
    assertEquals(reveal.candidates.find((item: { name: string }) => item.name === "alpha").votes.points, 100);
    assertEquals(reveal.candidates.find((item: { name: string }) => item.name === "beta").votes.points, 0);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});
