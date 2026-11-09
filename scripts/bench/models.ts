// The models the benchmark compares, how fast each is asked to run, and what each costs.

export type Provider = "openai" | "anthropic";

export interface ModelSpec {
  provider: Provider;
  model: string;
  /** OpenAI reasoning effort, or Claude `output_config.effort`. */
  effort: string;
  /** "gpt-6.1-terra:none", the label in the report. */
  label: string;
}

/**
 * USD per million tokens: input, output, cached input. From the providers' pricing pages in
 * November 2026; cached-input prices marked "est." are 10% of input, where no price was listed.
 */
const PRICES: Record<string, { input: number; output: number; cached: number }> = {
  "gpt-6-astra": { input: 10, output: 50, cached: 1 }, // cached est.
  "gpt-6.1-sol": { input: 2, output: 10, cached: 0.2 }, // cached est.
  "gpt-6.1-terra": { input: 1, output: 5, cached: 0.1 }, // cached est.
  "gpt-6-luna": { input: 0.1, output: 0.5, cached: 0.01 }, // cached est.
  "claude-haiku-5-5": { input: 0.1, output: 0.5, cached: 0.01 }, // cached est.
  "claude-sonnet-5-5": { input: 2, output: 10, cached: 0.2 },
  "claude-opus-5-5": { input: 4, output: 20, cached: 0.2 },
};

/** The fastest setting each model allows: Terra and Luna think not at all, the others at low. */
const DEFAULT_EFFORT: Record<string, string> = {
  "gpt-6.1-terra": "none",
  "gpt-6-luna": "none",
  "gpt-6.1-sol": "low",
  "gpt-6-astra": "low",
};

export const DEFAULT_MODELS = [
  "gpt-6.1-terra:none",
  "gpt-6-luna:none",
  "gpt-6.1-sol:low",
  "gpt-6-astra:low",
  "claude-haiku-5-5:low",
  "claude-sonnet-5-5:low",
];

/** "gpt-6-luna" or "claude-haiku-5-5:low". */
export function parseModel(spec: string): ModelSpec {
  const [model, effort] = spec.trim().split(":");
  const provider: Provider = model.startsWith("claude-") ? "anthropic" : "openai";
  const resolved = effort || DEFAULT_EFFORT[model] || "low";
  return { provider, model, effort: resolved, label: `${model}:${resolved}` };
}

export interface Usage {
  /** Input tokens billed at the full price (cache reads and writes excluded). */
  uncached: number;
  cacheRead: number;
  cacheWrite: number;
  output: number;
}

/** USD for one call; cache writes cost 1.25× input on Claude and the input price on OpenAI. */
export function costOf(spec: ModelSpec, usage: Usage): number | null {
  const price = PRICES[spec.model];
  if (!price) return null;
  const writeRate = spec.provider === "anthropic" ? price.input * 1.25 : price.input;
  return (usage.uncached * price.input + usage.cacheRead * price.cached + usage.cacheWrite * writeRate +
    usage.output * price.output) / 1_000_000;
}

export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1))];
}

export function mean(values: number[]): number | null {
  return values.length === 0 ? null : values.reduce((sum, value) => sum + value, 0) / values.length;
}

/** Runs `work` over `items` with at most `limit` at a time, keeping the order of the results. */
export async function pool<T, R>(items: T[], limit: number, work: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const index = next++;
      results[index] = await work(items[index]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}
