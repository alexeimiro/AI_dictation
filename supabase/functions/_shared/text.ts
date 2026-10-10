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

export type GuardReason = "empty" | "too_long" | "assistant_reply" | "script_changed";
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
