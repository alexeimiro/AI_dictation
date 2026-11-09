// The text benchmark's cases: what each mode must do, in several languages, checked without a
// model. The judges grade the rest (grammar and faithfulness, 1–5).

export interface BenchCase {
  id: string;
  style: "verbatim" | "grammar";
  /** The spoken language as the app sends it. Omitted: Auto-detect from a build that sends none. */
  language?: string;
  targetLanguage?: string;
  transcript: string;
  /** Each must match the output. */
  must?: RegExp[];
  /** None may match the output. */
  mustNot?: RegExp[];
  /** A correct sentence: the output keeps exactly its words. */
  unchanged?: boolean;
}

export const CASES: BenchCase[] = [
  // Improve my grammar: real mistakes, which must be fixed.
  {
    id: "grammar.en.agreement",
    style: "grammar",
    language: "en-US",
    transcript: "me and him was going to the store yesterday and we buyed some apples",
    must: [/\bhe and I were\b/i, /\bbought\b/i, /\bapples\b/i],
    mustNot: [/\bbuyed\b/i],
  },
  {
    id: "grammar.en.tense",
    style: "grammar",
    language: "en-US",
    transcript: "if I would have known about it I would of came earlier",
    must: [/\bhad known\b/i, /\bwould have come\b/i],
    mustNot: [/\bof came\b/i],
  },
  {
    id: "grammar.en.question-order",
    style: "grammar",
    language: "en-US",
    transcript: "she don't know where is the meeting",
    must: [/\bdoesn['’]t know\b|\bdoes not know\b/i, /\bwhere the meeting is\b/i],
  },
  {
    id: "grammar.ru.cases",
    style: "grammar",
    language: "ru-RU",
    transcript: "я вчера купил две яблоки и один груша",
    must: [/два яблока/i, /одну грушу/i],
  },
  {
    id: "grammar.ru.agreement",
    style: "grammar",
    language: "ru-RU",
    transcript: "мы с ним ходили в магазин и он забыл свою кошелёк дома",
    must: [/сво[йи] кошел[её]к/i],
    mustNot: [/свою кошел/i],
  },
  {
    id: "grammar.tr.person",
    style: "grammar",
    language: "tr-TR",
    transcript: "ben dün markete gitti ve iki elma aldı",
    must: [/gittim/i, /aldım/i],
  },
  {
    id: "grammar.es.verb",
    style: "grammar",
    language: "es-ES",
    transcript: "ayer yo fue al mercado y compré dos manzana",
    must: [/\bfui\b/i, /dos manzanas/i],
  },
  {
    id: "grammar.de.word-order",
    style: "grammar",
    language: "de-DE",
    transcript: "gestern ich bin gegangen zum Supermarkt und habe Milch gekauft",
    must: [/gestern bin ich/i],
  },
  // Improve my grammar: correct or informal text, which must keep its words.
  {
    id: "grammar.en.correct",
    style: "grammar",
    language: "en-US",
    transcript: "Can you send me the report by Friday? Thanks.",
    unchanged: true,
  },
  {
    id: "grammar.ru.correct",
    style: "grammar",
    language: "ru-RU",
    transcript: "Можешь скинуть отчёт до пятницы? Спасибо.",
    unchanged: true,
  },
  {
    id: "grammar.en.slang-stays",
    style: "grammar",
    language: "en-US",
    transcript: "gonna grab coffee wanna come",
    must: [/\bgonna\b/i, /\bwanna\b/i],
  },
  {
    id: "grammar.en.question-not-answered",
    style: "grammar",
    language: "en-US",
    transcript: "what is the capital of france",
    must: [/capital of France\?/i],
    mustNot: [/Paris/i],
  },
  // Word for word: hedges, self-corrections and fillers stay; spoken commands become symbols.
  {
    id: "verbatim.en.self-correction",
    style: "verbatim",
    language: "en-US",
    transcript: "so I think we should actually ship it on monday no wait tuesday",
    must: [/\bactually\b/i, /\bmonday\b/i, /\bno,? wait\b/i, /\btuesday\b/i],
  },
  {
    id: "verbatim.ru.fillers-stay",
    style: "verbatim",
    language: "ru-RU",
    transcript: "ну короче я думаю что надо типа перенести встречу",
    // JavaScript's \b is ASCII-only: Cyrillic word ends are written out.
    must: [/(?<!\p{L})ну(?!\p{L})/iu, /короче/i, /типа/i],
  },
  {
    id: "verbatim.en.spoken-comma",
    style: "verbatim",
    language: "en-US",
    transcript: "send it today comma please",
    must: [/today, please/i],
    mustNot: [/\bcomma\b/i],
  },
  // Translations, from a chosen language and from Auto-detect.
  {
    id: "translate.ru-en.grammar",
    style: "grammar",
    language: "ru-RU",
    targetLanguage: "en-US",
    transcript: "можешь скинуть отчёт до пятницы спасибо большое",
    must: [/\breport\b/i, /\bFriday\b/i],
  },
  {
    id: "translate.tr-en.grammar",
    style: "grammar",
    language: "tr-TR",
    targetLanguage: "en-US",
    transcript: "yarın toplantıya gelemiyorum çünkü hastayım",
    must: [/\btomorrow\b/i, /\bmeeting\b/i, /\b(sick|ill|unwell)\b/i],
  },
  {
    id: "translate.auto-tr-en.grammar",
    style: "grammar",
    targetLanguage: "en-US",
    transcript: "yarın toplantıya gelemiyorum çünkü hastayım",
    must: [/\btomorrow\b/i, /\bmeeting\b/i],
  },
  {
    id: "translate.zh-en.grammar",
    style: "grammar",
    language: "zh-CN",
    targetLanguage: "en-US",
    transcript: "我明天不能来开会因为我生病了",
    must: [/\btomorrow\b/i, /\bmeeting\b/i],
  },
  {
    id: "translate.en-ru.verbatim",
    style: "verbatim",
    language: "en-US",
    targetLanguage: "ru-RU",
    transcript: "I think we should actually move the call to Thursday",
    must: [/четверг/i],
  },
  {
    id: "translate.en-tr.grammar",
    style: "grammar",
    language: "en-US",
    targetLanguage: "tr-TR",
    transcript: "can you send me the report by friday",
    must: [/rapor/i, /cuma/i],
  },
];

/** Lowercased letters and digits, one space apart: what "the same words" compares. */
function words(text: string): string {
  return text.normalize("NFC").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

/** What a run got wrong, as short labels; empty when it passed. */
export function check(benchCase: BenchCase, outcome: { status: string; reason?: string; text: string }): string[] {
  const problems: string[] = [];
  if (outcome.status !== "cleaned") problems.push(`${outcome.status}${outcome.reason ? `:${outcome.reason}` : ""}`);
  for (const pattern of benchCase.must ?? []) {
    if (!pattern.test(outcome.text)) problems.push(`missing ${pattern}`);
  }
  for (const pattern of benchCase.mustNot ?? []) {
    if (pattern.test(outcome.text)) problems.push(`has ${pattern}`);
  }
  if (benchCase.unchanged && words(outcome.text) !== words(benchCase.transcript)) problems.push("reworded");
  return problems;
}
