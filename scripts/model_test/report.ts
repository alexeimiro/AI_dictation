// What the model test found: each candidate's words against your references, whether it qualifies,
// how fast it was, what it costs, and how your blind votes rank it. The runner writes this as
// report.md and report.json in the work folder; the vote page shows its ranking when you reveal.
//
// The plan's rules (stage 3):
// - A candidate qualifies when no clip comes back empty or with invented words, mixed Russian and
//   English survive detection (Auto), and punctuation is there.
// - Your blind votes rank the qualifiers: the Russian side (Russian and mixed clips) weighs 0.6,
//   the English side 0.4. A candidate's points are the share of clips where its text was among
//   the ones you picked as best, 0–100.
// - Your own model wins a tie within 3 points.
// - Until you have voted, the order is by word error rate, weighed the same way, and says so.
import { describeDiff, differenceRate, totalDifference, wordDiff, type WordDifference, wordDifference } from "../bench/metrics.ts";
import { percentile } from "../bench/models.ts";
import { type ClipEntry, type Group, type Manifest, scored, scriptWords, sideOf, writeJsonAtomic } from "./clips.ts";
import type { Candidate } from "./candidates.ts";

// MARK: Results

/** One attempt at one clip, a line of results/<candidate>.jsonl. */
export interface ResultLine {
  clip: string;
  candidate: string;
  /** 0 is the warm-up call that loads the model or opens the connections; 1 and on are timed. */
  attempt: number;
  /** null when the attempt failed. */
  text: string | null;
  language: string | null;
  /** From the request to the answer, measured where the runner runs. */
  ms: number | null;
  /** The candidate's own processing time, when it reports one. */
  serverMs: number | null;
  /** Done → text, for the WebSocket kinds. */
  finalizeMs?: number | null;
  audioMs: number | null;
  error: string | null;
  run: string;
  at: string;
}

export async function loadResults(dir: string): Promise<Map<string, ResultLine[]>> {
  const results = new Map<string, ResultLine[]>();
  try {
    for await (const entry of Deno.readDir(`${dir}/results`)) {
      if (!entry.isFile || !entry.name.endsWith(".jsonl")) continue;
      const lines = (await Deno.readTextFile(`${dir}/results/${entry.name}`)).split("\n").filter((line) => line.trim());
      const parsed = lines.flatMap((line) => {
        try {
          return [JSON.parse(line) as ResultLine];
        } catch {
          return [];
        }
      });
      if (parsed.length > 0) results.set(entry.name.replace(/\.jsonl$/, ""), parsed);
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  return results;
}

/**
 * Each candidate's text for each clip: the first timed attempt that answered, in the latest run that
 * answered it (a run with --rerun replaces an older one). A clip it never answered maps to null.
 * This is the text the votes and the error rates are about.
 */
export function textsOf(results: Map<string, ResultLine[]>): Map<string, Map<string, string | null>> {
  const texts = new Map<string, Map<string, string | null>>();
  for (const [candidate, lines] of results) {
    const byClip = new Map<string, string | null>();
    const chosen = new Map<string, ResultLine>();
    for (const line of lines.filter((line) => line.attempt >= 1)) {
      if (!byClip.has(line.clip)) byClip.set(line.clip, null);
      if (line.text === null) continue;
      const kept = chosen.get(line.clip);
      const later = !kept || line.run > kept.run || (line.run === kept.run && line.attempt < kept.attempt);
      if (later) chosen.set(line.clip, line);
    }
    for (const [clip, line] of chosen) byClip.set(clip, line.text);
    texts.set(candidate, byClip);
  }
  return texts;
}

// MARK: Votes

export interface Vote {
  /** The texts you picked as best (several when they were equally good). */
  best: string[];
  /** The texts you marked unusable. */
  unusable: string[];
  skipped: boolean;
  at: string;
}

export interface Votes {
  version: 1;
  /** Keeps the order and the ids of the options from saying who wrote them. */
  salt: string;
  votes: Record<string, Vote>;
}

export async function readVotes(dir: string): Promise<Votes> {
  try {
    return JSON.parse(await Deno.readTextFile(`${dir}/votes.json`)) as Votes;
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    return { version: 1, salt: [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join(""), votes: {} };
  }
}

export async function writeVotes(dir: string, votes: Votes): Promise<void> {
  await writeJsonAtomic(`${dir}/votes.json`, votes);
}

async function digest(text: string): Promise<string> {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
  return [...hash.slice(0, 8)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export interface BallotOption {
  /** Opaque: says nothing about who wrote it. */
  id: string;
  text: string;
}

export interface BallotClip {
  id: string;
  group: Group;
  audioMs: number | null;
  reference: string;
  options: BallotOption[];
  /** Every candidate wrote the same text: nothing to vote on. */
  same: boolean;
  vote: { best: string[]; unusable: string[]; skipped: boolean } | null;
}

/**
 * The vote page's clips: each scored clip with the distinct texts the candidates wrote, in an order
 * and under ids drawn from the salt, so neither shows who wrote what. Identical texts are one
 * option, and a vote for it counts for every candidate that wrote it.
 */
export async function ballot(
  manifest: Manifest,
  texts: Map<string, Map<string, string | null>>,
  votes: Votes,
): Promise<BallotClip[]> {
  const clips: BallotClip[] = [];
  for (const clip of manifest.clips.filter(scored)) {
    const written = [...texts.values()].map((byClip) => byClip.get(clip.id)).filter((text) => text !== undefined);
    if (written.length === 0) continue;
    const distinct = [...new Set(written.filter((text): text is string => text !== null))];
    const options = await Promise.all(distinct.map(async (text) => ({
      id: await digest(`${votes.salt}|${clip.id}|${text}`),
      order: await digest(`${votes.salt}|order|${clip.id}|${text}`),
      text,
    })));
    options.sort((a, b) => a.order.localeCompare(b.order));
    const saved = votes.votes[clip.id];
    const idOf = (text: string) => options.find((option) => option.text === text)?.id;
    clips.push({
      id: clip.id,
      group: clip.group,
      audioMs: clip.audioMs,
      reference: clip.reference!,
      options: options.map(({ id, text }) => ({ id, text })),
      same: distinct.length === 1 && !written.includes(null),
      vote: saved
        ? {
          best: saved.best.map(idOf).filter((id): id is string => Boolean(id)),
          unusable: saved.unusable.map(idOf).filter((id): id is string => Boolean(id)),
          skipped: saved.skipped,
        }
        : null,
    });
  }
  return clips;
}

export interface VoteScore {
  candidate: string;
  /** 0–100: the weighted share of voted clips where its text was among the best. */
  points: number | null;
  ruPoints: number | null;
  enPoints: number | null;
  /** Voted clips where its text was marked unusable, or it gave none. */
  unusable: number;
  voted: number;
}

/** The side weights of the plan: Russian (with mixed) 0.6, English 0.4. */
export const SIDE_WEIGHTS = { ru: 0.6, en: 0.4 };

/** A weighted mean of the two sides; one side alone when the other has nothing. */
export function weighted(ru: number | null, en: number | null): number | null {
  if (ru === null && en === null) return null;
  if (ru === null) return en;
  if (en === null) return ru;
  return SIDE_WEIGHTS.ru * ru + SIDE_WEIGHTS.en * en;
}

export function scoreVotes(manifest: Manifest, texts: Map<string, Map<string, string | null>>, votes: Votes): VoteScore[] {
  const voted = manifest.clips.filter((clip) => scored(clip) && votes.votes[clip.id] && !votes.votes[clip.id].skipped);
  return [...texts.keys()].map((candidate) => {
    const byClip = texts.get(candidate)!;
    const share = (side: "ru" | "en") => {
      const clips = voted.filter((clip) => sideOf(clip.group) === side && byClip.has(clip.id));
      if (clips.length === 0) return null;
      const best = clips.filter((clip) => {
        const text = byClip.get(clip.id);
        return text !== null && text !== undefined && votes.votes[clip.id].best.includes(text);
      }).length;
      return (100 * best) / clips.length;
    };
    const mine = voted.filter((clip) => byClip.has(clip.id));
    const unusable = mine.filter((clip) => {
      const text = byClip.get(clip.id);
      return text === null || text === undefined || votes.votes[clip.id].unusable.includes(text);
    }).length;
    const ruPoints = share("ru");
    const enPoints = share("en");
    return { candidate, points: weighted(ruPoints, enPoints), ruPoints, enPoints, unusable, voted: mine.length };
  });
}

// MARK: Qualifying

export interface Qualification {
  /** Scored clips it has an answer (or a failure) for. */
  clips: number;
  missing: number;
  errors: number;
  empty: number;
  invented: number;
  mixedClips: number;
  mixedKept: number;
  punctuationClips: number;
  punctuated: number;
  qualifies: boolean;
  reasons: string[];
}

/** Added words that make a clip "invented": at least 3, and at least half the reference's words. */
export function invented(difference: WordDifference): boolean {
  return difference.added >= Math.max(3, Math.ceil(difference.words / 2));
}

const PUNCTUATION = /[.,!?…;:]/;

export function qualify(clips: ClipEntry[], byClip: Map<string, string | null>, failures: Map<string, string>): Qualification {
  const result: Qualification = {
    clips: 0, missing: 0, errors: 0, empty: 0, invented: 0, mixedClips: 0, mixedKept: 0, punctuationClips: 0, punctuated: 0,
    qualifies: false, reasons: [],
  };
  for (const clip of clips) {
    if (!byClip.has(clip.id)) {
      result.missing++;
      continue;
    }
    result.clips++;
    const text = byClip.get(clip.id) ?? null;
    if (text === null) {
      result.errors++;
      continue;
    }
    const reference = clip.reference!;
    const difference = wordDifference(reference, text);
    if (difference.words > 0 && !text.trim()) result.empty++;
    else if (invented(difference)) result.invented++;
    if (clip.group === "mix") {
      result.mixedClips++;
      const heard = scriptWords(text);
      if (heard.cyrillic > 0 && heard.latin > 0) result.mixedKept++;
    }
    if (difference.words >= 5) {
      result.punctuationClips++;
      if (PUNCTUATION.test(text)) result.punctuated++;
    }
  }
  const reasons = result.reasons;
  if (result.missing > 0) reasons.push(`not run on ${result.missing} clip${result.missing === 1 ? "" : "s"}`);
  if (result.errors > 0) {
    const kinds = [...new Set(failures.values())].slice(0, 3).join("; ");
    reasons.push(`failed on ${result.errors} clip${result.errors === 1 ? "" : "s"}${kinds ? ` (${kinds})` : ""}`);
  }
  if (result.empty > 0) reasons.push(`empty text on ${result.empty}`);
  if (result.invented > 0) reasons.push(`invented words on ${result.invented}`);
  if (result.mixedClips > 0 && result.mixedKept / result.mixedClips < 0.75) {
    reasons.push(`lost the mix of Russian and English on ${result.mixedClips - result.mixedKept} of ${result.mixedClips} mixed clips`);
  }
  if (result.punctuationClips > 0 && result.punctuated / result.punctuationClips < 0.8) {
    reasons.push(`no punctuation on ${result.punctuationClips - result.punctuated} of ${result.punctuationClips} longer clips`);
  }
  result.qualifies = result.clips > 0 && reasons.length === 0;
  return result;
}

// MARK: The report

export interface CandidateReport {
  name: string;
  kind: string;
  model: string;
  own: boolean;
  qualification: Qualification;
  /** Word error rate in percent, by group and weighted (Russian side 0.6, English 0.4). */
  errorRate: { ru: number | null; mix: number | null; en: number | null; weighted: number | null };
  speed: { n: number; medianMs: number | null; p95Ms: number | null; serverMedianMs: number | null; finalizeMedianMs: number | null; coldMs: number | null };
  cost: { usdPerMinute: number | null; usdThisTest: number | null; usdPer1000Minutes: number | null; note: string | null };
  votes: VoteScore | null;
}

export interface Report {
  at: string;
  clips: { scored: number; ru: number; mix: number; en: number; audioMinutes: number };
  voted: number;
  ranking: string[];
  /** How the ranking was made: "votes" or "error rate" (provisional). */
  rankedBy: "votes" | "error rate";
  winner: string | null;
  spare: string | null;
  verdict: string;
  candidates: CandidateReport[];
}

function rate(differences: WordDifference[]): number | null {
  const value = differenceRate(totalDifference(differences));
  return value === null ? null : Math.round(value * 1000) / 10;
}

function median(values: number[]): number | null {
  const value = percentile(values, 50);
  return value === null ? null : Math.round(value);
}

/** Orders the qualifiers by points; your own model takes first place from a service within 3 points of it. */
export function rankByVotes(rows: { name: string; own: boolean; points: number | null }[]): string[] {
  const ranked = [...rows].sort((a, b) => (b.points ?? -1) - (a.points ?? -1));
  const top = ranked[0];
  if (top && !top.own) {
    const own = ranked.find((row) => row.own);
    if (own && own.points !== null && top.points !== null && top.points - own.points <= 3) {
      ranked.splice(ranked.indexOf(own), 1);
      ranked.unshift(own);
    }
  }
  return ranked.map((row) => row.name);
}

export function buildReport(
  manifest: Manifest,
  results: Map<string, ResultLine[]>,
  votes: Votes,
  candidates: Candidate[],
  ownCost: string | null = null,
  now = new Date(),
): Report {
  const clips = manifest.clips.filter(scored);
  const texts = textsOf(results);
  const voteScores = new Map(scoreVotes(manifest, texts, votes).map((score) => [score.candidate, score]));
  const audioMinutes = clips.reduce((sum, clip) => sum + (clip.audioMs ?? 0), 0) / 60_000;
  const known = new Map(candidates.map((candidate) => [candidate.name, candidate]));
  const reports: CandidateReport[] = [...results.keys()].sort().map((name) => {
    const candidate = known.get(name);
    const lines = results.get(name)!;
    const byClip = texts.get(name)!;
    const failures = new Map(lines.filter((line) => line.text === null && line.error).map((line) => [line.clip, line.error!]));
    const differences = (group: Group | null) =>
      clips.filter((clip) => (group === null || clip.group === group) && typeof byClip.get(clip.id) === "string")
        .map((clip) => wordDifference(clip.reference!, byClip.get(clip.id)!));
    const ru = rate(differences("ru"));
    const mix = rate(differences("mix"));
    const en = rate(differences("en"));
    const ruSide = rate([...differences("ru"), ...differences("mix")]);
    const timed = lines.filter((line) => line.attempt >= 1 && line.text !== null && line.ms !== null);
    const cold = lines.find((line) => line.attempt === 0 && line.ms !== null);
    const usdPerMinute = candidate?.usdPerMinute ?? null;
    const own = candidate?.own ?? false;
    const voted = voteScores.get(name) ?? null;
    return {
      name,
      kind: candidate?.kind ?? "unknown",
      model: candidate?.model ?? "",
      own,
      qualification: qualify(clips, byClip, failures),
      errorRate: { ru, mix, en, weighted: (() => {
        const value = weighted(ruSide, en);
        return value === null ? null : Math.round(value * 10) / 10;
      })() },
      speed: {
        n: timed.length,
        medianMs: median(timed.map((line) => line.ms!)),
        p95Ms: (() => {
          const value = percentile(timed.map((line) => line.ms!), 95);
          return value === null ? null : Math.round(value);
        })(),
        serverMedianMs: median(timed.flatMap((line) => line.serverMs === null ? [] : [line.serverMs])),
        finalizeMedianMs: median(timed.flatMap((line) => typeof line.finalizeMs === "number" ? [line.finalizeMs] : [])),
        coldMs: cold?.ms ?? null,
      },
      cost: {
        usdPerMinute,
        usdThisTest: usdPerMinute === null ? null : Math.round(usdPerMinute * audioMinutes * 10_000) / 10_000,
        usdPer1000Minutes: usdPerMinute === null ? null : Math.round(usdPerMinute * 1000 * 100) / 100,
        note: own ? ownCost ?? "your GPU's rent, the same however much is dictated" : candidate?.priceSource ?? null,
      },
      votes: voted && voted.voted > 0 ? voted : null,
    };
  });

  const qualifiers = reports.filter((report) => report.qualification.qualifies);
  const voted = Object.values(votes.votes).filter((vote) => !vote.skipped).length;
  const rankedBy = voted > 0 ? "votes" : "error rate";
  const ranking = rankedBy === "votes"
    ? rankByVotes(qualifiers.map((report) => ({ name: report.name, own: report.own, points: report.votes?.points ?? null })))
    : [...qualifiers].sort((a, b) => (a.errorRate.weighted ?? Infinity) - (b.errorRate.weighted ?? Infinity)).map((report) => report.name);
  const winner = ranking[0] ?? null;
  const spare = ranking[1] ?? null;
  const winnerIsOwn = winner !== null && (known.get(winner)?.own ?? false);
  const anyOwn = qualifiers.some((report) => report.own);
  const verdict = winner === null
    ? "No candidate qualifies yet."
    : winnerIsOwn
    ? `${winner} wins: your own model can be the primary, with ${spare ?? "OpenAI"} as the backup.`
    : anyOwn
    ? `${winner} wins, by more than 3 points over your best own model: it can be the primary through the Murmur server for now.`
    : `${winner} wins. No open model qualifies: the best service becomes the primary through the Murmur server, and your own model waits for training.`;

  return {
    at: now.toISOString(),
    clips: {
      scored: clips.length,
      ru: clips.filter((clip) => clip.group === "ru").length,
      mix: clips.filter((clip) => clip.group === "mix").length,
      en: clips.filter((clip) => clip.group === "en").length,
      audioMinutes: Math.round(audioMinutes * 100) / 100,
    },
    voted,
    ranking,
    rankedBy,
    winner,
    spare,
    verdict: rankedBy === "votes" ? verdict : `Provisional, by word error rate until you vote: ${verdict}`,
    candidates: reports,
  };
}

function cell(value: number | null, suffix = ""): string {
  return value === null ? "—" : `${value}${suffix}`;
}

/** The report for people: what wins, the table, why some didn't qualify, and each clip's differences. */
export function reportMarkdown(report: Report, manifest: Manifest, results: Map<string, ResultLine[]>): string {
  const texts = textsOf(results);
  const lines = [
    `# Model test, ${report.at.slice(0, 16).replace("T", " ")} UTC`,
    "",
    `${report.clips.scored} clips with a checked reference (Russian ${report.clips.ru}, mixed ${report.clips.mix}, ` +
    `English ${report.clips.en}; ${report.clips.audioMinutes} minutes of audio). Votes: ${report.voted}.`,
    "",
    `**${report.verdict}**`,
    "",
    `Ranked by ${report.rankedBy === "votes" ? "your blind votes (Russian side 0.6, English 0.4; your own model wins a tie within 3 points)" : "word error rate (Russian side 0.6, English 0.4)"}: ` +
    (report.ranking.length ? report.ranking.map((name, index) => `${index + 1}. ${name}`).join(" · ") : "nobody qualifies yet") + ".",
    "",
    "| Candidate | Own | Qualifies | Votes (ru / en) | Word errors ru / mix / en | Speed median · p95 | Its own time | Price |",
    "|---|---|---|---|---|---|---|---|",
  ];
  for (const candidate of report.candidates) {
    const votes = candidate.votes
      ? `${cell(round(candidate.votes.points))} (${cell(round(candidate.votes.ruPoints))} / ${cell(round(candidate.votes.enPoints))})`
      : "—";
    const own = candidate.speed.serverMedianMs ?? candidate.speed.finalizeMedianMs;
    const ownLabel = candidate.speed.serverMedianMs !== null ? "" : candidate.speed.finalizeMedianMs !== null ? " after done" : "";
    lines.push(`| ${candidate.name} | ${candidate.own ? "yes" : ""} | ${candidate.qualification.qualifies ? "yes" : "**no**"} | ${votes} | ` +
      `${cell(candidate.errorRate.ru, "%")} / ${cell(candidate.errorRate.mix, "%")} / ${cell(candidate.errorRate.en, "%")} | ` +
      `${cell(candidate.speed.medianMs, " ms")} · ${cell(candidate.speed.p95Ms, " ms")} | ${cell(own, " ms")}${ownLabel} | ` +
      `${candidate.cost.usdPer1000Minutes === null ? candidate.own ? "fixed (GPU)" : "—" : `$${candidate.cost.usdPer1000Minutes} per 1,000 min`} |`);
  }
  lines.push(
    "",
    "Word errors: words changed, missing or added against your references, in percent; case, punctuation and ё/е don't count. " +
    "Speed: request to text, measured where the runner ran, after one warm-up call; \"its own time\" is what the candidate reports " +
    "for itself (a header), or done → text for the streaming kinds.",
  );
  const failing = report.candidates.filter((candidate) => !candidate.qualification.qualifies);
  if (failing.length > 0) {
    lines.push("", "## Why some don't qualify", "");
    for (const candidate of failing) lines.push(`- ${candidate.name}: ${candidate.qualification.reasons.join("; ") || "no answers yet"}.`);
  }
  lines.push("", "## Each clip", "");
  for (const clip of manifest.clips.filter(scored)) {
    lines.push(`### ${clip.group} · ${clip.audioMs === null ? "?" : (clip.audioMs / 1000).toFixed(1)} s · ${clip.id}`, "", `Reference: ${clip.reference}`, "");
    for (const [candidate, byClip] of texts) {
      if (!byClip.has(clip.id)) continue;
      const text = byClip.get(clip.id);
      if (text === null || text === undefined) {
        lines.push(`- ${candidate}: (failed)`);
        continue;
      }
      const differences = describeDiff(wordDiff(clip.reference!, text));
      lines.push(`- ${candidate}: ${differences ? `\`${differences}\`` : "same words"}${text === clip.reference ? " (exactly the reference)" : ""}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

function round(value: number | null): number | null {
  return value === null ? null : Math.round(value);
}

export async function writeReport(dir: string, manifest: Manifest, results: Map<string, ResultLine[]>, votes: Votes, candidates: Candidate[], ownCost: string | null) {
  const report = buildReport(manifest, results, votes, candidates, ownCost);
  await writeJsonAtomic(`${dir}/report.json`, report);
  await Deno.writeTextFile(`${dir}/report.md`, reportMarkdown(report, manifest, results));
  return report;
}
