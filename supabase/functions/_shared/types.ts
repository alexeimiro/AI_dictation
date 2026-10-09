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
  language?: string;
  style?: Style;
  dictionary?: DictionaryEntry[];
  snippets?: SnippetRef[];
}

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

const STYLES: Style[] = ["formal", "casual", "veryCasual", "excited"];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TOKEN_PATTERN = /^⟦s:[0-9a-f]{8}⟧$/;

export const LIMITS = {
  transcriptChars: 20_000,
  dictionaryEntries: 300,
  snippets: 200,
  termChars: 59,
  triggerChars: 59,
} as const;

export function parseCleanupRequest(body: unknown): Parsed<CleanupRequest> {
  if (typeof body !== "object" || body === null) return { ok: false, error: "body must be a JSON object" };
  const raw = body as Record<string, unknown>;

  if (typeof raw.dictationId !== "string" || !UUID_PATTERN.test(raw.dictationId)) {
    return { ok: false, error: "dictationId must be a UUID" };
  }
  if (typeof raw.transcript !== "string") return { ok: false, error: "transcript must be a string" };
  if (raw.transcript.length > LIMITS.transcriptChars) return { ok: false, error: "transcript too long" };
  if (raw.language !== undefined && (typeof raw.language !== "string" || raw.language.length > 35)) {
    return { ok: false, error: "language must be a BCP-47 tag" };
  }
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
      language: raw.language as string | undefined,
      style: raw.style as Style | undefined,
      dictionary,
      snippets,
    },
  };
}
