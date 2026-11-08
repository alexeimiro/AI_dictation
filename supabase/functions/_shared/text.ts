const PLACEHOLDER = /⟦s:[0-9a-f]{8}⟧/g;

/** Locale-aware word count; works for languages without spaces (Chinese, Japanese). */
export function countWords(text: string, locale = "en"): number {
  let segmenter: Intl.Segmenter;
  try {
    segmenter = new Intl.Segmenter(locale, { granularity: "word" });
  } catch {
    segmenter = new Intl.Segmenter("en", { granularity: "word" });
  }
  let count = 0;
  for (const segment of segmenter.segment(text.replace(PLACEHOLDER, " "))) {
    if (segment.isWordLike) count++;
  }
  return count;
}

/**
 * Phrases a chat assistant starts with when it answers or refuses instead of cleaning up.
 * JavaScript's `\b` is ASCII-only (it never matches after a Cyrillic letter), so word ends are
 * written as `(?![\p{L}\p{N}_])` with the `u` flag. The Russian patterns are deliberately
 * narrow: a bare «Конечно» or «Вот» is ordinary dictation.
 */
const ASSISTANT_OPENERS = [
  /^(sure|certainly|of course|absolutely)[,!. ]/iu,
  /^here(?:'|’)s(?![\p{L}\p{N}_])/iu,
  /^i(?:'|’)m sorry(?![\p{L}\p{N}_])/iu,
  /^i can(?:'|’)?t(?![\p{L}\p{N}_])/iu,
  /^as an ai(?![\p{L}\p{N}_])/iu,
  /^great question(?![\p{L}\p{N}_])/iu,
  /^(конечно|разумеется|безусловно)[,!.]?\s+вот(?![\p{L}\p{N}_])/iu,
  /^вот\s+(ваш|твой|исправленн|очищенн|готов)/iu,
  /^(извините|простите|к сожалению)[,!.]?\s+(но\s+)?я\s+не\s+могу(?![\p{L}\p{N}_])/iu,
  /^я\s+не\s+могу(?![\p{L}\p{N}_])/iu,
  /^как\s+(ии|языковая модель|ассистент)(?![\p{L}\p{N}_])/iu,
  /^отличный вопрос(?![\p{L}\p{N}_])/iu,
];

export type GuardReason = "empty" | "too_long" | "assistant_reply" | "script_changed" | "untranslated";
export type GuardResult = { ok: true } | { ok: false; reason: GuardReason };

/** Share of letters written in Cyrillic, or null when there are too few letters (< 20) to judge. */
export function cyrillicShare(text: string): number | null {
  const letters = text.match(/\p{L}/gu)?.length ?? 0;
  if (letters < 20) return null;
  const cyrillic = text.match(/\p{Script=Cyrillic}/gu)?.length ?? 0;
  return cyrillic / letters;
}

/**
 * Catches outputs that aren't a cleanup of the transcript: the model answered a dictated
 * question, refused, produced something much longer than what was said, or translated or
 * transliterated the text into another script.
 */
export function guardOutput(transcript: string, output: string, locale = "en"): GuardResult {
  const inputWords = countWords(transcript, locale);
  const outputWords = countWords(output, locale);
  if (outputWords === 0 && inputWords >= 3) return { ok: false, reason: "empty" };
  if (outputWords > Math.max(12, Math.ceil(inputWords * 1.8))) return { ok: false, reason: "too_long" };

  const trimmedOutput = output.trimStart();
  const trimmedInput = transcript.trimStart();
  for (const opener of ASSISTANT_OPENERS) {
    if (opener.test(trimmedOutput) && !opener.test(trimmedInput)) {
      return { ok: false, reason: "assistant_reply" };
    }
  }

  // Script shift: a Cyrillic transcript coming back in Latin letters (or the reverse) is a
  // translation or transliteration, never a cleanup. Legitimately mixed outputs such as
  // «Пулл-реквест на GitHub» keep a share between the thresholds and pass.
  const inputShare = cyrillicShare(transcript);
  const outputShare = cyrillicShare(output);
  if (inputShare !== null && outputShare !== null) {
    if ((inputShare >= 0.7 && outputShare < 0.3) || (inputShare < 0.3 && outputShare >= 0.7)) {
      return { ok: false, reason: "script_changed" };
    }
  }
  return { ok: true };
}

/** A translation's language pair as normalized BCP-47 tags; no source when it is auto-detected. */
export interface LanguagePair {
  source?: string | null;
  target: string;
}

/**
 * The guard for translations. Catches an output that is empty, far longer than what was said (an
 * answer rather than a translation), or still in the language that was spoken: the model cleaned
 * the transcript up but did not translate it. A translation legitimately changes the script and
 * may open like an assistant ("Of course, here's my report"), so those cleanup checks don't apply.
 */
export function guardTranslation(transcript: string, output: string, languages: LanguagePair): GuardResult {
  const inputWords = countWords(transcript, languages.source ?? "en");
  const outputWords = countWords(output, languages.target);
  if (outputWords === 0 && inputWords >= 3) return { ok: false, reason: "empty" };
  // Word counts shift between languages (Turkish or Korean into English can double them), so the
  // bound is looser than cleanup's; an answer instead of a translation still runs past it.
  if (outputWords > Math.max(20, Math.ceil(inputWords * 3))) return { ok: false, reason: "too_long" };
  if (isUntranslated(transcript, output, languages)) return { ok: false, reason: "untranslated" };
  return { ok: true };
}

/**
 * True when a translation is still in the language that was spoken.
 *
 * - The transcript is mostly in another script than the target's (Russian → English, English →
 *   Japanese): the output's letters must move to the target's script. Brands, code and URLs stay
 *   Latin, so a translation into Cyrillic may keep a lot of Latin; when the share moved only part
 *   of the way, the words decide, since a cleanup that wrote «гитхаб» as GitHub kept the rest.
 * - The transcript is in the target's script and so is the declared source language (English →
 *   Turkish, Russian → Ukrainian): a translation keeps few of the transcript's words (names,
 *   loanwords), while a cleanup keeps nearly all of them.
 *
 * Anything else passes, because the speaker may simply have spoken the target language: the
 * source was auto-detected, or the transcript isn't written in the source language's script.
 */
export function isUntranslated(transcript: string, output: string, languages: LanguagePair): boolean {
  const targetScript = scriptOf(languages.target);
  if (!targetScript) return false;
  const before = scriptShare(transcript, targetScript);
  const after = scriptShare(output, targetScript);
  if (before !== null && after !== null && before < 0.5) {
    if (after >= 0.5) return false;
    if (after - before < 0.25) return true;
    return keptWords(transcript, output);
  }

  const source = languages.source;
  if (!source || primarySubtag(source) === "und" || primarySubtag(source) === primarySubtag(languages.target)) {
    return false;
  }
  if (scriptOf(source) !== targetScript) return false;
  return keptWords(transcript, output);
}

/** The output keeps the transcript's words: at least four of every five of its own words. */
function keptWords(transcript: string, output: string): boolean {
  const overlap = wordOverlap(transcript, output);
  return overlap !== null && overlap >= 0.8;
}

export function primarySubtag(tag: string): string {
  return tag.split("-")[0].toLowerCase();
}

/**
 * The ISO 15924 script a language is normally written in: "ru-RU" → "Cyrl", "ja" → "Jpan",
 * "sr-Latn" → "Latn". Note that "und" maximizes to "Latn": callers rule out auto-detection first.
 */
export function scriptOf(tag: string): string | null {
  try {
    return new Intl.Locale(tag).maximize().script ?? null;
  } catch {
    return null;
  }
}

/** ISO 15924 codes that stand for more than one Unicode script. */
const COMPOSITE_SCRIPTS: Record<string, string[]> = {
  Hans: ["Han"],
  Hant: ["Han"],
  Jpan: ["Han", "Hiragana", "Katakana"],
  Kore: ["Hangul", "Han"],
};

/** Matches one character of an ISO 15924 script, or null for a code JavaScript doesn't know. */
function scriptCharacter(script: string): RegExp | null {
  if (!/^[A-Z][a-z]{3}$/.test(script)) return null;
  const parts = Object.hasOwn(COMPOSITE_SCRIPTS, script) ? COMPOSITE_SCRIPTS[script] : [script];
  try {
    // Script_Extensions, so marks shared by several scripts (Japanese «ー») count for each.
    return new RegExp(`[${parts.map((part) => `\\p{scx=${part}}`).join("")}]`, "u");
  } catch {
    return null;
  }
}

/** Share of `text`'s letters written in `script` (ISO 15924), or null under `minLetters` letters. */
export function scriptShare(text: string, script: string, minLetters = 12): number | null {
  const character = scriptCharacter(script);
  const letters = text.replace(PLACEHOLDER, " ").match(/\p{L}/gu) ?? [];
  if (!character || letters.length < minLetters) return null;
  return letters.filter((letter) => character.test(letter)).length / letters.length;
}

/** Share of the output's words that the transcript contains too, or null under four words. */
export function wordOverlap(transcript: string, output: string): number | null {
  const spoken = new Set(letterWords(transcript));
  const written = letterWords(output);
  if (written.length < 4) return null;
  return written.filter((word) => spoken.has(word)).length / written.length;
}

/** Lowercased words that contain a letter: numbers and snippet placeholders are left out. */
function letterWords(text: string): string[] {
  const words: string[] = [];
  const segmenter = new Intl.Segmenter("und", { granularity: "word" });
  for (const segment of segmenter.segment(text.replace(PLACEHOLDER, " "))) {
    if (segment.isWordLike && /\p{L}/u.test(segment.segment)) {
      words.push(segment.segment.normalize("NFC").toLowerCase());
    }
  }
  return words;
}

/** Quote pairs the model may wrap its whole answer in: straight, curly, «ёлочки» and „лапки“. */
const QUOTE_PAIRS: ReadonlyArray<readonly [string, string]> = [
  ['"', '"'],
  ["“", "”"],
  ["«", "»"],
  ["„", "“"],
  ["„", "”"],
];

/** Strips wrapping quotes or code fences the model should not have added. */
export function tidyOutput(output: string): string {
  let text = output.trim();
  const fenced = text.match(/^```[a-z]*\n([\s\S]*?)\n```$/);
  if (fenced) text = fenced[1].trim();
  for (const [open, close] of QUOTE_PAIRS) {
    if (text.length < 2 || !text.startsWith(open) || !text.endsWith(close)) continue;
    const inner = text.slice(open.length, -close.length);
    // Only a pair that wraps the whole text is noise; quotes inside the text are the user's.
    if (!inner.includes(open) && !inner.includes(close)) {
      text = inner.trim();
      break;
    }
  }
  return text;
}
