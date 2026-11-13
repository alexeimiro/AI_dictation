// Gets your recordings off the iPhone for the model test, with the text the phone typed for each,
// and picks a first set of about 40 for you to correct on the correction page.
//
//   deno run --allow-run --allow-read --allow-write --allow-env scripts/model_test/pull_phone.ts --device "<name or id>"
//     [--dir scripts/out/model_test] [--days 30] [--yes] [--keep-pull]
//
// What it does on the phone: one read. It copies Murmur's own folder out of the app's container
// (`xcrun devicectl device copy from`): the history (History.store) and the recordings kept by
// Settings › Keep recordings. Nothing on the phone changes. Only a development build's files can
// be read this way: a TestFlight or App Store build refuses, and this says so. The iPhone must be
// unlocked, and connected by cable or on the same Wi-Fi.
//
// Then, on the Mac: every dictation with a recording and some text becomes a clip in
// <dir>/clips.json, its audio copied to <dir>/audio/. The copy of the history is deleted afterwards
// (it holds every text you ever dictated), unless --keep-pull. Run it again later to add newer
// dictations: what you already did to a clip stays.
//
// Two other sources, for the Mac test or for recordings you have as files:
//   --from-dir <folder>    a folder laid out like the app's: History.store (with -wal and -shm) and Recordings/
//   --from-clips <folder>  <group>-<name>.m4a|wav|aiff|caf|mp3 with <group>-<name>.txt beside it (the text the
//                          phone typed, or any first draft); the group, ru, en or mix, when the name starts with one
//
// --days keeps only dictations from the last that many days.
import {
  audioType,
  type ClipEntry,
  coreDataDate,
  countClips,
  decodePcm16,
  DEFAULT_DIR,
  flag,
  type Group,
  guessGroup,
  type Manifest,
  mergeClips,
  PCM_BYTES_PER_MS,
  readManifest,
  chooseTestSet,
  uuidFromHex,
  writeManifest,
} from "./clips.ts";

/** Murmur's bundle id and the folder its history and recordings live in, inside the app's container. */
export const BUNDLE_ID = "com.antonmironenko.murmur";
export const MURMUR_FOLDER = "Library/Application Support/Murmur";

/** The history's statuses whose dictations have a transcript worth testing against. */
const USABLE_STATUSES = new Set(["raw", "cleaned", "limitReached"]);
const AUDIO_EXTENSIONS = /\.(m4a|wav|aiff?|caf|mp3)$/i;

/** One row of the app's history (SwiftData's table ZTRANSCRIPTRECORD), as sqlite3 -json gives it. */
export interface HistoryRow {
  id: string;
  ZCREATEDAT: number | null;
  ZLANGUAGE: string | null;
  ZSTYLE: string | null;
  ZRAWTEXT: string | null;
  ZSTATUS: string | null;
  ZSOURCE: string | null;
  ZAUDIOSECONDS: number | null;
}

const HISTORY_QUERY = "select hex(ZID) as id, ZCREATEDAT, ZLANGUAGE, ZSTYLE, ZRAWTEXT, ZSTATUS, ZSOURCE, ZAUDIOSECONDS " +
  "from ZTRANSCRIPTRECORD";

/** The history's rows, read from a copy of History.store (its -wal and -shm beside it). */
export async function readHistory(storePath: string): Promise<HistoryRow[]> {
  const { success, stdout, stderr } = await new Deno.Command("sqlite3", {
    args: ["-json", storePath, HISTORY_QUERY],
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!success) throw new Error(`sqlite3 could not read ${storePath}: ${new TextDecoder().decode(stderr).trim()}`);
  const text = new TextDecoder().decode(stdout).trim();
  // sqlite3 prints nothing at all for a query with no rows.
  return text ? JSON.parse(text) as HistoryRow[] : [];
}

/**
 * The clips a pulled folder makes: each history row with a usable transcript and a recording.
 * `recordings` maps a dictation's id (uppercase UUID) to its file name; `since` drops older ones.
 */
export function clipsFromHistory(
  rows: HistoryRow[],
  recordings: Map<string, string>,
  source: string,
  since: Date | null = null,
): { clips: ClipEntry[]; skipped: Record<string, number> } {
  const skipped: Record<string, number> = { "no recording": 0, "no text": 0, "failed or empty": 0, "older": 0 };
  const clips: ClipEntry[] = [];
  for (const row of rows) {
    const id = uuidFromHex(row.id);
    if (!id) continue;
    const text = (row.ZRAWTEXT ?? "").trim();
    const createdAt = coreDataDate(row.ZCREATEDAT);
    if (!USABLE_STATUSES.has(row.ZSTATUS ?? "")) {
      skipped["failed or empty"]++;
      continue;
    }
    if (!text) {
      skipped["no text"]++;
      continue;
    }
    if (since && createdAt && new Date(createdAt) < since) {
      skipped["older"]++;
      continue;
    }
    const file = recordings.get(id);
    if (!file) {
      skipped["no recording"]++;
      continue;
    }
    const extension = file.split(".").pop()!.toLowerCase();
    clips.push({
      id,
      file: `audio/${id}.${extension}`,
      source,
      createdAt,
      audioMs: row.ZAUDIOSECONDS && row.ZAUDIOSECONDS > 0 ? Math.round(row.ZAUDIOSECONDS * 1000) : null,
      phoneText: text,
      phoneLanguage: row.ZLANGUAGE,
      style: row.ZSTYLE,
      group: guessGroup(text, row.ZLANGUAGE),
      selected: false,
      excluded: false,
      reference: null,
      checked: false,
      tags: [],
      note: "",
    });
  }
  return { clips, skipped };
}

/** The recordings in a folder, by the dictation id their name carries. */
export async function recordingFiles(folder: string): Promise<Map<string, string>> {
  const files = new Map<string, string>();
  try {
    for await (const entry of Deno.readDir(folder)) {
      if (!entry.isFile || !AUDIO_EXTENSIONS.test(entry.name)) continue;
      const id = uuidFromHex(entry.name.replace(AUDIO_EXTENSIONS, ""));
      if (id) files.set(id, entry.name);
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error;
  }
  return files;
}

/** The first file named `name` under `folder`, however deep: where a copy put the history. */
export async function findFile(folder: string, name: string): Promise<string | null> {
  for await (const entry of Deno.readDir(folder)) {
    const path = `${folder}/${entry.name}`;
    if (entry.isFile && entry.name === name) return path;
    if (entry.isDirectory) {
      const found = await findFile(path, name);
      if (found) return found;
    }
  }
  return null;
}

/** Reads a pulled Murmur folder: its history and recordings become clips, their audio copied into `dir`. */
export async function importMurmurFolder(folder: string, dir: string, source: string, since: Date | null) {
  const store = await findFile(folder, "History.store");
  if (!store) throw new Error(`no History.store under ${folder}`);
  const base = store.slice(0, store.lastIndexOf("/"));
  const rows = await readHistory(store);
  const recordings = await recordingFiles(`${base}/Recordings`);
  const { clips, skipped } = clipsFromHistory(rows, recordings, source, since);
  await Deno.mkdir(`${dir}/audio`, { recursive: true });
  for (const clip of clips) {
    await Deno.copyFile(`${base}/Recordings/${recordings.get(clip.id)}`, `${dir}/${clip.file}`);
  }
  return { clips, skipped, rows: rows.length, recordings: recordings.size };
}

/** Reads a folder of `<group>-<name>.<audio>` + `.txt` pairs; their audio is measured and copied into `dir`. */
export async function importClipFolder(folder: string, dir: string, source: string): Promise<ClipEntry[]> {
  const clips: ClipEntry[] = [];
  await Deno.mkdir(`${dir}/audio`, { recursive: true });
  const names: string[] = [];
  for await (const entry of Deno.readDir(folder)) {
    if (entry.isFile && AUDIO_EXTENSIONS.test(entry.name)) names.push(entry.name);
  }
  for (const name of names.sort()) {
    const stem = name.replace(AUDIO_EXTENSIONS, "");
    const text = await Deno.readTextFile(`${folder}/${stem}.txt`).catch(() => null);
    if (text === null || !text.trim()) continue;
    const prefix = stem.match(/^(ru|en|mix)-/i)?.[1].toLowerCase() as Group | undefined;
    const pcm = await decodePcm16(`${folder}/${name}`);
    const file = `audio/${stem}.${name.split(".").pop()!.toLowerCase()}`;
    await Deno.copyFile(`${folder}/${name}`, `${dir}/${file}`);
    const stat = await Deno.stat(`${folder}/${name}`);
    clips.push({
      id: stem,
      file,
      source,
      createdAt: stat.mtime?.toISOString() ?? null,
      audioMs: Math.round(pcm.byteLength / PCM_BYTES_PER_MS),
      phoneText: text.trim(),
      phoneLanguage: null,
      style: null,
      group: prefix ?? guessGroup(text, null),
      selected: false,
      excluded: false,
      reference: null,
      checked: false,
      tags: [],
      note: "",
    });
  }
  return clips;
}

// MARK: The phone

interface DeviceInfo {
  identifier: string;
  name: string;
  model: string;
  state: string;
}

/** The devices `devicectl list devices --json-output` knows, as far as this needs them. */
export function parseDevices(json: unknown): DeviceInfo[] {
  const devices = (json as { result?: { devices?: unknown[] } })?.result?.devices;
  if (!Array.isArray(devices)) return [];
  return devices.map((device) => {
    const item = device as Record<string, Record<string, unknown> | string | undefined>;
    const properties = (item.deviceProperties ?? {}) as Record<string, unknown>;
    const hardware = (item.hardwareProperties ?? {}) as Record<string, unknown>;
    const connection = (item.connectionProperties ?? {}) as Record<string, unknown>;
    return {
      identifier: String(item.identifier ?? ""),
      name: String(properties.name ?? ""),
      model: String(hardware.marketingName ?? hardware.productType ?? ""),
      state: [connection.transportType, connection.tunnelState].filter(Boolean).join(", ") || "unknown",
    };
  });
}

async function devicectl(args: string[], timeoutSeconds = 600): Promise<{ ok: boolean; json: unknown; error: string }> {
  const output = await Deno.makeTempFile({ suffix: ".json" });
  try {
    const { success, stderr } = await new Deno.Command("xcrun", {
      args: ["devicectl", ...args, "--timeout", String(timeoutSeconds), "--json-output", output, "--quiet"],
      stdout: "null",
      stderr: "piped",
    }).output();
    const json = await Deno.readTextFile(output).then(JSON.parse).catch(() => null);
    const error = (json as { error?: { userInfo?: Record<string, { string?: string }> } })?.error?.userInfo?.NSLocalizedDescription?.string ??
      new TextDecoder().decode(stderr).trim();
    return { ok: success, json, error };
  } finally {
    await Deno.remove(output).catch(() => {});
  }
}

/** Every file under `folder` in the app's container, from `devicectl device info files`. */
function listedFiles(json: unknown): string[] {
  const paths: string[] = [];
  const visit = (value: unknown) => {
    if (Array.isArray(value)) return value.forEach(visit);
    if (typeof value !== "object" || value === null) return;
    const item = value as Record<string, unknown>;
    const path = item.relativePath ?? item.path ?? item.name;
    if (typeof path === "string" && (path.includes("History.store") || AUDIO_EXTENSIONS.test(path))) paths.push(path);
    Object.values(item).forEach(visit);
  };
  visit(json);
  return [...new Set(paths)];
}

/** Copies Murmur's folder off the phone into `pull`; throws with a plain reason when the phone refuses. */
async function copyFromPhone(device: string, pull: string): Promise<void> {
  const common = ["--device", device, "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE_ID];
  const whole = await devicectl(["device", "copy", "from", ...common, "--source", MURMUR_FOLDER, "--destination", `${pull}/Murmur`]);
  if (whole.ok && await findFile(pull, "History.store").catch(() => null)) return;
  // Some versions copy one file at a time: list the folder, then copy what the test needs.
  const listing = await devicectl(["device", "info", "files", ...common, "--subdirectory", MURMUR_FOLDER]);
  if (!listing.ok) throw new Error(explain(whole.error || listing.error));
  const files = listedFiles(listing.json);
  if (!files.some((path) => path.endsWith("History.store"))) throw new Error(explain(whole.error || "History.store wasn't listed"));
  for (const path of files) {
    const relative = path.includes("Murmur/") ? path.slice(path.lastIndexOf("Murmur/") + "Murmur/".length) : path;
    const target = `${pull}/Murmur/${relative}`;
    await Deno.mkdir(target.slice(0, target.lastIndexOf("/")), { recursive: true });
    const copied = await devicectl(["device", "copy", "from", ...common, "--source", `${MURMUR_FOLDER}/${relative}`, "--destination", target]);
    if (!copied.ok && relative.startsWith("History.store")) throw new Error(explain(copied.error));
  }
}

function explain(error: string): string {
  if (/not.*(debug|develop)|permission|not permitted|access/i.test(error)) {
    return `the phone refused to share Murmur's files (${error}). Only a development build's files can be read: ` +
      "a TestFlight or App Store build can't. Install a development build first (scripts/device_build.sh), or AirDrop the files.";
  }
  if (/unavailable|not found|no device|locked/i.test(error)) {
    return `the phone isn't reachable (${error}). Unlock it, connect it by cable or put it on the same Wi-Fi, and try again.`;
  }
  return error || "devicectl failed without a reason";
}

// MARK: Main

function summary(manifest: Manifest, added: number, dir: string): string {
  const { selected, checked } = countClips(manifest.clips);
  const targets = manifest.targets;
  return [
    `${manifest.clips.length} clips in ${dir}/clips.json (${added} new).`,
    `In the test: ${selected.total} of ${targets.total} — Russian ${selected.ru}/${targets.ru}, mixed ${selected.mix}/${targets.mix}, ` +
    `English ${selected.en}/${targets.en}, short (2–5 s) ${selected.short}/${targets.short}. Checked: ${checked.total}.`,
    "",
    "Next: correct the texts on the correction page:",
    `  deno run --allow-net=127.0.0.1 --allow-read --allow-write scripts/model_test/review.ts --dir ${dir}`,
  ].join("\n");
}

/** One line on what a pulled folder held and what was left out, and why. */
function describeImport(result: Awaited<ReturnType<typeof importMurmurFolder>>): string {
  const left = Object.entries(result.skipped).filter(([, n]) => n > 0).map(([why, n]) => `${n} ${why}`).join(", ");
  return `History: ${result.rows} dictations; recordings: ${result.recordings}; usable: ${result.clips.length}; left out: ${left || "none"}.`;
}

async function confirm(question: string): Promise<boolean> {
  const answer = prompt(`${question} [y/N]`);
  return /^y(es)?$/i.test(answer?.trim() ?? "");
}

if (import.meta.main) {
  const args = Deno.args;
  const dir = flag(args, "--dir") ?? DEFAULT_DIR;
  const days = Number(flag(args, "--days"));
  const since = Number.isFinite(days) && days > 0 ? new Date(Date.now() - days * 86_400_000) : null;
  const device = flag(args, "--device");
  const fromDir = flag(args, "--from-dir");
  const fromClips = flag(args, "--from-clips");
  if ([device, fromDir, fromClips].filter(Boolean).length !== 1) {
    console.error("Give one source: --device <name or id>, --from-dir <folder> or --from-clips <folder>.");
    Deno.exit(2);
  }
  await Deno.mkdir(dir, { recursive: true });
  const manifest = await readManifest(dir);
  const stamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 16);
  let incoming: ClipEntry[];

  if (device) {
    const list = await devicectl(["list", "devices"], 60);
    const known = parseDevices(list.json).find((item) => [item.identifier, item.name].includes(device));
    const label = known ? `${known.name} (${known.model}, ${known.state})` : device;
    console.log(`This copies Murmur's history and kept recordings from ${label} to ${dir}/phone/${stamp}/.`);
    console.log("Nothing on the phone changes. The phone must be unlocked.");
    if (!args.includes("--yes") && !await confirm("Go on?")) Deno.exit(1);
    const pull = `${dir}/phone/${stamp}`;
    await Deno.mkdir(pull, { recursive: true });
    try {
      await copyFromPhone(device, pull);
    } catch (error) {
      console.error(`Couldn't copy from the phone: ${error instanceof Error ? error.message : error}`);
      await Deno.remove(pull, { recursive: true }).catch(() => {});
      await Deno.remove(`${dir}/phone`).catch(() => {});
      Deno.exit(1);
    }
    const source = `${known?.name ?? device}, pulled ${stamp.replace(/-(\d\d)-(\d\d)$/, " $1:$2")}`;
    const result = await importMurmurFolder(pull, dir, source, since);
    console.log(describeImport(result));
    incoming = result.clips;
    if (!args.includes("--keep-pull")) {
      await Deno.remove(pull, { recursive: true });
      // The folder the copies go in, once it is empty.
      await Deno.remove(`${dir}/phone`).catch(() => {});
    }
  } else if (fromDir) {
    const result = await importMurmurFolder(fromDir, dir, `folder ${fromDir.split("/").filter(Boolean).pop()}`, since);
    console.log(describeImport(result));
    incoming = result.clips;
  } else {
    incoming = await importClipFolder(fromClips!, dir, `folder ${fromClips!.split("/").filter(Boolean).pop()}`);
    console.log(`${incoming.length} clips with a text in ${fromClips}.`);
  }

  const added = mergeClips(manifest, incoming);
  // A first set only when you haven't chosen one: later pulls just add clips to choose from.
  if (!manifest.clips.some((clip) => clip.selected)) {
    const chosen = chooseTestSet(manifest.clips, manifest.targets);
    for (const clip of manifest.clips) clip.selected = chosen.has(clip.id);
  }
  // Every clip's audio type is one a browser plays, or the page will say so.
  const odd = manifest.clips.filter((clip) => audioType(clip.file) === "application/octet-stream");
  if (odd.length > 0) console.warn(`${odd.length} clips have a file type a browser may not play.`);
  await writeManifest(dir, manifest);
  console.log(summary(manifest, added.length, dir));
}
