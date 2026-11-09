// Compares models on the text step (Word for word, Improve my grammar, translation) with the
// prompt and output guards the `cleanup` function uses. Costs money: it calls OpenAI and
// Anthropic. Writes results.json and report.md to --out.
//
//   deno run --allow-env --allow-net --allow-read --allow-write --env-file=supabase/functions/.env \
//     scripts/bench/text_bench.ts --out <dir> [--models gpt-6-luna,claude-haiku-5-5:low] [--repeat 3]
//     [--only grammar.en] [--no-judge] [--dry-run]
//
// Needs OPENAI_API_KEY (OpenAI models and the gpt-6-astra judge) and ANTHROPIC_API_KEY (Claude
// models and the claude-opus-5-5 judge).
import Anthropic from "npm:@anthropic-ai/sdk@1.2.0";
import { runCleanup } from "../../supabase/functions/_shared/cleanup.ts";
import type { CleanupRequest } from "../../supabase/functions/_shared/types.ts";
import { type BenchCase, CASES, check } from "./cases.ts";
import {
  type Grade,
  GRADE_SCHEMA,
  JUDGE_RULES,
  type JudgeItem,
  judgeMessage,
  judgeWithClaude,
  type ModelRun,
  parseGrade,
  runClaudeCleanup,
} from "./claude.ts";
import { costOf, DEFAULT_MODELS, mean, type ModelSpec, parseModel, percentile, pool, type Usage } from "./models.ts";

interface Flags {
  out?: string;
  models: ModelSpec[];
  repeat: number;
  only?: string;
  judge: boolean;
  dryRun: boolean;
}

function parseFlags(args: string[]): Flags {
  const flags: Flags = { models: DEFAULT_MODELS.map(parseModel), repeat: 3, judge: true, dryRun: false };
  for (let index = 0; index < args.length; index++) {
    const value = () => args[++index];
    switch (args[index]) {
      case "--out": flags.out = value(); break;
      case "--models": flags.models = value().split(",").map(parseModel); break;
      case "--repeat": flags.repeat = Math.max(1, Number(value()) || 1); break;
      case "--only": flags.only = value(); break;
      case "--no-judge": flags.judge = false; break;
      case "--dry-run": flags.dryRun = true; break;
      default: throw new Error(`unknown flag ${args[index]}`);
    }
  }
  return flags;
}

interface RunRecord {
  model: string;
  caseId: string;
  repeat: number;
  status: string;
  reason?: string;
  text: string;
  totalMs: number;
  usage: Usage;
  cost: number | null;
  problems: string[];
  grades: { astra?: Grade | null; opus?: Grade | null };
}

function requestFor(benchCase: BenchCase): CleanupRequest {
  return {
    dictationId: crypto.randomUUID(),
    transcript: benchCase.transcript,
    language: benchCase.language,
    targetLanguage: benchCase.targetLanguage,
    style: benchCase.style,
  };
}

async function runOne(spec: ModelSpec, benchCase: BenchCase, repeat: number, keys: Keys, anthropic: Anthropic | null):
  Promise<RunRecord> {
  const base = { model: spec.label, caseId: benchCase.id, repeat, grades: {} };
  try {
    let run: ModelRun;
    const request = requestFor(benchCase);
    if (spec.provider === "anthropic") {
      run = await runClaudeCleanup(anthropic!, request, spec.model, spec.effort);
    } else {
      const outcome = await runCleanup(request, {
        model: spec.model, effort: spec.effort, apiKey: keys.openai!, deadlineMs: 30_000,
      });
      run = {
        text: outcome.text, status: outcome.status, reason: outcome.reason, totalMs: outcome.totalMs,
        usage: {
          // OpenAI counts cached and written tokens inside input_tokens; Claude counts them apart.
          uncached: Math.max(0, outcome.usage.input - outcome.usage.cacheRead - outcome.usage.cacheWrite),
          cacheRead: outcome.usage.cacheRead,
          cacheWrite: outcome.usage.cacheWrite,
          output: outcome.usage.output,
        },
      };
    }
    return { ...base, ...run, cost: costOf(spec, run.usage), problems: check(benchCase, run) };
  } catch (error) {
    const reason = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    return {
      ...base, status: "error", reason, text: "", totalMs: 0,
      usage: { uncached: 0, cacheRead: 0, cacheWrite: 0, output: 0 }, cost: null, problems: ["error"],
    };
  }
}

/** gpt-6-astra as a judge, with a structured reply, as the Responses API takes one. */
async function judgeWithAstra(apiKey: string, item: JudgeItem): Promise<Grade | null> {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      model: "gpt-6-astra",
      instructions: JUDGE_RULES,
      input: [{ role: "user", content: judgeMessage(item) }],
      reasoning: { effort: "low" },
      text: { format: { type: "json_schema", name: "grade", schema: GRADE_SCHEMA, strict: true } },
      max_output_tokens: 4000,
      store: false,
    }),
    signal: AbortSignal.timeout(60_000),
  });
  if (!response.ok) return null;
  const reply = await response.json() as {
    output?: Array<{ type?: string; content?: Array<{ type?: string; text?: string }> }>;
  };
  const text = (reply.output ?? [])
    .filter((item) => item.type === "message")
    .flatMap((item) => item.content ?? [])
    .filter((part) => part.type === "output_text")
    .map((part) => part.text ?? "")
    .join("");
  return parseGrade(text);
}

interface Keys {
  openai?: string;
  anthropic?: string;
}

interface Summary {
  model: string;
  runs: number;
  passed: number;
  grammar: number | null;
  faithfulness: number | null;
  p50: number | null;
  p95: number | null;
  costPer1000: number | null;
  cacheShare: number | null;
  failures: Record<string, number>;
}

function summarize(model: string, records: RunRecord[]): Summary {
  const ok = records.filter((record) => record.status !== "error");
  const graded = (pick: (grade: Grade) => number) =>
    mean(records.flatMap((record) => {
      const scores = [record.grades.astra, record.grades.opus].flatMap((grade) => grade ? [pick(grade)] : []);
      return scores.length > 0 ? [scores.reduce((a, b) => a + b, 0) / scores.length] : [];
    }));
  const costs = records.flatMap((record) => record.cost === null ? [] : [record.cost]);
  const read = ok.reduce((sum, record) => sum + record.usage.cacheRead, 0);
  const prompt = ok.reduce((sum, record) => sum + record.usage.cacheRead + record.usage.uncached + record.usage.cacheWrite, 0);
  const failures: Record<string, number> = {};
  for (const record of records) {
    if (record.problems.length > 0) failures[record.caseId] = (failures[record.caseId] ?? 0) + 1;
  }
  return {
    model,
    runs: records.length,
    passed: records.filter((record) => record.problems.length === 0).length,
    grammar: graded((grade) => grade.grammar),
    faithfulness: graded((grade) => grade.faithfulness),
    p50: percentile(ok.map((record) => record.totalMs), 50),
    p95: percentile(ok.map((record) => record.totalMs), 95),
    costPer1000: costs.length > 0 ? mean(costs)! * 1000 : null,
    cacheShare: prompt > 0 ? read / prompt : null,
    failures,
  };
}

function fixed(value: number | null, digits: number): string {
  return value === null ? "—" : value.toFixed(digits);
}

function report(summaries: Summary[], records: RunRecord[], flags: Flags): string {
  const lines = [
    `# Text step: models compared (${new Date().toISOString().slice(0, 10)})`,
    "",
    `${CASES.filter((c) => !flags.only || c.id.includes(flags.only)).length} cases × ${flags.repeat} runs per model. ` +
    "Pass = status cleaned and every check held. Grammar and faithfulness: mean of gpt-6-astra and claude-opus-5-5, " +
    "graded blind, 1–5. Latency: the model call alone, from this Mac. Cost: estimate from the token counts.",
    "",
    "| Model | Pass | Grammar | Faithful | p50 ms | p95 ms | $ / 1,000 | Cached input |",
    "|---|---|---|---|---|---|---|---|",
    ...summaries.map((s) =>
      `| ${s.model} | ${s.passed}/${s.runs} | ${fixed(s.grammar, 2)} | ${fixed(s.faithfulness, 2)} | ${fixed(s.p50, 0)} | ` +
      `${fixed(s.p95, 0)} | ${fixed(s.costPer1000, 3)} | ${s.cacheShare === null ? "—" : `${Math.round(s.cacheShare * 100)}%`} |`
    ),
    "",
    "## Failures",
  ];
  for (const summary of summaries) {
    const failed = Object.entries(summary.failures);
    if (failed.length === 0) continue;
    lines.push("", `### ${summary.model}`);
    for (const [caseId, count] of failed) {
      const example = records.find((record) => record.model === summary.model && record.caseId === caseId &&
        record.problems.length > 0);
      lines.push(`- ${caseId} ×${count}: ${example?.problems.join("; ")} → ${JSON.stringify(example?.text ?? "")}`);
    }
  }
  return lines.join("\n") + "\n";
}

async function main() {
  const flags = parseFlags(Deno.args);
  const cases = CASES.filter((benchCase) => !flags.only || benchCase.id.includes(flags.only));
  const calls = cases.length * flags.repeat * flags.models.length;
  console.log(`${cases.length} cases × ${flags.repeat} runs × ${flags.models.length} models = ${calls} calls` +
    (flags.judge ? ", then up to 2 judge calls per distinct output" : ""));
  console.log(`Models: ${flags.models.map((spec) => spec.label).join(", ")}`);
  if (flags.dryRun) return;
  if (!flags.out) throw new Error("--out <dir> is required");

  const keys: Keys = { openai: Deno.env.get("OPENAI_API_KEY"), anthropic: Deno.env.get("ANTHROPIC_API_KEY") };
  const needsOpenAI = flags.judge || flags.models.some((spec) => spec.provider === "openai");
  const needsAnthropic = flags.judge || flags.models.some((spec) => spec.provider === "anthropic");
  if (needsOpenAI && !keys.openai) throw new Error("OPENAI_API_KEY is not set");
  if (needsAnthropic && !keys.anthropic) throw new Error("ANTHROPIC_API_KEY is not set");
  // No retries: a failed call is counted, and a retried one would hide its time.
  const anthropic = keys.anthropic ? new Anthropic({ apiKey: keys.anthropic, maxRetries: 0 }) : null;

  // One worker per model, so the models run side by side and each sees one call at a time. The
  // first round warms each model's prompt cache, as a user's first dictation would.
  const perModel = await Promise.all(flags.models.map(async (spec) => {
    const records: RunRecord[] = [];
    for (let repeat = 1; repeat <= flags.repeat; repeat++) {
      for (const benchCase of cases) {
        const record = await runOne(spec, benchCase, repeat, keys, anthropic);
        records.push(record);
        console.log(`${spec.label} ${benchCase.id} #${repeat}: ${record.status}` +
          `${record.problems.length ? ` (${record.problems.join("; ")})` : ""} ${record.totalMs} ms`);
      }
    }
    return records;
  }));
  const records = perModel.flat();

  if (flags.judge) {
    const byId = new Map(cases.map((benchCase) => [benchCase.id, benchCase]));
    const distinct = new Map<string, JudgeItem>();
    for (const record of records) {
      if (record.status !== "cleaned") continue;
      const benchCase = byId.get(record.caseId)!;
      distinct.set(`${record.caseId}\u0000${record.text}`, {
        style: benchCase.style, targetLanguage: benchCase.targetLanguage,
        transcript: benchCase.transcript, output: record.text,
      });
    }
    console.log(`Judging ${distinct.size} distinct outputs…`);
    const grades = new Map<string, { astra: Grade | null; opus: Grade | null }>();
    await pool([...distinct.entries()], 4, async ([key, item]) => {
      const [astra, opus] = await Promise.all([
        judgeWithAstra(keys.openai!, item).catch(() => null),
        judgeWithClaude(anthropic!, item).catch(() => null),
      ]);
      grades.set(key, { astra, opus });
    });
    for (const record of records) {
      const grade = grades.get(`${record.caseId}\u0000${record.text}`);
      if (grade) record.grades = grade;
    }
  }

  const summaries = perModel.map((modelRecords, index) => summarize(flags.models[index].label, modelRecords));
  const markdown = report(summaries, records, flags);
  await Deno.mkdir(flags.out, { recursive: true });
  await Deno.writeTextFile(`${flags.out}/results.json`, JSON.stringify({ records, summaries }, null, 2));
  await Deno.writeTextFile(`${flags.out}/report.md`, markdown);
  console.log(`\n${markdown}`);
}

if (import.meta.main) await main();
