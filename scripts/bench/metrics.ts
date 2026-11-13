// How far one transcript of a recording is from another, counted in words: what the live bake-off
// (live_bench.ts) reports for each speech service against a clip's reference text.

/**
 * A transcript as the words that are compared. Case, punctuation and "ё" for "е" are how a service
 * writes, not what it heard, so they don't count: "Ещё, не всё." and "еще не все" are the same.
 * Numbers do count as written: "5" and "five" differ.
 */
export function comparableWords(text: string): string[] {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replaceAll("ё", "е")
    // "don't" and "dont" are one word; a hyphen separates, so "кто-то" is "кто то".
    .replace(/['’ʼ`]/g, "")
    .split(/[^\p{L}\p{M}\p{N}]+/u)
    .filter((word) => word.length > 0);
}

/** One step on the way from the reference to what a service heard. */
export type DiffStep =
  | { kind: "same"; word: string }
  | { kind: "changed"; from: string; to: string }
  /** In the reference only. */
  | { kind: "missing"; word: string }
  /** Heard, and not in the reference. */
  | { kind: "added"; word: string };

/** The fewest word changes that turn `reference` into `heard`, in the order of the text. */
export function wordDiff(reference: string, heard: string): DiffStep[] {
  const from = comparableWords(reference);
  const to = comparableWords(heard);
  const width = to.length + 1;
  // cost[i * width + j]: the changes between the first i reference words and the first j heard.
  const cost = new Uint32Array((from.length + 1) * width);
  for (let j = 0; j <= to.length; j++) cost[j] = j;
  for (let i = 1; i <= from.length; i++) {
    cost[i * width] = i;
    for (let j = 1; j <= to.length; j++) {
      const swap = cost[(i - 1) * width + j - 1] + (from[i - 1] === to[j - 1] ? 0 : 1);
      cost[i * width + j] = Math.min(swap, cost[(i - 1) * width + j] + 1, cost[i * width + j - 1] + 1);
    }
  }
  const steps: DiffStep[] = [];
  let i = from.length;
  let j = to.length;
  while (i > 0 || j > 0) {
    const here = cost[i * width + j];
    if (i > 0 && j > 0 && from[i - 1] === to[j - 1] && here === cost[(i - 1) * width + j - 1]) {
      steps.push({ kind: "same", word: from[--i] });
      j--;
    } else if (i > 0 && j > 0 && here === cost[(i - 1) * width + j - 1] + 1) {
      steps.push({ kind: "changed", from: from[--i], to: to[--j] });
    } else if (i > 0 && here === cost[(i - 1) * width + j] + 1) {
      steps.push({ kind: "missing", word: from[--i] });
    } else {
      steps.push({ kind: "added", word: to[--j] });
    }
  }
  return steps.reverse();
}

/** The word changes between a reference and what was heard, by kind. */
export interface WordDifference {
  /** Words in the reference. */
  words: number;
  changed: number;
  missing: number;
  added: number;
}

export function wordDifference(reference: string, heard: string): WordDifference {
  const difference: WordDifference = { words: 0, changed: 0, missing: 0, added: 0 };
  for (const step of wordDiff(reference, heard)) {
    if (step.kind !== "added") difference.words++;
    if (step.kind !== "same") difference[step.kind]++;
  }
  return difference;
}

/** Several clips as one: a long clip weighs as its words do. */
export function totalDifference(differences: WordDifference[]): WordDifference {
  const total: WordDifference = { words: 0, changed: 0, missing: 0, added: 0 };
  for (const difference of differences) {
    total.words += difference.words;
    total.changed += difference.changed;
    total.missing += difference.missing;
    total.added += difference.added;
  }
  return total;
}

/** The word error rate: the changes over the reference's words. Null without a reference to count against. */
export function differenceRate(difference: WordDifference): number | null {
  if (difference.words === 0) return null;
  return (difference.changed + difference.missing + difference.added) / difference.words;
}

/** The words that differ, for a line of the report: "fox→box −the +very"; empty when none do. */
export function describeDiff(steps: DiffStep[]): string {
  return steps.flatMap((step) => {
    if (step.kind === "changed") return [`${step.from}→${step.to}`];
    if (step.kind === "missing") return [`−${step.word}`];
    if (step.kind === "added") return [`+${step.word}`];
    return [];
  }).join(" ");
}
