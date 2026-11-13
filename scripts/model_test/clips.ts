// The model test's set of recordings: one manifest (clips.json in the work folder) that the phone
// pull writes, the correction page edits and the runner reads. Everything in the work folder is
// private (your voice, your texts): it lives under scripts/out/, which git ignores, and the review
// page serves it on this Mac only.
//
// A clip is one dictation: its audio as the phone uploaded it (AAC .m4a, or .wav), the text the
// phone typed for it, and the reference you write for it on the correction page, which is what
// every candidate is compared with.

/** The work folder when none is given. */
export const DEFAULT_DIR = "scripts/out/model_test";
export const MANIFEST = "clips.json";

/**
 * How a clip's words are split by language. "ru" and "mix" (Russian with English words in it) are
 * the Russian side of the score, "en" the English side.
 */
export type Group = "ru" | "en" | "mix";
export const GROUPS: Group[] = ["ru", "mix", "en"];

/** The plan's test set: about 40 dictations, 20 Russian (8 of them mixed), 20 English, some short. */
export const DEFAULT_TARGETS = { ru: 12, mix: 8, en: 20, short: 8, total: 40 };
export type Targets = typeof DEFAULT_TARGETS;

/** A clip counts as short from this long to `SHORT_MAX_MS`: the 2–5 s dictations the plan asks for. */
export const SHORT_MIN_MS = 2000;
export const SHORT_MAX_MS = 5000;

export interface ClipEntry {
  /** The dictation's id on the phone (an uppercase UUID), or the file's name for a folder of clips. */
  id: string;
  /** The audio, relative to the work folder. */
  file: string;
  /** Where it came from: "iPhone 16 Pro, pulled 2026-11-13 18:05" or "folder live_bench_clips". */
  source: string;
  /** When it was dictated (ISO), if known. */
  createdAt: string | null;
  audioMs: number | null;
  /** The text the phone typed: today's speech service as the app kept it. */
  phoneText: string;
  phoneLanguage: string | null;
  /** The writing style it was dictated in ("verbatim" is Word for word). */
  style: string | null;
  group: Group;
  /** In the test set. */
  selected: boolean;
  /** Never sent anywhere (private). Wins over `selected`. */
  excluded: boolean;
  /** What was really said, as you want it typed; null until you edit it. */
  reference: string | null;
  /** You listened and confirmed the reference. Only checked clips are scored. */
  checked: boolean;
  /** "names", "numbers", "terms": what makes the clip hard. */
  tags: string[];
  note: string;
  updatedAt?: string;
}

export interface Manifest {
  version: 1;
  createdAt: string;
  updatedAt: string;
  targets: Targets;
  clips: ClipEntry[];
}

export function emptyManifest(now = new Date()): Manifest {
  return { version: 1, createdAt: now.toISOString(), updatedAt: now.toISOString(), targets: { ...DEFAULT_TARGETS }, clips: [] };
}

export async function readManifest(dir: string): Promise<Manifest> {
  try {
    const manifest = JSON.parse(await Deno.readTextFile(`${dir}/${MANIFEST}`)) as Manifest;
    manifest.targets = { ...DEFAULT_TARGETS, ...manifest.targets };
    return manifest;
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return emptyManifest();
    throw error;
  }
}

/** Writes the manifest whole, through a temporary file, so a crash never leaves half of it. */
export async function writeManifest(dir: string, manifest: Manifest, now = new Date()): Promise<void> {
  manifest.updatedAt = now.toISOString();
  await writeJsonAtomic(`${dir}/${MANIFEST}`, manifest);
}

export async function writeJsonAtomic(path: string, value: unknown): Promise<void> {
  const temporary = `${path}.${crypto.randomUUID().slice(0, 8)}.tmp`;
  await Deno.writeTextFile(temporary, JSON.stringify(value, null, 2) + "\n");
  await Deno.rename(temporary, path);
}

// MARK: Languages

const CYRILLIC = /\p{Script=Cyrillic}/u;
const LATIN = /\p{Script=Latin}/u;

/** The words of a text that are written in each script: what "mixed" is measured by. */
export function scriptWords(text: string): { cyrillic: number; latin: number } {
  let cyrillic = 0;
  let latin = 0;
  for (const word of text.normalize("NFC").split(/[^\p{L}\p{M}'’-]+/u)) {
    if (!word) continue;
    if (CYRILLIC.test(word)) cyrillic++;
    else if (LATIN.test(word)) latin++;
  }
  return { cyrillic, latin };
}

/**
 * The group a text belongs to: Russian, English, or Russian with English words in it ("mix"). A
 * single Latin word in a Russian sentence ("скинь pull request") is what mixed means here. A text
 * with no letters goes by the language the phone reported.
 */
export function guessGroup(text: string, language: string | null): Group {
  const { cyrillic, latin } = scriptWords(text);
  if (cyrillic > 0 && latin > 0) return "mix";
  if (cyrillic > 0) return "ru";
  if (latin > 0) return "en";
  return language?.toLowerCase().startsWith("ru") ? "ru" : "en";
}

/** The Russian side (ru and mix) or the English side, as the score weighs them. */
export function sideOf(group: Group): "ru" | "en" {
  return group === "en" ? "en" : "ru";
}

// MARK: The test set

export function isShort(clip: Pick<ClipEntry, "audioMs">): boolean {
  return clip.audioMs !== null && clip.audioMs >= SHORT_MIN_MS && clip.audioMs <= SHORT_MAX_MS;
}

/** A clip the test can use at all: audio of a second or more, some words, not excluded. */
export function eligible(clip: ClipEntry): boolean {
  return !clip.excluded && (clip.audioMs ?? 0) >= 1000 && clip.phoneText.trim().length > 0;
}

/** The clips that are in the test: selected and not excluded. */
export function inTest(clip: ClipEntry): boolean {
  return clip.selected && !clip.excluded;
}

/** The clips that are scored: in the test, with a reference you confirmed. */
export function scored(clip: ClipEntry): boolean {
  return inTest(clip) && clip.checked && (clip.reference ?? "").trim().length > 0;
}

/**
 * Picks a first test set from the clips: per group up to its target, newest first but spread over
 * lengths, with short ones first up to their share of `short`. Mixed clips that don't fit their
 * target count toward the Russian one. You change the set on the correction page.
 */
export function chooseTestSet(clips: ClipEntry[], targets: Targets = DEFAULT_TARGETS): Set<string> {
  const chosen = new Set<string>();
  const pool = clips.filter(eligible);
  const byGroup = (group: Group) => pool.filter((clip) => clip.group === group);
  const quota: Record<Group, number> = { mix: targets.mix, ru: targets.ru, en: targets.en };
  const mixAvailable = byGroup("mix").length;
  // Fewer mixed clips than their target: the Russian ones fill the Russian side's 20.
  if (mixAvailable < quota.mix) {
    quota.ru += quota.mix - mixAvailable;
    quota.mix = mixAvailable;
  }
  for (const group of ["mix", "ru", "en"] as Group[]) {
    const candidates = byGroup(group).filter((clip) => !chosen.has(clip.id));
    const shortShare = Math.round((targets.short * quota[group]) / Math.max(1, targets.total));
    for (const clip of spreadByLength(candidates, quota[group], shortShare)) chosen.add(clip.id);
  }
  // Mixed clips beyond their target are Russian dictations too: top the Russian side up with them.
  const ruSide = targets.ru + targets.mix;
  const ruChosen = [...chosen].filter((id) => sideOf(pool.find((clip) => clip.id === id)!.group) === "ru").length;
  if (ruChosen < ruSide) {
    const extra = pool.filter((clip) => clip.group !== "en" && !chosen.has(clip.id));
    for (const clip of spreadByLength(extra, ruSide - ruChosen, 0)) chosen.add(clip.id);
  }
  return chosen;
}

/** Up to `count` clips: `short` short ones first, then the rest round-robin over length bands, newest first in each. */
function spreadByLength(clips: ClipEntry[], count: number, short: number): ClipEntry[] {
  const newest = [...clips].sort((a, b) => (b.createdAt ?? "").localeCompare(a.createdAt ?? ""));
  const picked: ClipEntry[] = newest.filter(isShort).slice(0, Math.min(short, count));
  const bands = [[0, SHORT_MIN_MS], [SHORT_MIN_MS, SHORT_MAX_MS + 1], [SHORT_MAX_MS + 1, 10_000], [10_000, 20_000], [20_000, Infinity]]
    .map(([from, to]) => newest.filter((clip) => !picked.includes(clip) && (clip.audioMs ?? 0) >= from && (clip.audioMs ?? 0) < to));
  while (picked.length < count && bands.some((band) => band.length > 0)) {
    for (const band of bands) {
      const next = band.shift();
      if (next && picked.length < count) picked.push(next);
    }
  }
  return picked;
}

export interface Counts {
  ru: number;
  mix: number;
  en: number;
  short: number;
  total: number;
}

/** How many clips are in the test, and how many of those are checked, by group. */
export function countClips(clips: ClipEntry[]): { selected: Counts; checked: Counts } {
  const tally = (subset: ClipEntry[]): Counts => ({
    ru: subset.filter((clip) => clip.group === "ru").length,
    mix: subset.filter((clip) => clip.group === "mix").length,
    en: subset.filter((clip) => clip.group === "en").length,
    short: subset.filter(isShort).length,
    total: subset.length,
  });
  return { selected: tally(clips.filter(inTest)), checked: tally(clips.filter(scored)) };
}

/**
 * Adds clips to the manifest; a clip already in it keeps everything you did to it (reference,
 * checked, group, selection), and only gains what was unknown before. Returns the ids added.
 */
export function mergeClips(manifest: Manifest, incoming: ClipEntry[]): string[] {
  const added: string[] = [];
  const byId = new Map(manifest.clips.map((clip) => [clip.id, clip]));
  for (const clip of incoming) {
    const existing = byId.get(clip.id);
    if (existing) {
      existing.audioMs ??= clip.audioMs;
      existing.createdAt ??= clip.createdAt;
      existing.phoneLanguage ??= clip.phoneLanguage;
      existing.style ??= clip.style;
      continue;
    }
    manifest.clips.push(clip);
    byId.set(clip.id, clip);
    added.push(clip.id);
  }
  manifest.clips.sort((a, b) => (b.createdAt ?? "").localeCompare(a.createdAt ?? "") || a.id.localeCompare(b.id));
  return added;
}

// MARK: Audio

/** 16 kHz mono PCM16 is 32 bytes a millisecond. */
export const PCM_BYTES_PER_MS = 32;

let ffmpegPath: string | null | undefined;

/** ffmpeg, when this machine has it (the GPU box does once set up; a Mac may). */
async function ffmpeg(): Promise<string | null> {
  if (ffmpegPath !== undefined) return ffmpegPath;
  for (const candidate of ["ffmpeg", "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]) {
    try {
      const { success } = await new Deno.Command(candidate, { args: ["-version"], stdout: "null", stderr: "null" }).output();
      if (success) return ffmpegPath = candidate;
    } catch {
      // Not there: try the next.
    }
  }
  return ffmpegPath = null;
}

/**
 * A recording as what the app streams and the models hear: PCM16, mono, 16 kHz. A WAV file that
 * already is that is read as it is; anything else goes through ffmpeg when there is one, and
 * macOS's afconvert when there isn't or ffmpeg can't read it.
 */
export async function decodePcm16(path: string): Promise<Uint8Array> {
  if (/\.wav$/i.test(path)) {
    const plain = wavSamples(await Deno.readFile(path));
    if (plain) return plain;
  }
  const tool = await ffmpeg();
  if (tool) {
    const { success, stdout, stderr } = await new Deno.Command(tool, {
      args: ["-nostdin", "-loglevel", "error", "-i", path, "-f", "s16le", "-acodec", "pcm_s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
      stdout: "piped",
      stderr: "piped",
    }).output();
    if (success) return stdout;
    if (Deno.build.os !== "darwin") throw new Error(`ffmpeg could not read ${path}: ${new TextDecoder().decode(stderr).trim()}`);
  }
  const converted = await Deno.makeTempFile({ suffix: ".wav" });
  try {
    const { success, stderr } = await new Deno.Command("afconvert", {
      args: ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, converted],
      stdout: "null",
      stderr: "piped",
    }).output();
    if (!success) throw new Error(`afconvert could not read ${path}: ${new TextDecoder().decode(stderr).trim()}`);
    const pcm = wavSamples(await Deno.readFile(converted));
    if (!pcm) throw new Error(`afconvert wrote no 16 kHz PCM16 for ${path}`);
    return pcm;
  } finally {
    await Deno.remove(converted).catch(() => {});
  }
}

/** The samples of a 16 kHz mono PCM16 WAV file (plain or WAVE_FORMAT_EXTENSIBLE); null for any other. */
export function wavSamples(bytes: Uint8Array): Uint8Array | null {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (at: number) => String.fromCharCode(...bytes.subarray(at, at + 4));
  if (bytes.byteLength < 12 || tag(0) !== "RIFF" || tag(8) !== "WAVE") return null;
  let plain = false;
  for (let at = 12; at + 8 <= bytes.byteLength;) {
    const size = view.getUint32(at + 4, true);
    const body = at + 8;
    if (tag(at) === "fmt " && size >= 16 && body + 16 <= bytes.byteLength) {
      const code = view.getUint16(body, true);
      const format = code === 0xfffe && size >= 40 && body + 26 <= bytes.byteLength ? view.getUint16(body + 24, true) : code;
      plain = format === 1 && view.getUint16(body + 2, true) === 1 &&
        view.getUint32(body + 4, true) === 16000 && view.getUint16(body + 14, true) === 16;
    } else if (tag(at) === "data") {
      if (!plain) return null;
      const end = Math.min(bytes.byteLength, body + size);
      return bytes.subarray(body, end - ((end - body) % 2));
    }
    at = body + size + (size % 2);
  }
  return null;
}

/** A WAV file around PCM16 mono 16 kHz samples. */
export function wavOf(pcm: Uint8Array): Uint8Array {
  const header = new ArrayBuffer(44);
  const view = new DataView(header);
  const text = (at: number, value: string) => [...value].forEach((char, index) => view.setUint8(at + index, char.charCodeAt(0)));
  text(0, "RIFF");
  view.setUint32(4, 36 + pcm.byteLength, true);
  text(8, "WAVE");
  text(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16000, true);
  view.setUint32(28, 32000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  text(36, "data");
  view.setUint32(40, pcm.byteLength, true);
  const file = new Uint8Array(44 + pcm.byteLength);
  file.set(new Uint8Array(header), 0);
  file.set(pcm, 44);
  return file;
}

/** The content type a browser and a speech service expect for a clip's file. */
export function audioType(file: string): string {
  const extension = file.split(".").pop()?.toLowerCase();
  if (extension === "m4a" || extension === "mp4") return "audio/mp4";
  if (extension === "wav") return "audio/wav";
  if (extension === "mp3") return "audio/mpeg";
  if (extension === "aiff" || extension === "aif") return "audio/aiff";
  if (extension === "caf") return "audio/x-caf";
  return "application/octet-stream";
}

// MARK: Small helpers

/** "BFD971FA183B4A908B4F8BC176BA6705" → "BFD971FA-183B-4A90-8B4F-8BC176BA6705", as the app names files. */
export function uuidFromHex(hex: string): string | null {
  const clean = hex.replace(/[^0-9a-f]/gi, "").toUpperCase();
  if (clean.length !== 32) return null;
  return `${clean.slice(0, 8)}-${clean.slice(8, 12)}-${clean.slice(12, 16)}-${clean.slice(16, 20)}-${clean.slice(20)}`;
}

/** Core Data's timestamps count seconds from 2001-01-01. */
export function coreDataDate(seconds: number | null): string | null {
  if (seconds === null || !Number.isFinite(seconds)) return null;
  return new Date((seconds + 978_307_200) * 1000).toISOString();
}

/** `--name value` from the arguments; `undefined` when absent. */
export function flag(args: string[], name: string): string | undefined {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
}

export function seconds(ms: number | null): string {
  return ms === null ? "—" : `${(ms / 1000).toFixed(1)} s`;
}
