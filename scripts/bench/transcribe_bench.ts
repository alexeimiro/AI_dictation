// Speech-to-text and Auto-detect, measured. gpt-transcribe gets each clip twice: with no language
// (Auto-detect, the keyboard's default) and with the right one, exactly as the `transcribe` and
// `dictate` functions send them. The clips are spoken by the Mac's own voices (`say`) in ten
// languages, short and long; real recordings can be added with --real.
//
//   deno run --allow-env --allow-net --allow-read --allow-write --allow-run --env-file=supabase/functions/.env \
//     scripts/bench/transcribe_bench.ts --out <dir> [--repeat 1] [--real <dir>] [--clips-only]
//
// --real <dir>: <language>-<anything>.m4a files (ISO 639-1, "tr-meeting.m4a"), each with the
// words in a .txt of the same name. --clips-only makes the clips and stops: no OpenAI calls.
import { DEFAULT_TRANSCRIBE_MODEL, transcribeWithOpenAI } from "../../supabase/functions/_shared/transcribe.ts";
import { mean, percentile } from "./models.ts";

interface Clip {
  /** ISO 639-1, as OpenAI reports it. */
  language: string;
  kind: string;
  text: string;
  path: string;
}

/** Phrases a person might dictate: one of 2–4 words, where Auto-detect slips most, and a long one. */
const PHRASES: { language: string; voice: string; short: string; long: string }[] = [
  {
    language: "en", voice: "Samantha", short: "See you tomorrow.",
    long: "I think we should move the meeting to Thursday afternoon, because half of the team is traveling on Wednesday.",
  },
  {
    language: "ru", voice: "Milena", short: "Увидимся завтра.",
    long: "Я думаю, нам стоит перенести встречу на четверг, потому что половина команды в среду в командировке.",
  },
  {
    language: "uk", voice: "Lesya", short: "Побачимося завтра.",
    long: "Я думаю, нам варто перенести зустріч на четвер, бо половина команди в середу у відрядженні.",
  },
  {
    language: "tr", voice: "Yelda", short: "Yarın görüşürüz.",
    long: "Bence toplantıyı perşembe öğleden sonraya ertelemeliyiz, çünkü ekibin yarısı çarşamba günü seyahatte.",
  },
  {
    language: "zh", voice: "Tingting", short: "明天见。",
    long: "我觉得我们应该把会议改到星期四下午，因为一半的同事星期三要出差。",
  },
  {
    language: "ja", voice: "Kyoko", short: "また明日。",
    long: "チームの半分が水曜日に出張するので、会議を木曜日の午後に変更したほうがいいと思います。",
  },
  {
    language: "es", voice: "Mónica", short: "Nos vemos mañana.",
    long: "Creo que deberíamos mover la reunión al jueves por la tarde, porque la mitad del equipo viaja el miércoles.",
  },
  {
    language: "de", voice: "Anna", short: "Bis morgen.",
    long: "Ich finde, wir sollten das Meeting auf Donnerstagnachmittag verschieben, weil das halbe Team am Mittwoch unterwegs ist.",
  },
  {
    language: "ar", voice: "Majed", short: "أراك غدا.",
    long: "أعتقد أنه يجب علينا نقل الاجتماع إلى يوم الخميس بعد الظهر، لأن نصف الفريق مسافر يوم الأربعاء.",
  },
  {
    language: "hi", voice: "Lekha", short: "कल मिलते हैं।",
    long: "मुझे लगता है कि हमें मीटिंग को गुरुवार दोपहर पर ले जाना चाहिए, क्योंकि आधी टीम बुधवार को यात्रा कर रही है।",
  },
];

async function run(command: string, args: string[]): Promise<void> {
  const { code, stderr } = await new Deno.Command(command, { args, stdout: "null", stderr: "piped" }).output();
  if (code !== 0) throw new Error(`${command} failed: ${new TextDecoder().decode(stderr)}`);
}

/** Speaks `text` into an AAC .m4a, the format the app uploads. */
async function speak(voice: string, text: string, path: string): Promise<void> {
  const aiff = path.replace(/\.m4a$/, ".aiff");
  await run("say", ["-v", voice, "-o", aiff, text]);
  await run("afconvert", ["-f", "m4af", "-d", "aac", aiff, path]);
  await Deno.remove(aiff);
}

async function makeClips(directory: string): Promise<Clip[]> {
  await Deno.mkdir(directory, { recursive: true });
  const clips: Clip[] = [];
  for (const phrase of PHRASES) {
    for (const [kind, text] of [["short", phrase.short], ["long", phrase.long]] as const) {
      const path = `${directory}/${phrase.language}-${kind}.m4a`;
      await speak(phrase.voice, text, path);
      clips.push({ language: phrase.language, kind, text, path });
    }
  }
  return clips;
}

async function realClips(directory: string): Promise<Clip[]> {
  const clips: Clip[] = [];
  for await (const entry of Deno.readDir(directory)) {
    if (!entry.isFile || !entry.name.endsWith(".m4a")) continue;
    const path = `${directory}/${entry.name}`;
    const text = await Deno.readTextFile(path.replace(/\.m4a$/, ".txt")).catch(() => null);
    if (text === null) continue;
    clips.push({ language: entry.name.split("-")[0].toLowerCase(), kind: "real", text: text.trim(), path });
  }
  return clips;
}

/** Letters and digits only; no spaces at all for Chinese and Japanese, which are written without them. */
function normalized(text: string, language: string): string {
  const letters = text.normalize("NFC").toLowerCase().replace(/[\p{P}\p{S}]+/gu, " ");
  return language === "zh" || language === "ja"
    ? letters.replace(/\s+/g, "")
    : letters.replace(/\s+/g, " ").trim();
}

/** Character error rate: edit distance over the expected length. */
function cer(expected: string, heard: string): number {
  const a = Array.from(expected);
  const b = Array.from(heard);
  if (a.length === 0) return b.length === 0 ? 0 : 1;
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i++) {
    const current = [i];
    for (let j = 1; j <= b.length; j++) {
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[b.length] / a.length;
}

interface Heard {
  clip: Clip;
  mode: "auto" | "hinted";
  repeat: number;
  text: string;
  detected: string | null;
  cer: number;
  ms: number;
  error?: string;
}

async function transcribe(clip: Clip, mode: Heard["mode"], repeat: number, apiKey: string): Promise<Heard> {
  const audio = await Deno.readFile(clip.path) as Uint8Array<ArrayBuffer>;
  const started = performance.now();
  try {
    const result = await transcribeWithOpenAI(
      { dictationId: null, audio, format: "m4a", language: mode === "hinted" ? clip.language : null, keywords: [] },
      { apiKey, model: DEFAULT_TRANSCRIBE_MODEL, deadlineMs: 20_000 },
    );
    return {
      clip, mode, repeat, text: result.text, detected: result.languages[0]?.split("-")[0].toLowerCase() ?? null,
      cer: cer(normalized(clip.text, clip.language), normalized(result.text, clip.language)),
      ms: Math.round(performance.now() - started),
    };
  } catch (error) {
    return {
      clip, mode, repeat, text: "", detected: null, cer: 1, ms: Math.round(performance.now() - started),
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

function pct(value: number | null): string {
  return value === null ? "—" : `${(value * 100).toFixed(1)}%`;
}

function report(results: Heard[]): string {
  const languages = [...new Set(results.map((result) => result.clip.language))];
  const lines = [
    `# Speech-to-text: Auto-detect vs a chosen language (${new Date().toISOString().slice(0, 10)})`,
    "",
    `${DEFAULT_TRANSCRIBE_MODEL}, each clip with no language (Auto) and with the right one (Hinted). ` +
    "Detected: the first language OpenAI reports equals the clip's. CER: character error rate. ms: the request from this Mac.",
    "",
    "| Language | Detected (Auto) | CER Auto | CER Hinted | p50 ms Auto | p50 ms Hinted | Misheard as |",
    "|---|---|---|---|---|---|---|",
  ];
  const row = (label: string, subset: Heard[]) => {
    const auto = subset.filter((result) => result.mode === "auto");
    const hinted = subset.filter((result) => result.mode === "hinted");
    const right = auto.filter((result) => result.detected === result.clip.language).length;
    const wrong = [...new Set(auto.filter((r) => r.detected !== r.clip.language).map((r) => r.detected ?? "none"))];
    lines.push(`| ${label} | ${right}/${auto.length} | ${pct(mean(auto.map((r) => r.cer)))} | ` +
      `${pct(mean(hinted.map((r) => r.cer)))} | ${percentile(auto.map((r) => r.ms), 50) ?? "—"} | ` +
      `${percentile(hinted.map((r) => r.ms), 50) ?? "—"} | ${wrong.join(", ") || "—"} |`);
  };
  for (const language of languages) row(language, results.filter((result) => result.clip.language === language));
  row("**all**", results);
  const shorts = results.filter((result) => result.clip.kind === "short");
  if (shorts.length > 0) row("short clips", shorts);
  lines.push("", "## Each clip");
  for (const result of results.filter((r) => r.mode === "auto")) {
    lines.push(`- ${result.clip.language}-${result.clip.kind} #${result.repeat}: heard ${result.detected ?? "none"}, ` +
      `CER ${pct(result.cer)} → ${JSON.stringify(result.error ?? result.text)}`);
  }
  return lines.join("\n") + "\n";
}

async function main() {
  let out: string | undefined, real: string | undefined, repeat = 1, clipsOnly = false;
  for (let index = 0; index < Deno.args.length; index++) {
    const flag = Deno.args[index];
    if (flag === "--out") out = Deno.args[++index];
    else if (flag === "--real") real = Deno.args[++index];
    else if (flag === "--repeat") repeat = Math.max(1, Number(Deno.args[++index]) || 1);
    else if (flag === "--clips-only") clipsOnly = true;
    else throw new Error(`unknown flag ${flag}`);
  }
  if (!out) throw new Error("--out <dir> is required");
  const clips = [...await makeClips(`${out}/clips`), ...(real ? await realClips(real) : [])];
  console.log(`${clips.length} clips in ${out}/clips${real ? ` and ${real}` : ""}`);
  if (clipsOnly) return;
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) throw new Error("OPENAI_API_KEY is not set");

  const results: Heard[] = [];
  for (let round = 1; round <= repeat; round++) {
    for (const clip of clips) {
      for (const mode of ["auto", "hinted"] as const) {
        const heard = await transcribe(clip, mode, round, apiKey);
        results.push(heard);
        console.log(`${clip.language}-${clip.kind} ${mode} #${round}: ${heard.detected ?? "none"} ` +
          `CER ${pct(heard.cer)} ${heard.ms} ms${heard.error ? ` (${heard.error})` : ""}`);
      }
    }
  }
  const markdown = report(results);
  await Deno.writeTextFile(`${out}/transcription.json`, JSON.stringify(results.map(({ clip, ...rest }) => ({
    ...rest, language: clip.language, kind: clip.kind, expected: clip.text,
  })), null, 2));
  await Deno.writeTextFile(`${out}/transcription.md`, markdown);
  console.log(`\n${markdown}`);
}

if (import.meta.main) await main();
