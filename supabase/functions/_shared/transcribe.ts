// Request parsing and the OpenAI call for the `transcribe` function. Pure helpers, tested offline.
import { countWords } from "./text.ts";
import { normalizeLanguageTag, type Parsed } from "./types.ts";

/** OpenAI's file-transcription model (gpt-4o-transcribe and whisper-1 shut down 2027-02-26). */
export const DEFAULT_TRANSCRIBE_MODEL = "gpt-transcribe";

export const TRANSCRIBE_LIMITS = {
  /** Five minutes of 16 kHz mono WAV is ~9.6 MB; AAC is ~1.2 MB. OpenAI accepts up to 25 MB. */
  maxAudioBytes: 16 * 1024 * 1024,
  maxKeywords: 100,
  maxKeywordChars: 59,
  /** The languages a user picks in Settings, sent as hints while the language is detected. */
  maxLanguageHints: 10,
};

export type AudioFormat = "m4a" | "wav";

export interface TranscribeRequest {
  dictationId: string | null;
  audio: Uint8Array<ArrayBuffer>;
  format: AudioFormat;
  /** ISO-639-1 code ("ru"), or null to let the model detect the language. */
  language: string | null;
  /** Without a `language`: the ISO-639-1 codes the speech is one of (the user's languages); empty for any. */
  languageHints: string[];
  /** Personal dictionary terms, sent as keyword hints. */
  keywords: string[];
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE64_PATTERN = /^[A-Za-z0-9+/]*={0,2}$/;

/**
 * Body: { dictationId?: uuid, audio: base64, format: "m4a" | "wav", language?: BCP-47, languages?: BCP-47[],
 * keywords?: string[] }. `languages`: the user's languages, which the speech is detected among.
 */
export function parseTranscribeRequest(body: unknown): Parsed<TranscribeRequest> {
  if (typeof body !== "object" || body === null) return { ok: false, error: "body must be a JSON object" };
  const raw = body as Record<string, unknown>;

  const dictationId = raw.dictationId ?? null;
  if (dictationId !== null && (typeof dictationId !== "string" || !UUID_PATTERN.test(dictationId))) {
    return { ok: false, error: "dictationId must be a UUID" };
  }
  if (raw.format !== "m4a" && raw.format !== "wav") return { ok: false, error: "format must be m4a or wav" };
  if (typeof raw.audio !== "string" || raw.audio.length === 0) return { ok: false, error: "audio must be base64" };
  // Base64 is 4 characters per 3 bytes: reject oversized bodies before decoding them.
  if (raw.audio.length > Math.ceil(TRANSCRIBE_LIMITS.maxAudioBytes / 3) * 4) {
    return { ok: false, error: "audio too large" };
  }
  if (!BASE64_PATTERN.test(raw.audio)) return { ok: false, error: "audio must be base64" };
  const audio = decodeBase64(raw.audio);
  if (!audio) return { ok: false, error: "audio must be base64" };

  const language = normalizeLanguageTag(raw.language);
  if (!language.ok) return { ok: false, error: language.error };

  return {
    ok: true,
    value: {
      dictationId,
      audio,
      format: raw.format,
      language: isoLanguage(language.tag),
      languageHints: cleanLanguageHints(raw.languages),
      keywords: cleanKeywords(raw.keywords),
    },
  };
}

/** Apple tags whose language OpenAI knows under another ISO-639-1 code. */
const ISO_ALIASES: Record<string, string> = { nb: "no", nn: "no", fil: "tl", iw: "he", in: "id", cmn: "zh" };

/**
 * The ISO-639-3 codes gpt-transcribe's guide names beside the ISO-639-1 ones, for a language
 * that has no two-letter code: Cantonese. Soniox (the live words) doesn't take it, so a Cantonese
 * dictation is uploaded.
 */
const ISO_639_3 = new Set(["yue"]);

/** "ru-RU" → "ru"; OpenAI takes ISO-639-1 language codes ("nb-NO" → "no", "fil-PH" → "tl"), and "yue". */
export function isoLanguage(tag: string | undefined | null): string | null {
  if (!tag) return null;
  const primary = tag.split("-")[0].toLowerCase();
  const code = ISO_ALIASES[primary] ?? primary;
  return /^[a-z]{2}$/.test(code) || ISO_639_3.has(code) ? code : null;
}

/**
 * The user's languages as ISO-639-1 codes, deduplicated in order, at most 10. Anything that isn't a
 * language tag is skipped rather than refused: the hints only narrow the detection.
 */
export function cleanLanguageHints(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const codes: string[] = [];
  for (const item of raw) {
    const tag = normalizeLanguageTag(item);
    const code = tag.ok ? isoLanguage(tag.tag) : null;
    if (!code || codes.includes(code)) continue;
    codes.push(code);
    if (codes.length === TRANSCRIBE_LIMITS.maxLanguageHints) break;
  }
  return codes;
}

/**
 * Keyword hints: single-line terms without angle brackets (OpenAI rejects those), trimmed,
 * deduplicated case-insensitively, at most 100.
 */
export function cleanKeywords(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const keywords: string[] = [];
  for (const item of raw) {
    if (typeof item !== "string") continue;
    const term = item.trim();
    if (!term || term.length > TRANSCRIBE_LIMITS.maxKeywordChars || /[<>\r\n]/.test(term)) continue;
    const key = term.toLocaleLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    keywords.push(term);
    if (keywords.length === TRANSCRIBE_LIMITS.maxKeywords) break;
  }
  return keywords;
}

/**
 * The multipart body for POST /v1/audio/transcriptions. gpt-transcribe takes `languages[]` (the
 * language, else the user's languages to detect it among) and `keywords[]`; older models take a
 * single `language` (a lone hint counts) and the terms as a `prompt`.
 */
export function openAIForm(request: TranscribeRequest, model: string): FormData {
  const form = new FormData();
  const type = request.format === "m4a" ? "audio/mp4" : "audio/wav";
  form.append("file", new Blob([request.audio], { type }), `dictation.${request.format}`);
  form.append("model", model);
  const languages = request.language ? [request.language] : request.languageHints;
  if (model.startsWith("gpt-transcribe")) {
    for (const language of languages) form.append("languages[]", language);
    for (const keyword of request.keywords) form.append("keywords[]", keyword);
  } else {
    if (languages.length === 1) form.append("language", languages[0]);
    if (request.keywords.length > 0) form.append("prompt", request.keywords.join(", "));
  }
  return form;
}

export interface TranscriptionResult {
  text: string;
  languages: string[];
}

/**
 * Calls OpenAI with an overall deadline. Throws on HTTP errors, timeouts and aborts. A `signal`
 * replaces the `AbortSignal.timeout(deadlineMs)` default, so it should carry a deadline of its own.
 *
 * OpenAI rejects a language code it doesn't support with a 400, which would fail the whole
 * dictation. A 400 to a request that named its language or the user's languages is therefore
 * tried once more without them, inside the same deadline: the model then detects the language
 * itself. A 400 with no languages named, or a second one, is thrown as before.
 */
export async function transcribeWithOpenAI(
  request: TranscribeRequest,
  options: { apiKey: string; model: string; deadlineMs: number; signal?: AbortSignal; fetcher?: typeof fetch },
): Promise<TranscriptionResult> {
  const fetcher = options.fetcher ?? fetch;
  const signal = options.signal ?? AbortSignal.timeout(options.deadlineMs);
  const post = (body: TranscribeRequest) =>
    fetcher("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { Authorization: `Bearer ${options.apiKey}` },
      body: openAIForm(body, options.model),
      signal,
    });
  let response = await post(request);
  if (response.status === 400 && namesLanguages(request)) {
    const detail = await response.json().catch(() => null) as { error?: { type?: string; code?: string } } | null;
    console.warn(
      `OpenAI refused a transcription that named its languages (${detail?.error?.code ?? detail?.error?.type ?? "400"}); retrying without them`,
    );
    response = await post({ ...request, language: null, languageHints: [] });
  }
  if (!response.ok) {
    // The body can echo request details; keep only the status and OpenAI's error type.
    const detail = await response.json().catch(() => null) as { error?: { type?: string; code?: string } } | null;
    throw new OpenAIError(response.status, detail?.error?.code ?? detail?.error?.type ?? null);
  }
  const payload = await response.json() as { text?: unknown; languages?: unknown };
  const text = typeof payload.text === "string" ? payload.text.trim() : "";
  const languages = Array.isArray(payload.languages)
    ? payload.languages.flatMap((item) => typeof item?.code === "string" ? [item.code] : [])
    : [];
  return { text, languages };
}

/** The request tells OpenAI which language the speech is in, or which ones it may be in. */
function namesLanguages(request: TranscribeRequest): boolean {
  return request.language !== null || request.languageHints.length > 0;
}

export class OpenAIError extends Error {
  constructor(readonly status: number, readonly code: string | null) {
    super(`OpenAI transcription failed with HTTP ${status}${code ? ` (${code})` : ""}`);
  }
}

/**
 * What a transcript adds to the free plan's weekly words: its word count, under the dictation's
 * own id. `cleanup` and `dictate` report the same dictation under that id, and `record_usage`
 * keeps the largest count, so a dictation is counted once whichever requests it takes.
 *
 * Every transcript with words is counted. Until 2026-11-17 one was counted only when the request
 * vouched for its id with `x-murmur-dictation: <dictationId>`, so leaving the header out was free
 * transcription for any client that isn't the app. The only builds that send none are TestFlight
 * builds from before 2026-11-13: their id here is a random one, so their dictation is counted again
 * when `cleanup` reports it. A request without an id is counted under one of its own.
 */
export function transcriptUsage(
  request: TranscribeRequest,
  result: TranscriptionResult,
): { dictationId: string; words: number } | null {
  // In the language it was spoken in: the one asked for, else the one heard first.
  const words = countWords(result.text, request.language ?? result.languages[0]);
  return words > 0 ? { dictationId: request.dictationId ?? crypto.randomUUID(), words } : null;
}

function decodeBase64(value: string): Uint8Array<ArrayBuffer> | null {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
    return bytes;
  } catch {
    return null;
  }
}
