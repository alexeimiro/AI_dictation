// Does OpenAI accept every language Murmur offers to speak? gpt-transcribe publishes no language
// list, and its guide says it rejects a code it doesn't support. This sends one second of silence
// per language in `DictationLanguage.speechLanguages` (read from the Swift source, so the list is
// never copied), with that language as `languages[]`, exactly as `transcribe` and `dictate` send it,
// and reports each answer. It calls OpenAI directly, not through `transcribeWithOpenAI`, whose retry
// without the language would hide a refusal. About 65 requests of one second: under $0.01.
//
//   deno run --allow-env --allow-net --allow-read --env-file=supabase/functions/.env \
//     scripts/bench/language_probe.ts [--model gpt-transcribe]
//
// Exit status 1 when any language is refused: take it out of `speechLanguages` (it can stay a
// translation target) or map its code in `isoLanguage`.
import { DEFAULT_TRANSCRIBE_MODEL, isoLanguage, openAIForm } from "../../supabase/functions/_shared/transcribe.ts";

const SWIFT_SOURCE = new URL("../../Packages/MurmurKit/Sources/MurmurCore/Text/DictationLanguage.swift", import.meta.url);

/** The tags of a `public static let <name>: [DictationLanguage] = [ "…", … ]` list in the Swift source. */
export function swiftLanguageList(source: string, name: string): string[] {
  const start = source.indexOf(`static let ${name}: [DictationLanguage] = [`);
  if (start < 0) throw new Error(`${name} not found in DictationLanguage.swift`);
  const end = source.indexOf("]", source.indexOf("[", source.indexOf("=", start)));
  const body = source.slice(source.indexOf("[", source.indexOf("=", start)) + 1, end);
  return [...body.matchAll(/"([A-Za-z0-9-]+)"/g)].map((match) => match[1]);
}

/** What the server sends OpenAI for each speech language: `isoLanguage`, as `transcribe` maps it. */
export function probeCodes(tags: string[]): { tag: string; code: string | null }[] {
  return tags.map((tag) => ({ tag, code: isoLanguage(tag) }));
}

/** One second of 16 kHz mono 16-bit silence as a WAV file. */
export function silentWav(seconds = 1, rate = 16_000): Uint8Array<ArrayBuffer> {
  const samples = seconds * rate;
  const bytes = new Uint8Array(44 + samples * 2);
  const view = new DataView(bytes.buffer);
  const ascii = (offset: number, text: string) => [...text].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
  ascii(0, "RIFF");
  view.setUint32(4, 36 + samples * 2, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); // PCM
  view.setUint16(22, 1, true); // mono
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, "data");
  view.setUint32(40, samples * 2, true);
  return bytes;
}

async function main() {
  const apiKey = Deno.env.get("OPENAI_API_KEY");
  if (!apiKey) {
    console.error("OPENAI_API_KEY is not set (put it in supabase/functions/.env and pass --env-file).");
    Deno.exit(2);
  }
  const modelFlag = Deno.args.indexOf("--model");
  const model = modelFlag >= 0 ? Deno.args[modelFlag + 1] : DEFAULT_TRANSCRIBE_MODEL;
  const tags = swiftLanguageList(await Deno.readTextFile(SWIFT_SOURCE), "speechLanguages");
  const audio = silentWav();
  const refused: string[] = [];
  console.log(`${tags.length} speech languages, model ${model}`);
  for (const { tag, code } of probeCodes(tags)) {
    if (!code) {
      refused.push(tag);
      console.log(`${tag.padEnd(8)} —      no code the server would send`);
      continue;
    }
    const form = openAIForm(
      { dictationId: null, audio, format: "wav", language: code, languageHints: [], keywords: [] },
      model,
    );
    const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}` },
      body: form,
      signal: AbortSignal.timeout(30_000),
    });
    const body = await response.json().catch(() => null) as
      | { error?: { code?: string; type?: string; message?: string }; languages?: { code?: string }[] }
      | null;
    if (response.ok) {
      console.log(`${tag.padEnd(8)} ${code.padEnd(6)} accepted`);
    } else {
      refused.push(tag);
      const reason = body?.error?.code ?? body?.error?.type ?? "";
      console.log(`${tag.padEnd(8)} ${code.padEnd(6)} HTTP ${response.status} ${reason} ${body?.error?.message ?? ""}`);
    }
  }
  console.log(refused.length === 0 ? "Every speech language was accepted." : `Refused: ${refused.join(", ")}`);
  Deno.exit(refused.length === 0 ? 0 : 1);
}

if (import.meta.main) await main();
