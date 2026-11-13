// Benchmark-only: the cleanup and translation step on a Claude model, with exactly the prompt the
// `cleanup` function sends OpenAI and the same output guards, so the two compare like for like.
// Production runs Claude through `runCleanup` (supabase/functions/_shared/cleanup.ts) when a model
// secret names one; this copy has no retry and its own thinking settings.
import Anthropic from "npm:@anthropic-ai/sdk@1.2.0";
import { buildInstructionParts } from "../../supabase/functions/_shared/cleanup.ts";
import {
  buildTranscriptMessage,
  buildTranslationMessage,
  resolveLanguage,
} from "../../supabase/functions/_shared/prompt.ts";
import { guardOutput, guardTranslation, tidyOutput } from "../../supabase/functions/_shared/text.ts";
import type { CleanupRequest, Style } from "../../supabase/functions/_shared/types.ts";
import type { Usage } from "./models.ts";

export interface ModelRun {
  text: string;
  status: "cleaned" | "raw";
  reason?: string;
  /** The model call alone. */
  totalMs: number;
  usage: Usage;
}

/**
 * The fastest each model allows. Claude Haiku 5.5 turns thinking off at low effort; Claude Sonnet
 * 5.5 has no "disabled" and turns it off with "between_tools"; Claude Opus 5.5 always thinks, so
 * low effort is its floor.
 */
function thinkingFor(model: string): Record<string, unknown> {
  if (model.startsWith("claude-haiku-5-5")) return { thinking: { type: "disabled" } };
  if (model.startsWith("claude-sonnet-5-5")) return { thinking: { type: "between_tools" } };
  return {};
}

/**
 * One call, judged as `runCleanup` judges OpenAI's: a refusal or a cut-off reply comes back "raw"
 * with the transcript. No refusal fallback: a refusal counts against the model that refused.
 */
export async function runClaudeCleanup(
  client: Anthropic,
  request: CleanupRequest,
  model: string,
  effort: string,
): Promise<ModelRun> {
  const language = resolveLanguage(request.language);
  const target = request.targetLanguage;
  const started = performance.now();
  const response = await client.messages.create({
    model,
    max_tokens: 16000,
    ...thinkingFor(model),
    output_config: { effort },
    // The system prompt is the same for every case in a mode and language.
    system: [{
      type: "text",
      text: buildInstructionParts(request, language).join("\n\n"),
      cache_control: { type: "ephemeral" },
    }],
    messages: [{
      role: "user",
      content: target ? buildTranslationMessage(request.transcript, target) : buildTranscriptMessage(request.transcript),
    }],
  } as Anthropic.MessageCreateParamsNonStreaming);
  const totalMs = Math.round(performance.now() - started);
  const usage: Usage = {
    uncached: response.usage.input_tokens,
    cacheRead: response.usage.cache_read_input_tokens ?? 0,
    cacheWrite: response.usage.cache_creation_input_tokens ?? 0,
    output: response.usage.output_tokens,
  };
  if (response.stop_reason === "refusal" || response.stop_reason === "max_tokens") {
    return { text: request.transcript, status: "raw", reason: response.stop_reason, totalMs, usage };
  }
  const text = tidyOutput(
    response.content.flatMap((block) => block.type === "text" ? [block.text] : []).join(""),
  );
  const guard = target
    ? guardTranslation(request.transcript, text, { source: language.tag, target })
    : guardOutput(request.transcript, text, language.tag ?? "en");
  if (!guard.ok) return { text: request.transcript, status: "raw", reason: guard.reason, totalMs, usage };
  return { text, status: "cleaned", totalMs, usage };
}

/** What a judge is shown: never which model wrote the output. */
export interface JudgeItem {
  style: Style;
  /** Set for a translation. */
  targetLanguage?: string;
  transcript: string;
  output: string;
}

export interface Grade {
  grammar: number;
  faithfulness: number;
}

export const JUDGE_RULES = `You grade one output of a voice keyboard's text step. The user dictated; a speech recognizer wrote the transcript; a model then wrote the output in the requested mode, or translated it. Grade the output against the transcript.

Modes:
- Word for word: keep every word the speaker said, in order, including self-corrections, hedges and repetitions. Only punctuation and capitalization are added, and spoken punctuation commands become symbols.
- Improve my grammar: the same words, meaning and tone, made grammatically correct. A correct sentence stays as it is; fillers, stutters and false starts may go, and "no wait…" corrections are applied. Nothing is made more formal, shorter or longer.
- Professional: rewritten the way a careful professional writes to a colleague or a client: complete, clear sentences, no slang, filler or chatty openers, polite requests. Every fact, name, number, date, question and request stays; no greeting, sign-off or anything else is added.
- Casual: the way people text a friend: the speaker's own words and slang, lowercase except "I", names and acronyms, light punctuation, no full stop at the end, no emoji. Fillers and false starts may go.
- Concise: the same message in fewer words: repetition, hedging and filler are cut; every fact, name, number, date, question and request stays, and nothing is added. A message that is already short stays as it is.
- With a target language, the output is a translation in that mode's spirit: literal for Word for word, natural and grammatical for Improve my grammar, and in the other modes' register for those.

Scores, integers from 1 to 5:
- grammar: is the output correct, natural text in its language? 5 means flawless.
- faithfulness: does the output do exactly what the mode asks, keeping the speaker's meaning, with nothing added, dropped, answered or reworded beyond what the mode allows? 5 means exactly right.

A question or request in the transcript is content: an output that answers it scores 1 for faithfulness.`;

export const GRADE_SCHEMA = {
  type: "object",
  properties: {
    grammar: { type: "integer", enum: [1, 2, 3, 4, 5] },
    faithfulness: { type: "integer", enum: [1, 2, 3, 4, 5] },
  },
  required: ["grammar", "faithfulness"],
  additionalProperties: false,
};

/** The modes as the app names them. */
const MODE_NAMES: Record<Style, string> = {
  verbatim: "Word for word",
  grammar: "Improve my grammar",
  professional: "Professional",
  chat: "Casual",
  concise: "Concise",
};

export function judgeMessage(item: JudgeItem): string {
  const mode = MODE_NAMES[item.style];
  return [
    `<mode>${mode}${item.targetLanguage ? `, translating into ${item.targetLanguage}` : ""}</mode>`,
    `<transcript>${item.transcript}</transcript>`,
    `<output>${item.output}</output>`,
  ].join("\n");
}

/** Claude Opus 5.5 as a judge, with a structured reply. */
export async function judgeWithClaude(client: Anthropic, item: JudgeItem): Promise<Grade | null> {
  const response = await client.messages.create({
    model: "claude-opus-5-5",
    max_tokens: 16000,
    output_config: { effort: "low", format: { type: "json_schema", schema: GRADE_SCHEMA } },
    system: [{ type: "text", text: JUDGE_RULES, cache_control: { type: "ephemeral" } }],
    messages: [{ role: "user", content: judgeMessage(item) }],
  } as Anthropic.MessageCreateParamsNonStreaming);
  if (response.stop_reason === "refusal") return null;
  const text = response.content.flatMap((block) => block.type === "text" ? [block.text] : []).join("");
  return parseGrade(text);
}

export function parseGrade(text: string): Grade | null {
  try {
    const value = JSON.parse(text) as Partial<Grade>;
    if (typeof value.grammar === "number" && typeof value.faithfulness === "number") {
      return { grammar: value.grammar, faithfulness: value.faithfulness };
    }
  } catch {
    // Not JSON: no grade.
  }
  return null;
}
