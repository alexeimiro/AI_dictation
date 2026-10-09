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

const ASSISTANT_OPENERS = [
  /^(sure|certainly|of course|absolutely)[,!. ]/i,
  /^here(?:'|’)s\b/i,
  /^i(?:'|’)m sorry\b/i,
  /^i can(?:'|’)?t\b/i,
  /^as an ai\b/i,
  /^great question\b/i,
];

export type GuardResult = { ok: true } | { ok: false; reason: "empty" | "too_long" | "assistant_reply" };

/**
 * Catches outputs that aren't a cleanup of the transcript: the model answered a dictated
 * question, refused, or produced something much longer than what was said.
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
  return { ok: true };
}

/** Strips wrapping quotes or code fences the model should not have added. */
export function tidyOutput(output: string): string {
  let text = output.trim();
  const fenced = text.match(/^```[a-z]*\n([\s\S]*?)\n```$/);
  if (fenced) text = fenced[1].trim();
  if (text.length >= 2 && /^["“]/.test(text) && /["”]$/.test(text) && !text.slice(1, -1).match(/["“”]/)) {
    text = text.slice(1, -1).trim();
  }
  return text;
}
