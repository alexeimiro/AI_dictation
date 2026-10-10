export type Style = "formal" | "casual" | "veryCasual" | "excited";

export interface DictionaryEntry {
  term: string;
  misspelling?: string | null;
}

export interface SnippetRef {
  /** Placeholder the model emits, e.g. ⟦s:1a2b3c4d⟧. The expansion never leaves the device. */
  token: string;
  trigger: string;
}

export interface CleanupRequest {
  dictationId: string;
  transcript: string;
  /**
   * Normalized BCP-47 tag such as "ru-RU" (see `normalizeLanguageTag`), or undefined when the
   * client did not say ("auto"). Only this sanitized value ever reaches the prompt.
   */
  language?: string;
  style?: Style;
  dictionary?: DictionaryEntry[];
  snippets?: SnippetRef[];
}

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

const STYLES: Style[] = ["formal", "casual", "veryCasual", "excited"];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_PATTERN = /^⟦s:[0-9a-f]{8}⟧$/;
/** Characters a client may send as a language tag. Anything else is a 400, never prompt text. */
const LANGUAGE_TAG_CHARS = /^[A-Za-z0-9-]*$/;
/** language[-Script][-REGION], as `Intl.Locale(...).baseName` spells it. */
const NORMALIZED_TAG = /^[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|\d{3}))?$/;

export const LIMITS = {
  transcriptChars: 20_000,
  /** Anonymous (trial) callers: shorter dictations, so an abused trial account costs little. */
  anonymousTranscriptChars: 6000,
  dictionaryEntries: 300,
  snippets: 200,
  termChars: 59,
  triggerChars: 59,
  languageTagChars: 35,
} as const;

export type NormalizedLanguage = { ok: true; tag: string | undefined } | { ok: false; error: string };

/**
 * Sanitizes the client's language tag before it can reach the prompt. Rejected (400) are only
 * non-strings, values over 35 characters and characters outside [A-Za-z0-9-]. Everything else is
 * canonicalized with `Intl.Locale` ("ru_RU" → "ru-RU", "ru-RU-u-ca-gregory" → "ru-RU"); a tag that
 * is well formed but does not reduce to language[-Script][-REGION] becomes undefined ("auto")
 * rather than an error, because a 400 silently degrades every dictation to the local formatter
 * on the device.
 */
export function normalizeLanguageTag(raw: unknown): NormalizedLanguage {
  if (raw === undefined || raw === null) return { ok: true, tag: undefined };
  if (typeof raw !== "string" || raw.length > LIMITS.languageTagChars) {
    return { ok: false, error: "language must be a BCP-47 tag" };
  }
  const candidate = raw.trim().replaceAll("_", "-");
  if (!LANGUAGE_TAG_CHARS.test(candidate)) return { ok: false, error: "language must be a BCP-47 tag" };
  let baseName: string;
  try {
    baseName = new Intl.Locale(candidate).baseName;
  } catch {
    return { ok: true, tag: undefined };
  }
  return { ok: true, tag: NORMALIZED_TAG.test(baseName) ? baseName : undefined };
}

export function parseCleanupRequest(body: unknown): Parsed<CleanupRequest> {
  if (typeof body !== "object" || body === null) return { ok: false, error: "body must be a JSON object" };
  const raw = body as Record<string, unknown>;

  if (typeof raw.dictationId !== "string" || !UUID_PATTERN.test(raw.dictationId)) {
    return { ok: false, error: "dictationId must be a UUID" };
  }
  if (typeof raw.transcript !== "string") return { ok: false, error: "transcript must be a string" };
  if (raw.transcript.length > LIMITS.transcriptChars) return { ok: false, error: "transcript too long" };
  const language = normalizeLanguageTag(raw.language);
  if (!language.ok) return { ok: false, error: language.error };
  if (raw.style !== undefined && !STYLES.includes(raw.style as Style)) {
    return { ok: false, error: "unknown style" };
  }

  const dictionary: DictionaryEntry[] = [];
  if (raw.dictionary !== undefined) {
    if (!Array.isArray(raw.dictionary) || raw.dictionary.length > LIMITS.dictionaryEntries) {
      return { ok: false, error: "dictionary must be an array of at most 300 entries" };
    }
    for (const item of raw.dictionary) {
      const entry = item as Record<string, unknown>;
      if (typeof entry?.term !== "string" || entry.term.length === 0 || entry.term.length > LIMITS.termChars) {
        return { ok: false, error: "invalid dictionary term" };
      }
      const misspelling = entry.misspelling;
      if (misspelling != null && (typeof misspelling !== "string" || misspelling.length > LIMITS.termChars)) {
        return { ok: false, error: "invalid dictionary misspelling" };
      }
      dictionary.push({ term: entry.term, misspelling: (misspelling as string | null | undefined) ?? null });
    }
  }

  const snippets: SnippetRef[] = [];
  if (raw.snippets !== undefined) {
    if (!Array.isArray(raw.snippets) || raw.snippets.length > LIMITS.snippets) {
      return { ok: false, error: "snippets must be an array of at most 200 entries" };
    }
    for (const item of raw.snippets) {
      const snippet = item as Record<string, unknown>;
      if (typeof snippet?.token !== "string" || !TOKEN_PATTERN.test(snippet.token)) {
        return { ok: false, error: "invalid snippet token" };
      }
      if (typeof snippet.trigger !== "string" || snippet.trigger.length === 0 ||
        snippet.trigger.length > LIMITS.triggerChars) {
        return { ok: false, error: "invalid snippet trigger" };
      }
      snippets.push({ token: snippet.token, trigger: snippet.trigger });
    }
  }

  return {
    ok: true,
    value: {
      dictationId: raw.dictationId,
      transcript: raw.transcript,
      language: language.tag,
      style: raw.style as Style | undefined,
      dictionary,
      snippets,
    },
  };
}
