// The model test's runner: every candidate in the candidates file turns every clip in the test into
// text, timed, and the report is written. Run it where the candidates are fast to reach: on the
// rented GPU (gpu_box.sh sets that up), which also keeps the services' calls out of Russia.
//
//   deno run --allow-net --allow-read --allow-write --allow-env --allow-run scripts/model_test/run.ts \
//     [--dir scripts/out/model_test] [--candidates <dir>/candidates.json] [--only a,b] [--skip c] \
//     [--serve] [--repeat 1] [--rerun] [--timeout 60000] [--dry-run]
//
// Keys come from the environment (each candidate's `keyEnv`): pass `--env-file=<file outside the
// repository>` to deno. A candidate whose key is missing is skipped, not the run.
//
// --serve     starts each candidate's own server (`serve` in the candidates file) before its clips and
//             stops it after, one at a time: one model on the GPU at a time, each with all of it.
//             The candidates without a server (the services) run after those, side by side.
// --repeat    times each clip that many times (the text of the first answer counts).
// --rerun     runs clips that already have an answer again; without it a run picks up where the last stopped.
// --dry-run   says what would run, and checks the keys, without sending anything.
//
// Each answer is appended to <dir>/results/<candidate>.jsonl as it comes (your clips' words stay in
// the work folder), and report.md / report.json are written at the end. One warm-up call per
// candidate comes first and isn't counted in the speed: it loads the model or opens connections.
import { type ClipAudio, clipAudio, CandidateError, type Transcriber, transcriberFor } from "./adapters.ts";
import { type Candidate, type CandidateFile, readCandidates } from "./candidates.ts";
import { DEFAULT_DIR, flag, inTest, type Manifest, readManifest } from "./clips.ts";
import { loadResults, readVotes, type ResultLine, writeReport } from "./report.ts";

interface RunOptions {
  dir: string;
  repeat: number;
  rerun: boolean;
  timeoutMs: number;
  run: string;
  log: (line: string) => void;
}

/** The clips that already have an answer from a candidate: a run without --rerun skips them. */
function answered(lines: ResultLine[] | undefined): Set<string> {
  return new Set((lines ?? []).filter((line) => line.attempt >= 1 && line.text !== null).map((line) => line.clip));
}

async function append(dir: string, line: ResultLine): Promise<void> {
  await Deno.writeTextFile(`${dir}/results/${line.candidate}.jsonl`, JSON.stringify(line) + "\n", { append: true });
}

/** One call, timed, as a result line; a failure is a line too, with its short reason. */
export async function attempt(
  transcribe: Transcriber,
  candidate: string,
  clip: ClipAudio,
  audioMs: number | null,
  number: number,
  options: Pick<RunOptions, "timeoutMs" | "run">,
): Promise<ResultLine> {
  const started = performance.now();
  const base = { clip: clip.id, candidate, attempt: number, audioMs, run: options.run };
  try {
    const result = await transcribe(clip, AbortSignal.timeout(options.timeoutMs));
    return {
      ...base,
      text: result.text,
      language: result.language,
      ms: Math.round(performance.now() - started),
      serverMs: result.serverMs,
      finalizeMs: result.detail?.finalizeMs ?? null,
      error: null,
      at: new Date().toISOString(),
    };
  } catch (error) {
    const reason = error instanceof CandidateError
      ? error.short
      : error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError")
      ? `timed out after ${options.timeoutMs} ms`
      : error instanceof TypeError
      ? `couldn't reach it (${error.message.split(":")[0]})`
      : error instanceof Error
      ? error.message.split("\n")[0].slice(0, 160)
      : String(error);
    return { ...base, text: null, language: null, ms: Math.round(performance.now() - started), serverMs: null, error: reason, at: new Date().toISOString() };
  }
}

/** Every clip of the test through one candidate: a warm-up, then each clip `repeat` times. */
export async function runCandidate(
  candidate: Candidate,
  transcribe: Transcriber,
  manifest: Manifest,
  done: Set<string>,
  options: RunOptions,
): Promise<{ answered: number; failed: number; skipped: number }> {
  await Deno.mkdir(`${options.dir}/results`, { recursive: true });
  const clips = manifest.clips.filter(inTest);
  const todo = options.rerun ? clips : clips.filter((clip) => !done.has(clip.id));
  const tally = { answered: 0, failed: 0, skipped: clips.length - todo.length };
  if (todo.length === 0) {
    options.log(`${candidate.name}: every clip already has an answer (use --rerun to run them again)`);
    return tally;
  }
  const load = (clip: (typeof todo)[number]) => clipAudio(clip.id, `${options.dir}/${clip.file}`);
  // The warm-up: loads the model, opens the connections. Recorded as attempt 0, never as a speed.
  const warm = await attempt(transcribe, candidate.name, await load(todo[0]), todo[0].audioMs, 0, options);
  await append(options.dir, warm);
  options.log(`${candidate.name}: warm-up ${warm.error ? `failed (${warm.error})` : `${warm.ms} ms`}`);
  for (const [index, clip] of todo.entries()) {
    const audio = await load(clip);
    for (let number = 1; number <= options.repeat; number++) {
      const line = await attempt(transcribe, candidate.name, audio, clip.audioMs, number, options);
      await append(options.dir, line);
      if (number === 1) line.text === null ? tally.failed++ : tally.answered++;
      options.log(`${candidate.name} ${index + 1}/${todo.length} ${clip.group} ${clip.id.slice(0, 13)}: ` +
        (line.error ? `failed (${line.error})` : `${line.ms} ms${line.serverMs !== null ? ` (its own ${line.serverMs} ms)` : ""}`));
    }
  }
  return tally;
}

// MARK: Servers

function expandHome(path: string): string {
  return path.startsWith("~/") ? `${Deno.env.get("HOME")}${path.slice(1)}` : path;
}

/** A candidate's own server, started and waited for; `stop` ends it (SIGTERM, then SIGKILL after 30 s). */
export async function startServer(candidate: Candidate, dir: string, log: (line: string) => void): Promise<{ stop(): Promise<void> }> {
  const serve = candidate.serve!;
  const [command, ...args] = serve.command.map(expandHome);
  await Deno.mkdir(`${dir}/results`, { recursive: true });
  const logPath = `${dir}/results/${candidate.name}.server.log`;
  const logFile = await Deno.open(logPath, { create: true, append: true });
  const process = new Deno.Command(command, {
    args,
    env: serve.env,
    stdin: "null",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  // Both streams into the server's log, never to this terminal.
  const piping = Promise.all([process.stdout, process.stderr].map(async (stream) => {
    for await (const chunk of stream) await logFile.write(chunk).catch(() => 0);
  }));
  let exited = false;
  const status = process.status.then((value) => {
    exited = true;
    return value;
  });
  const deadline = Date.now() + (serve.timeoutMs ?? 15 * 60_000);
  log(`${candidate.name}: starting its server (log: ${logPath})`);
  let ready = false;
  while (!ready && !exited && Date.now() < deadline) {
    try {
      const response = await fetch(serve.ready, { signal: AbortSignal.timeout(5000) });
      await response.body?.cancel();
      ready = response.ok;
    } catch {
      // Not listening yet.
    }
    if (!ready) await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  const stop = async () => {
    if (!exited) {
      try {
        process.kill("SIGTERM");
      } catch {
        // Already gone.
      }
      const killer = setTimeout(() => {
        try {
          process.kill("SIGKILL");
        } catch {
          // Already gone.
        }
      }, 30_000);
      await status;
      clearTimeout(killer);
    }
    await piping.catch(() => {});
    logFile.close();
  };
  if (!ready) {
    await stop();
    const tail = (await Deno.readTextFile(logPath).catch(() => "")).trim().split("\n").slice(-8).join("\n");
    throw new Error(`${candidate.name}'s server ${exited ? "exited" : "wasn't ready in time"}. Its last lines:\n${tail}`);
  }
  log(`${candidate.name}: server ready`);
  return { stop };
}

// MARK: Main

export interface MainResult {
  ran: string[];
  skipped: { name: string; why: string }[];
}

export async function main(args: string[], log: (line: string) => void = console.log): Promise<MainResult> {
  const dir = flag(args, "--dir") ?? DEFAULT_DIR;
  const file: CandidateFile = await readCandidates(flag(args, "--candidates") ?? `${dir}/candidates.json`);
  const only = flag(args, "--only")?.split(",").map((name) => name.trim()).filter(Boolean);
  const skip = new Set(flag(args, "--skip")?.split(",").map((name) => name.trim()) ?? []);
  const unknown = (only ?? []).filter((name) => !file.candidates.some((candidate) => candidate.name === name));
  if (unknown.length > 0) throw new Error(`no candidate named ${unknown.join(", ")} in the candidates file`);
  const options: RunOptions = {
    dir,
    repeat: Math.max(1, Number(flag(args, "--repeat")) || 1),
    rerun: args.includes("--rerun"),
    timeoutMs: Math.max(1000, Number(flag(args, "--timeout")) || 60_000),
    run: new Date().toISOString(),
    log,
  };
  const manifest = await readManifest(dir);
  const clips = manifest.clips.filter(inTest);
  if (clips.length === 0) throw new Error(`no clips in the test in ${dir}/clips.json: pull them first (pull_phone.ts)`);
  const unchecked = clips.filter((clip) => !clip.checked).length;
  log(`${clips.length} clips in the test${unchecked ? ` (${unchecked} not checked yet: they run, but only checked ones are scored)` : ""}.`);

  const chosen = file.candidates.filter((candidate) => (!only || only.includes(candidate.name)) && !skip.has(candidate.name));
  const result: MainResult = { ran: [], skipped: [] };
  const ready: { candidate: Candidate; transcribe: Transcriber }[] = [];
  for (const candidate of chosen) {
    try {
      const transcribe = transcriberFor(candidate, {
        languageHints: file.languageHints ?? ["ru", "en"],
        keywords: file.keywords ?? [],
        env: (name) => Deno.env.get(name),
      });
      ready.push({ candidate, transcribe });
    } catch (error) {
      const why = error instanceof CandidateError ? error.short : String(error);
      result.skipped.push({ name: candidate.name, why });
      log(`${candidate.name}: skipped, ${why}`);
    }
  }
  const results = await loadResults(dir);
  if (args.includes("--dry-run")) {
    for (const { candidate } of ready) {
      const done = answered(results.get(candidate.name));
      const todo = options.rerun ? clips.length : clips.filter((clip) => !done.has(clip.id)).length;
      log(`${candidate.name} (${candidate.kind}, ${candidate.model}${candidate.url ? ` at ${candidate.url}` : ""}): ` +
        `${todo} clips to run${candidate.serve && args.includes("--serve") ? ", its server started first" : ""}`);
    }
    return result;
  }

  const serve = args.includes("--serve");
  const served = ready.filter(({ candidate }) => serve && candidate.serve);
  const direct = ready.filter((item) => !served.includes(item));
  // One server at a time, each with the whole GPU; then the rest, side by side.
  for (const { candidate, transcribe } of served) {
    let server: { stop(): Promise<void> } | null = null;
    try {
      server = await startServer(candidate, dir, log);
      const tally = await runCandidate(candidate, transcribe, manifest, answered(results.get(candidate.name)), options);
      log(`${candidate.name}: ${tally.answered} answered, ${tally.failed} failed, ${tally.skipped} already done`);
      result.ran.push(candidate.name);
    } catch (error) {
      const why = error instanceof Error ? error.message : String(error);
      result.skipped.push({ name: candidate.name, why });
      log(`${candidate.name}: ${why}`);
    } finally {
      await server?.stop();
    }
  }
  await Promise.all(direct.map(async ({ candidate, transcribe }) => {
    const tally = await runCandidate(candidate, transcribe, manifest, answered(results.get(candidate.name)), options);
    log(`${candidate.name}: ${tally.answered} answered, ${tally.failed} failed, ${tally.skipped} already done`);
    result.ran.push(candidate.name);
  }));

  const report = await writeReport(dir, manifest, await loadResults(dir), await readVotes(dir), file.candidates, file.ownCost ?? null);
  log("");
  log(report.verdict);
  log(`The report: ${dir}/report.md. Vote blind on the vote page: ` +
    `deno run --allow-net=127.0.0.1 --allow-read --allow-write scripts/model_test/review.ts --dir ${dir}  (then /vote)`);
  return result;
}

if (import.meta.main) {
  try {
    await main(Deno.args);
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    Deno.exit(1);
  }
}
