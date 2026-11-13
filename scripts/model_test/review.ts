// The model test's two pages, served on this Mac only:
//   /correct  the correction page: listen to each clip and write what you really said (the reference)
//   /vote     the blind-vote page: for each clip, pick the best of the candidates' texts, not knowing whose
// Your clips and texts never leave the Mac: it listens on 127.0.0.1, answers no other site, and
// writes only into the work folder (clips.json, votes.json).
//
//   deno run --allow-net=127.0.0.1 --allow-read --allow-write scripts/model_test/review.ts [--dir scripts/out/model_test] [--port 8790]
//
// Then open http://127.0.0.1:8790 in Safari or Chrome. Stop it with Ctrl+C: everything is saved as you go.
import { readCandidates } from "./candidates.ts";
import { audioType, type ClipEntry, countClips, DEFAULT_DIR, flag, GROUPS, type Group, readManifest, writeManifest } from "./clips.ts";
import { ballot, buildReport, loadResults, readVotes, textsOf, writeVotes } from "./report.ts";

const PAGES = new URL("./pages/", import.meta.url);
const EDITABLE = ["reference", "checked", "group", "selected", "excluded", "tags", "note"] as const;
const TAGS = new Set(["names", "numbers", "terms"]);

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });
}

/** A clip as the correction page shows it. */
function view(clip: ClipEntry) {
  return { ...clip, file: undefined, hasAudio: true };
}

/** The fields a PUT may change, checked; an error in plain words otherwise. */
export function applyEdit(clip: ClipEntry, body: Record<string, unknown>): string | null {
  for (const key of Object.keys(body)) {
    if (!(EDITABLE as readonly string[]).includes(key)) return `${key} can't be changed here`;
  }
  if ("reference" in body) {
    if (body.reference !== null && typeof body.reference !== "string") return "reference must be text";
    if (typeof body.reference === "string" && body.reference.length > 20_000) return "reference is too long";
    clip.reference = typeof body.reference === "string" ? body.reference.replace(/\r\n/g, "\n") : null;
  }
  for (const key of ["checked", "selected", "excluded"] as const) {
    if (key in body) {
      if (typeof body[key] !== "boolean") return `${key} must be true or false`;
      clip[key] = body[key] as boolean;
    }
  }
  if ("group" in body) {
    if (!GROUPS.includes(body.group as Group)) return "group must be ru, mix or en";
    clip.group = body.group as Group;
  }
  if ("tags" in body) {
    if (!Array.isArray(body.tags) || body.tags.some((tag) => typeof tag !== "string" || !TAGS.has(tag))) return "tags must be names, numbers or terms";
    clip.tags = [...new Set(body.tags as string[])];
  }
  if ("note" in body) {
    if (typeof body.note !== "string" || body.note.length > 2000) return "note must be short text";
    clip.note = body.note;
  }
  // A clip can't be checked with an empty reference, nor stay in the test once it is private.
  if (clip.checked && !(clip.reference ?? "").trim()) clip.checked = false;
  if (clip.excluded) clip.selected = false;
  clip.updatedAt = new Date().toISOString();
  return null;
}

/** The file's bytes, or the part a Range header asks for: Safari plays audio only with ranges. */
async function serveFile(path: string, request: Request): Promise<Response> {
  let file: Deno.FsFile;
  try {
    file = await Deno.open(path);
  } catch {
    return json({ error: "no audio for this clip" }, 404);
  }
  const { size } = await file.stat();
  const type = audioType(path);
  const range = request.headers.get("range")?.match(/^bytes=(\d*)-(\d*)$/);
  if (!range || (range[1] === "" && range[2] === "")) {
    return new Response(file.readable, { headers: { "Content-Type": type, "Content-Length": String(size), "Accept-Ranges": "bytes" } });
  }
  let start = range[1] === "" ? Math.max(0, size - Number(range[2])) : Number(range[1]);
  let end = range[1] !== "" && range[2] !== "" ? Number(range[2]) : size - 1;
  end = Math.min(end, size - 1);
  if (start > end || start >= size) {
    file.close();
    return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${size}` } });
  }
  start = Math.max(0, start);
  const length = end - start + 1;
  const bytes = new Uint8Array(length);
  await file.seek(start, Deno.SeekMode.Start);
  let read = 0;
  while (read < length) {
    const n = await file.read(bytes.subarray(read));
    if (n === null) break;
    read += n;
  }
  file.close();
  return new Response(bytes.subarray(0, read), {
    status: 206,
    headers: { "Content-Type": type, "Content-Length": String(read), "Content-Range": `bytes ${start}-${start + read - 1}/${size}`, "Accept-Ranges": "bytes" },
  });
}

async function page(name: string): Promise<Response> {
  const types: Record<string, string> = { html: "text/html; charset=utf-8", css: "text/css; charset=utf-8", js: "text/javascript; charset=utf-8" };
  try {
    const body = await Deno.readFile(new URL(name, PAGES));
    return new Response(body, { headers: { "Content-Type": types[name.split(".").pop()!] ?? "application/octet-stream", "Cache-Control": "no-store" } });
  } catch {
    return json({ error: "not_found" }, 404);
  }
}

/** The server's request handler for a work folder. Writes are serialized, so two quick saves never interleave. */
export function createReviewHandler(dir: string, port: number): (request: Request) => Promise<Response> {
  const origins = new Set([`http://127.0.0.1:${port}`, `http://localhost:${port}`]);
  const hosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
  let queue: Promise<unknown> = Promise.resolve();
  const serial = <T>(work: () => Promise<T>): Promise<T> => {
    const next = queue.then(work, work);
    queue = next.catch(() => {});
    return next;
  };

  return async (request) => {
    const url = new URL(request.url);
    // Only this Mac's own pages: another site in the browser can't read or change anything here.
    if (!hosts.has(request.headers.get("host") ?? "")) return json({ error: "forbidden" }, 403);
    const origin = request.headers.get("origin");
    if (request.method !== "GET" && request.method !== "HEAD") {
      if (origin !== null && !origins.has(origin)) return json({ error: "forbidden" }, 403);
      if (!request.headers.get("content-type")?.startsWith("application/json")) return json({ error: "json only" }, 415);
    }
    const path = url.pathname;

    if (path === "/") return Response.redirect(`${url.origin}/correct`, 302);
    // The browser asks for a tab icon; there is none.
    if (path === "/favicon.ico") return new Response(null, { status: 204 });
    if (path === "/correct") return await page("correct.html");
    if (path === "/vote") return await page("vote.html");
    if (path === "/common.css" || path === "/common.js") return await page(path.slice(1));

    if (path.startsWith("/audio/") && request.method === "GET") {
      const id = decodeURIComponent(path.slice("/audio/".length));
      const manifest = await readManifest(dir);
      const clip = manifest.clips.find((item) => item.id === id);
      if (!clip) return json({ error: "no such clip" }, 404);
      return await serveFile(`${dir}/${clip.file}`, request);
    }

    if (path === "/api/clips" && request.method === "GET") {
      const manifest = await readManifest(dir);
      return json({ targets: manifest.targets, counts: countClips(manifest.clips), clips: manifest.clips.map(view) });
    }

    const clipMatch = path.match(/^\/api\/clips\/([^/]+)$/);
    if (clipMatch && request.method === "PUT") {
      const id = decodeURIComponent(clipMatch[1]);
      const body = await request.json().catch(() => null);
      if (typeof body !== "object" || body === null || Array.isArray(body)) return json({ error: "body must be a JSON object" }, 400);
      return await serial(async () => {
        const manifest = await readManifest(dir);
        const clip = manifest.clips.find((item) => item.id === id);
        if (!clip) return json({ error: "no such clip" }, 404);
        const problem = applyEdit(clip, body as Record<string, unknown>);
        if (problem) return json({ error: problem }, 400);
        await writeManifest(dir, manifest);
        return json({ clip: view(clip), counts: countClips(manifest.clips) });
      });
    }

    if (path === "/api/ballot" && request.method === "GET") {
      const manifest = await readManifest(dir);
      const results = await loadResults(dir);
      const votes = await readVotes(dir);
      // The salt has to exist on disk before ids are handed out, or the next read would draw another.
      if (!await Deno.stat(`${dir}/votes.json`).catch(() => null)) await serial(() => writeVotes(dir, votes));
      const clips = await ballot(manifest, textsOf(results), votes);
      return json({
        candidates: results.size,
        clips,
        progress: {
          total: clips.filter((clip) => !clip.same).length,
          voted: clips.filter((clip) => !clip.same && clip.vote && !clip.vote.skipped).length,
          same: clips.filter((clip) => clip.same).length,
        },
      });
    }

    const voteMatch = path.match(/^\/api\/votes\/([^/]+)$/);
    if (voteMatch && request.method === "PUT") {
      const id = decodeURIComponent(voteMatch[1]);
      const body = await request.json().catch(() => null) as { best?: unknown; unusable?: unknown; skipped?: unknown } | null;
      const ids = (value: unknown) => Array.isArray(value) && value.every((item) => typeof item === "string") ? value as string[] : null;
      const best = ids(body?.best ?? []);
      const unusable = ids(body?.unusable ?? []);
      if (!best || !unusable || (body?.skipped !== undefined && typeof body.skipped !== "boolean")) {
        return json({ error: "best and unusable must be lists of option ids" }, 400);
      }
      return await serial(async () => {
        const manifest = await readManifest(dir);
        const votes = await readVotes(dir);
        const clip = (await ballot(manifest, textsOf(await loadResults(dir)), votes)).find((item) => item.id === id);
        if (!clip) return json({ error: "no such clip on the ballot" }, 404);
        const textOf = (option: string) => clip.options.find((item) => item.id === option)?.text;
        if ([...best, ...unusable].some((option) => textOf(option) === undefined)) return json({ error: "unknown option" }, 400);
        votes.votes[id] = {
          best: best.map((option) => textOf(option)!),
          unusable: unusable.map((option) => textOf(option)!),
          skipped: body?.skipped === true,
          at: new Date().toISOString(),
        };
        await writeVotes(dir, votes);
        return json({ ok: true });
      });
    }

    if (path === "/api/reveal" && request.method === "GET") {
      const manifest = await readManifest(dir);
      // The candidates file says which are your own models and their prices; without it, names only.
      const file = await readCandidates(`${dir}/candidates.json`).catch(() => null);
      const report = buildReport(manifest, await loadResults(dir), await readVotes(dir), file?.candidates ?? [], file?.ownCost ?? null);
      return json(report);
    }

    return json({ error: "not_found" }, 404);
  };
}

if (import.meta.main) {
  const dir = flag(Deno.args, "--dir") ?? DEFAULT_DIR;
  const port = Number(flag(Deno.args, "--port")) || 8790;
  const manifest = await readManifest(dir);
  if (manifest.clips.length === 0) {
    console.error(`No clips in ${dir}/clips.json yet: run pull_phone.ts first.`);
    Deno.exit(1);
  }
  Deno.serve({ hostname: "127.0.0.1", port, onListen: () => {} }, createReviewHandler(dir, port));
  console.log(`The correction page: http://127.0.0.1:${port}/correct`);
  console.log(`The vote page:       http://127.0.0.1:${port}/vote   (once the runner has results)`);
  console.log("Everything is saved as you go. Ctrl+C stops it.");
}
