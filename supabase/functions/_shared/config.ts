// What the functions read from their environment (Supabase secrets), with the code defaults.
// Each reader takes the env, so the tests pass a fake one.
import { DEFAULT_EFFORT, DEFAULT_MODEL } from "./cleanup.ts";
import { DEFAULT_TRANSCRIBE_MODEL } from "./transcribe.ts";

/** The part of `Deno.env` the readers use. */
export type Env = Pick<Deno.Env, "get">;

/** A positive number from the env; unset, zero, negative or not a number gives `fallback`. */
export function envNumber(env: Env, name: string, fallback: number): number {
  const value = Number(env.get(name));
  return Number.isFinite(value) && value > 0 ? value : fallback;
}

/** The settings of one Responses API call (`runCleanup`). */
export interface ModelConfig {
  model: string;
  /** OpenAI reasoning effort (none, minimal, low, …; model-dependent). */
  effort: string;
  /** Hard bound on the whole call. */
  deadlineMs: number;
}

/**
 * Cleanups: CLEANUP_MODEL (default gpt-6-astra), CLEANUP_EFFORT (low) and CLEANUP_DEADLINE_MS
 * (9000, which must stay below the app's cleanup timeout of 11 s).
 */
export function cleanupConfig(env: Env = Deno.env): ModelConfig {
  return {
    model: env.get("CLEANUP_MODEL") ?? DEFAULT_MODEL,
    effort: env.get("CLEANUP_EFFORT") ?? DEFAULT_EFFORT,
    deadlineMs: envNumber(env, "CLEANUP_DEADLINE_MS", 9000),
  };
}

/**
 * Translations: TRANSLATE_MODEL and TRANSLATE_EFFORT, each falling back to its CLEANUP_* value and
 * then to the code default, with cleanup's deadline. With neither set a translation runs exactly as
 * before they existed; one secret then switches the model for `cleanup`'s translations (old builds)
 * and `dictate`'s alike.
 */
export function translationConfig(env: Env = Deno.env): ModelConfig {
  return {
    model: env.get("TRANSLATE_MODEL") ?? env.get("CLEANUP_MODEL") ?? DEFAULT_MODEL,
    effort: env.get("TRANSLATE_EFFORT") ?? env.get("CLEANUP_EFFORT") ?? DEFAULT_EFFORT,
    // CLEANUP_DEADLINE_MS, below the app's 11 s timeout for both.
    deadlineMs: cleanupConfig(env).deadlineMs,
  };
}

export interface TranscribeConfig {
  model: string;
  /** Hard bound on the OpenAI call. */
  deadlineMs: number;
}

/**
 * Transcription: TRANSCRIBE_MODEL (default gpt-transcribe) and TRANSCRIBE_DEADLINE_MS (20000,
 * below the app's 25 s `transcribe` timeout and, with the translation after it, its 30 s
 * `dictate` timeout).
 */
export function transcribeConfig(env: Env = Deno.env): TranscribeConfig {
  return {
    model: env.get("TRANSCRIBE_MODEL") ?? DEFAULT_TRANSCRIBE_MODEL,
    deadlineMs: envNumber(env, "TRANSCRIBE_DEADLINE_MS", 20000),
  };
}

export interface DictateConfig {
  /** The same secrets `transcribe` reads. */
  transcribe: TranscribeConfig;
  translation: ModelConfig;
  /**
   * Audio mode's bound, from the start of the request: the translation gets what is left of it
   * (at most its own deadline) and is skipped when under a second remains. Below the app's 30 s.
   */
  deadlineMs: number;
  /** Kill switch: answers 404 dictate_disabled, so the app goes back to transcribe + cleanup. */
  disabled: boolean;
  /** Dictations a minute; only a dictation's first call counts (`dictation_preflight`). */
  perMinute: number;
  /** Anonymous (trial) callers get the tighter limit `transcribe` and `cleanup` give them. */
  anonymousPerMinute: number;
}

/** `dictate`: the transcribe and translation secrets, DICTATE_DEADLINE_MS (26000) and DICTATE_DISABLED=1. */
export function dictateConfig(env: Env = Deno.env): DictateConfig {
  return {
    transcribe: transcribeConfig(env),
    translation: translationConfig(env),
    deadlineMs: envNumber(env, "DICTATE_DEADLINE_MS", 26000),
    disabled: env.get("DICTATE_DISABLED") === "1",
    perMinute: 40,
    anonymousPerMinute: 10,
  };
}
