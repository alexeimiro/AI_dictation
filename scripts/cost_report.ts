// What dictations cost, read from the `dictation_costs` rows the functions record (one per
// transcription or model call; counts only, never text) and the dated prices in scripts/prices.json.
//
// It prints the period's total and the month it adds up to at that pace, by service and model;
// what a dictation and an active person cost; the same by plan, against what a subscriber brings
// in; what the same audio would have cost at each other service; and the volume at which a server
// of your own becomes cheaper than paying by the minute.
//
//   deno run --allow-read scripts/cost_report.ts <rows.json> [--prices scripts/prices.json] [--since 2026-11-14] [--until 2026-11-21]
//
// <rows.json> is the one cell scripts/cost_rows.sql returns (a JSON array; a row a line also
// works). --since and --until take a date or a date and time (UTC) and set the period's length, so
// quiet days count; without them the period runs from the first row to the last.
import { percentile } from "./bench/models.ts";

/** A `dictation_costs` row as scripts/cost_rows.sql exports it. */
export interface CostRow {
  created_at: string;
  /** A pseudonym of the account; null once the account is deleted. */
  user: string | null;
  dictation_id: string | null;
  kind: "speech" | "text";
  path: "upload" | "live";
  host: string;
  plan: string | null;
  provider: string;
  model: string;
  backup: boolean;
  audio_ms: number | null;
  input_tokens: number | null;
  cached_tokens: number | null;
  cache_write_tokens: number | null;
  output_tokens: number | null;
}

interface Dated {
  provider: string;
  /** A row's model name starts with this. */
  model: string;
  /** The first day the price holds, "2026-01-01". */
  effective: string;
}

export interface SpeechPrice extends Dated {
  usdPerMinute: number;
  /** A service that bills every clip as at least this long. */
  minimumSeconds?: number;
}

/** US dollars per million tokens. */
export interface TextPrice extends Dated {
  input: number;
  cachedInput: number;
  /** Tokens written to the cache; billed as input when the provider names no price. */
  cacheWrite?: number;
  output: number;
}

export interface Monthly {
  name: string;
  usdPerMonth: number;
}

export interface Alternative {
  name: string;
  usdPerMinute: number;
  minimumSeconds?: number;
}

export interface Prices {
  checked: string;
  speech: SpeechPrice[];
  text: TextPrice[];
  /** What is paid every month whatever the use. */
  fixed: Monthly[];
  /** Servers that could run a model of your own, to compare with paying by the minute. */
  servers: Monthly[];
  /** Other speech services, for what the same audio would cost there. */
  alternatives: Alternative[];
  revenue: { monthlyUsd: number; yearlyUsd: number; storeCommission: number; note?: string };
}

const DAY_MS = 86_400_000;
/** An average month, in days. */
const MONTH_DAYS = 30.4375;

/** The rows of an export: a JSON array, or a row a line. Lines that aren't rows are skipped and counted. */
export function parseRows(text: string): { rows: CostRow[]; skipped: number } {
  let candidates: unknown[];
  try {
    const parsed = JSON.parse(text);
    // The SQL editor wraps the one cell: [{ "json_agg": [...] }].
    const cell = Array.isArray(parsed) && parsed.length === 1 && typeof parsed[0] === "object" && parsed[0] !== null
      ? Object.values(parsed[0] as Record<string, unknown>).find(Array.isArray)
      : undefined;
    candidates = (cell as unknown[] | undefined) ?? (Array.isArray(parsed) ? parsed : [parsed]);
  } catch {
    candidates = text.split("\n").filter((line) => line.trim()).map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    });
  }
  const rows = candidates.filter(isRow);
  return { rows, skipped: candidates.length - rows.length };
}

function isRow(value: unknown): value is CostRow {
  if (typeof value !== "object" || value === null) return false;
  const row = value as Record<string, unknown>;
  return typeof row.created_at === "string" && !Number.isNaN(Date.parse(row.created_at)) &&
    (row.kind === "speech" || row.kind === "text") && typeof row.provider === "string" && typeof row.model === "string";
}

/**
 * The price in force for a row: among its provider's entries that its model name starts with and
 * that hold on its day, the longest name, then the latest. Null when the file has none.
 */
export function priceFor<T extends Dated>(entries: T[], row: Pick<CostRow, "provider" | "model" | "created_at">): T | null {
  const day = row.created_at.slice(0, 10);
  let best: T | null = null;
  for (const entry of entries) {
    if (entry.provider !== row.provider || !row.model.startsWith(entry.model) || entry.effective > day) continue;
    if (
      !best || entry.model.length > best.model.length ||
      (entry.model.length === best.model.length && entry.effective > best.effective)
    ) best = entry;
  }
  return best;
}

/** What `seconds` of audio cost at a per-minute price, with the service's minimum per clip. */
export function audioCost(seconds: number, price: { usdPerMinute: number; minimumSeconds?: number }): number {
  return (Math.max(seconds, price.minimumSeconds ?? 0) / 60) * price.usdPerMinute;
}

/** What a model call's tokens cost. `input_tokens` holds every input token, the cached ones included. */
export function tokenCost(row: CostRow, price: TextPrice): number {
  const cached = row.cached_tokens ?? 0;
  const written = row.cache_write_tokens ?? 0;
  const fresh = Math.max(0, (row.input_tokens ?? 0) - cached - written);
  return (fresh * price.input + cached * price.cachedInput + written * (price.cacheWrite ?? price.input) +
    (row.output_tokens ?? 0) * price.output) / 1_000_000;
}

/** A row in dollars. Null when it can't be priced: no price for its model, or audio of unknown length. */
export function rowCost(row: CostRow, prices: Prices): number | null {
  if (row.kind === "speech") {
    const price = priceFor(prices.speech, row);
    return price && row.audio_ms !== null ? audioCost(row.audio_ms / 1000, price) : null;
  }
  const price = priceFor(prices.text, row);
  return price ? tokenCost(row, price) : null;
}

export interface ModelLine {
  kind: "speech" | "text";
  provider: string;
  model: string;
  usd: number;
  calls: number;
  audioMinutes: number;
  inputTokens: number;
  cachedTokens: number;
  outputTokens: number;
  /** The price it was costed at, when one entry priced every call. */
  usdPerMinute: number | null;
}

export interface PersonLine {
  user: string;
  /** The plan on the person's latest row that named one. */
  plan: string;
  usd: number;
  audioMinutes: number;
  dictations: number;
}

export interface PlanLine {
  plan: string;
  people: number;
  /** Per person, a month at the period's pace. */
  usdAMonth: number;
  audioMinutesAMonth: number;
  /** The share of the plan's dictations a model wrote. */
  rewritten: number | null;
}

export interface Summary {
  from: number;
  to: number;
  days: number;
  /** What a period's figure is multiplied by for a month at that pace. */
  perMonth: number;
  speechUsd: number;
  textUsd: number;
  transcriptions: number;
  textCalls: number;
  /** Of the transcriptions whose length is known. */
  audioMinutes: number;
  unknownAudio: number;
  backups: number;
  byModel: ModelLine[];
  unpriced: { label: string; rows: number }[];
  dictations: number;
  /** Dollars per dictation, for the rows that name one. */
  perDictation: number[];
  rewritten: number;
  people: PersonLine[];
  byPlan: PlanLine[];
  byPath: { label: string; calls: number; usd: number }[];
  /** The period's audio at each other service, in dollars over the period. */
  alternatives: { name: string; usd: number }[];
}

function sum(values: number[]): number {
  return values.reduce((total, value) => total + value, 0);
}

/** Groups in the order their keys first appear. */
function groupBy<T>(items: T[], key: (item: T) => string): Map<string, T[]> {
  const groups = new Map<string, T[]>();
  for (const item of items) {
    const name = key(item);
    const group = groups.get(name);
    if (group) group.push(item);
    else groups.set(name, [item]);
  }
  return groups;
}

/**
 * The rows as figures. `period` sets how long they are taken to cover; without it, from the first
 * row to the last, and never less than a day: an hour's rows are a day like that one, not a month
 * of such hours.
 */
export function summarize(rows: CostRow[], prices: Prices, period: { since?: number; until?: number } = {}): Summary {
  const times = rows.map((row) => Date.parse(row.created_at));
  const from = period.since ?? (times.length ? Math.min(...times) : 0);
  const to = period.until ?? (times.length ? Math.max(...times) : 0);
  const days = Math.max((to - from) / DAY_MS, 1);
  const perMonth = MONTH_DAYS / days;

  const costs = new Map<CostRow, number | null>(rows.map((row) => [row, rowCost(row, prices)]));
  const cost = (row: CostRow) => costs.get(row) ?? 0;
  const minutes = (row: CostRow) => row.kind === "speech" && row.audio_ms !== null ? row.audio_ms / 60_000 : 0;
  const speech = rows.filter((row) => row.kind === "speech");
  const text = rows.filter((row) => row.kind === "text");

  const byModel: ModelLine[] = [...groupBy(rows, (row) => `${row.kind} ${row.provider} ${row.model}`).values()].map((group) => {
    const [first] = group;
    const rates = new Set(group.map((row) => row.kind === "speech" ? priceFor(prices.speech, row)?.usdPerMinute ?? null : null));
    return {
      kind: first.kind,
      provider: first.provider,
      model: first.model,
      usd: sum(group.map(cost)),
      calls: group.length,
      audioMinutes: sum(group.map(minutes)),
      inputTokens: sum(group.map((row) => row.input_tokens ?? 0)),
      cachedTokens: sum(group.map((row) => row.cached_tokens ?? 0)),
      outputTokens: sum(group.map((row) => row.output_tokens ?? 0)),
      usdPerMinute: rates.size === 1 ? [...rates][0] : null,
    };
  }).sort((a, b) => b.usd - a.usd);

  // No price in the file: a speech row of unknown length is counted apart, as its model has one.
  const priceless = rows.filter((row) => !priceFor<Dated>(row.kind === "speech" ? prices.speech : prices.text, row));
  const unpriced = [...groupBy(priceless, (row) => `${row.kind} ${row.provider} ${row.model}`)]
    .map(([label, group]) => ({ label, rows: group.length }));

  const named = groupBy(rows.filter((row) => row.dictation_id !== null), (row) => row.dictation_id as string);
  const wasRewritten = (group: CostRow[]) => group.some((row) => row.kind === "text");

  const people: PersonLine[] = [...groupBy(rows.filter((row) => row.user !== null), (row) => row.user as string)]
    .map(([user, group]) => ({
      user,
      plan: [...group].sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at)).find((row) => row.plan)?.plan ??
        "unknown",
      usd: sum(group.map(cost)),
      audioMinutes: sum(group.map(minutes)),
      dictations: new Set(group.map((row) => row.dictation_id).filter((id) => id !== null)).size,
    }));
  const planOf = new Map(people.map((person) => [person.user, person.plan]));

  const byPlan: PlanLine[] = [...groupBy(people, (person) => person.plan)].map(([plan, group]) => {
    const theirs = [...named.values()].filter((dictation) => dictation.some((row) => row.user !== null && planOf.get(row.user) === plan));
    return {
      plan,
      people: group.length,
      usdAMonth: (sum(group.map((person) => person.usd)) / group.length) * perMonth,
      audioMinutesAMonth: (sum(group.map((person) => person.audioMinutes)) / group.length) * perMonth,
      rewritten: theirs.length ? theirs.filter(wasRewritten).length / theirs.length : null,
    };
  }).sort((a, b) => b.usdAMonth - a.usdAMonth);

  const byPath = [...groupBy(rows, (row) => `${row.path} on ${row.host}`)]
    .map(([label, group]) => ({ label, calls: group.length, usd: sum(group.map(cost)) }))
    .sort((a, b) => b.usd - a.usd);

  const timed = speech.filter((row) => row.audio_ms !== null);
  return {
    from,
    to,
    days,
    perMonth,
    speechUsd: sum(speech.map(cost)),
    textUsd: sum(text.map(cost)),
    transcriptions: speech.length,
    textCalls: text.length,
    audioMinutes: sum(timed.map(minutes)),
    unknownAudio: speech.length - timed.length,
    backups: speech.filter((row) => row.backup).length,
    byModel,
    unpriced,
    dictations: named.size,
    perDictation: [...named.values()].map((group) => sum(group.map(cost))),
    rewritten: [...named.values()].filter(wasRewritten).length,
    people,
    byPlan,
    byPath,
    alternatives: prices.alternatives.map((alternative) => ({
      name: alternative.name,
      usd: sum(timed.map((row) => audioCost((row.audio_ms as number) / 1000, alternative))),
    })),
  };
}

/** Dollars, with the digits a figure of its size needs. */
export function usd(value: number): string {
  const size = Math.abs(value);
  const digits = size === 0 || size >= 100 ? 0 : size >= 1 ? 2 : size >= 0.01 ? 3 : 5;
  return `$${value.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits })}`;
}

function count(value: number, digits = 0): string {
  return value.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

function tokens(value: number): string {
  return value >= 1_000_000 ? `${count(value / 1_000_000, 2)}M` : value >= 10_000 ? `${count(value / 1000)}K` : count(value);
}

function percent(share: number): string {
  return `${count(share * 100, share > 0 && share < 0.1 ? 1 : 0)}%`;
}

function plural(value: number, one: string, many = `${one}s`): string {
  return `${count(value)} ${value === 1 ? one : many}`;
}

function day(date: number): string {
  return new Date(date).toISOString().slice(0, 10);
}

/**
 * Rows as columns, each as wide as its widest cell. The first column is left-aligned and the rest
 * right, as figures are; `notes` left-aligns the last one, for a column of words.
 */
function table(rows: string[][], options: { indent?: string; notes?: boolean } = {}): string[] {
  if (rows.length === 0) return [];
  const widths = rows[0].map((_, column) => Math.max(...rows.map((row) => row[column].length)));
  const last = rows[0].length - 1;
  return rows.map((row) =>
    ((options.indent ?? "  ") + row.map((cell, column) =>
      column === 0 || (options.notes && column === last) ? cell.padEnd(widths[column]) : cell.padStart(widths[column])
    ).join("   ")).trimEnd()
  );
}

/** The report, as text. `skipped`: lines of the export that weren't rows. */
export function report(rows: CostRow[], prices: Prices, options: { since?: number; until?: number; skipped?: number } = {}): string {
  if (rows.length === 0) return "No cost rows in this period: nothing was dictated, or the functions that record costs aren't live yet.";
  const s = summarize(rows, prices, options);
  const total = s.speechUsd + s.textUsd;
  const fixed = sum(prices.fixed.map((item) => item.usdPerMonth));
  const lines: string[] = [];

  lines.push(
    `Dictation costs, ${day(s.from)} to ${day(s.to)} (${count(s.days, 1)} days): ` +
      `${plural(s.dictations, "dictation")} by ${plural(s.people.length, "person", "people")}`,
    `Prices as checked on ${prices.checked} (scripts/prices.json).`,
    "",
    ...table([
      ["This period", usd(total), `a month at this pace: ${usd(total * s.perMonth)}, plus ${usd(fixed)} fixed = ${usd(total * s.perMonth + fixed)}`],
      ["  Speech", usd(s.speechUsd), `${count(s.audioMinutes, 1)} audio minutes in ${plural(s.transcriptions, "transcription")}`],
      ["  Text", usd(s.textUsd), plural(s.textCalls, "model call")],
    ], { indent: "", notes: true }),
    "",
    "By service and model",
    ...table(s.byModel.map((line) => [
      `${line.kind}  ${line.provider} ${line.model}`,
      usd(line.usd),
      line.kind === "speech"
        ? `${count(line.audioMinutes, 1)} min in ${plural(line.calls, "call")}` +
          (line.usdPerMinute === null ? "" : ` at ${usd(line.usdPerMinute)} a minute`)
        : `${tokens(line.inputTokens)} tokens in (${tokens(line.cachedTokens)} cached), ${tokens(line.outputTokens)} out, ${plural(line.calls, "call")}`,
    ]), { notes: true }),
  );

  const notes: string[] = [];
  if (s.unknownAudio > 0) {
    notes.push(`${plural(s.unknownAudio, "transcription")} whose file didn't state the audio's length (not costed)`);
  }
  for (const item of s.unpriced) {
    notes.push(`${plural(item.rows, "call")} with no price for "${item.label}": add it to scripts/prices.json`);
  }
  if (options.skipped) notes.push(`${plural(options.skipped, "line")} of the export that ${options.skipped === 1 ? "isn't a row" : "aren't rows"}`);
  if (notes.length) lines.push("", "Not in the total", ...notes.map((note) => `  ${note}`));
  if (s.transcriptions > 0) {
    lines.push("", `The backup answered ${count(s.backups)} of ${plural(s.transcriptions, "transcription")}.`);
  }

  if (s.dictations > 0) {
    lines.push(
      "",
      `A dictation costs: median ${usd(percentile(s.perDictation, 50) ?? 0)}, 95th percentile ${usd(percentile(s.perDictation, 95) ?? 0)}. ` +
        `A model wrote ${percent(s.rewritten / s.dictations)} of them.`,
    );
  }
  if (s.people.length > 0) {
    const monthly = s.people.map((person) => person.usd * s.perMonth);
    lines.push(
      `A person costs, a month at this pace: median ${usd(percentile(monthly, 50) ?? 0)}, ` +
        `95th percentile ${usd(percentile(monthly, 95) ?? 0)}, the most ${usd(Math.max(...monthly))}.`,
      "",
      "By plan",
      ...table([
        ["", "people", "a person a month", "audio a month", "written by a model"],
        ...s.byPlan.map((line) => [
          line.plan,
          count(line.people),
          usd(line.usdAMonth),
          `${count(line.audioMinutesAMonth)} min`,
          line.rewritten === null ? "–" : percent(line.rewritten),
        ]),
      ]),
    );
    const { monthlyUsd, storeCommission, note } = prices.revenue;
    const kept = monthlyUsd * (1 - storeCommission);
    const pro = s.byPlan.find((line) => line.plan === "pro");
    lines.push(
      "",
      `Against a subscription: ${usd(monthlyUsd)} a month leaves ${usd(kept)} after the store's ${percent(storeCommission)}.` +
        (pro ? ` A person on pro costs ${percent(pro.usdAMonth / kept)} of that.` : ""),
      ...(note ? [`  ${note}`] : []),
    );
  }

  if (s.byPath.length > 1) {
    lines.push(
      "",
      "By path and home",
      ...table(s.byPath.map((line) => [line.label, usd(line.usd), plural(line.calls, "call")]), { notes: true }),
    );
  }

  if (s.audioMinutes > 0) {
    const monthlyMinutes = s.audioMinutes * s.perMonth;
    lines.push(
      "",
      `The same audio at each service, a month at this pace (${count(monthlyMinutes)} audio minutes)`,
      ...table([
        ["What you paid", usd(s.speechUsd * s.perMonth)],
        ...s.alternatives.map((alternative) => [alternative.name, usd(alternative.usd * s.perMonth)]),
      ]),
    );
    if (s.speechUsd > 0 && prices.servers.length > 0) {
      const paidPerMinute = s.speechUsd / s.audioMinutes;
      lines.push(
        "",
        `A server of your own instead of ${usd(paidPerMinute)} a minute`,
        ...table(prices.servers.map((server) => {
          const breakEven = server.usdPerMonth / paidPerMinute;
          return [
            server.name,
            `${usd(server.usdPerMonth)} a month`,
            `cheaper above ${count(breakEven)} audio minutes a month` +
              (breakEven > monthlyMinutes ? ` (${count(breakEven / monthlyMinutes, 1)} times this pace)` : " (below this pace already)"),
          ];
        }), { notes: true }),
      );
    }
  }
  return lines.join("\n");
}

function parseDate(value: string | undefined, flag: string): number {
  // A date alone is that day's start, in UTC, as the rows' own dates are.
  const date = Date.parse(value && /^\d{4}-\d{2}-\d{2}$/.test(value) ? `${value}T00:00:00Z` : value ?? "");
  if (Number.isNaN(date)) throw new Error(`${flag} needs a date such as 2026-11-14`);
  return date;
}

if (import.meta.main) {
  const args = [...Deno.args];
  const flag = (name: string): string | undefined => {
    const index = args.indexOf(name);
    if (index === -1) return undefined;
    const [, value] = args.splice(index, 2);
    return value ?? "";
  };
  try {
    const pricesPath = flag("--prices") ?? new URL("./prices.json", import.meta.url).pathname;
    const sinceArg = flag("--since");
    const untilArg = flag("--until");
    const since = sinceArg === undefined ? undefined : parseDate(sinceArg, "--since");
    const until = untilArg === undefined ? undefined : parseDate(untilArg, "--until");
    const [path] = args;
    if (!path) throw new Error("usage: cost_report.ts <rows.json> [--prices prices.json] [--since date] [--until date]");
    const prices = JSON.parse(await Deno.readTextFile(pricesPath)) as Prices;
    const { rows, skipped } = parseRows(await Deno.readTextFile(path));
    const within = rows.filter((row) => {
      const at = Date.parse(row.created_at);
      return (since === undefined || at >= since) && (until === undefined || at < until);
    });
    console.log(report(within, prices, { since, until, skipped }));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}
