// The text benchmark's cases: what each mode must do, in several languages, checked without a
// model. The judges grade the rest (grammar and faithfulness, 1–5).
import type { Style } from "../../supabase/functions/_shared/types.ts";

export interface BenchCase {
  id: string;
  style: Style;
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
  /** The output has at most this share of the transcript's words (Concise). */
  maxWordRatio?: number;
}

/** The sentence the app's Style screen shows in every style (`StyleView.spoken`). */
const SCREEN = "um so me and him was thinking maybe we could like meet on friday at 4 if that works for you guys";

export const CASES: BenchCase[] = [
  // The Style screen's own sentence: each card's promise.
  {
    id: "screen.verbatim",
    style: "verbatim",
    language: "en-US",
    transcript: SCREEN,
    must: [/^So,? me and him was thinking maybe we could,? like,? meet on Friday at 4/, /\byou guys\.$/],
    mustNot: [/\bum\b/i],
  },
  {
    id: "screen.grammar",
    style: "grammar",
    language: "en-US",
    transcript: SCREEN,
    must: [/\bhe and I were thinking\b/i, /\bFriday at 4\b/, /\byou guys\b/],
    mustNot: [/\bum\b/i, /\bme and him\b/i, /\b[ap]\.?m\b/i],
  },
  {
    id: "screen.professional",
    style: "professional",
    language: "en-US",
    transcript: SCREEN,
    must: [/^He and I\b/, /\bFriday at 4\b/, /[.?]$/],
    mustNot: [/\bguys\b/i, /\bum\b/i, /\blike meet\b/i, /\bdear\b/i, /\bregards\b/i, /\b[ap]\.?m\b/i],
  },
  {
    id: "screen.casual",
    style: "chat",
    language: "en-US",
    transcript: SCREEN,
    must: [/^[a-z]/, /\bme and him\b/, /\bfriday at 4\b/, /\byou guys$/],
    mustNot: [/\bum\b/i, /\p{Extended_Pictographic}/u],
  },
  {
    id: "screen.concise",
    style: "concise",
    language: "en-US",
    transcript: SCREEN,
    must: [/\bHe and I\b/, /\bFriday at 4\b/],
    mustNot: [/\bum\b/i, /\bhim and I\b/i, /\b[ap]\.?m\b/i],
    maxWordRatio: 0.75,
  },
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
  // Nothing is added: a bare hour gets no "PM" and no 24-hour guess.
  {
    id: "grammar.en.bare-hour",
    style: "grammar",
    language: "en-US",
    transcript: "lets meet on friday at 4 at the office",
    must: [/\bat 4\b/i, /\bFriday\b/],
    mustNot: [/\b[ap]\.?m\b/i, /16:00/],
  },
  {
    id: "grammar.ru.bare-hour",
    style: "grammar",
    language: "ru-RU",
    transcript: "давай встретимся в пятницу в четыре в офисе",
    must: [/в (четыре|4)(?![\d:])/i, /пятницу/i],
    mustNot: [/16:00/, /4:00/],
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
  {
    id: "verbatim.en.hedges",
    style: "verbatim",
    language: "en-US",
    transcript: "so like I think we should actually ship it on monday no wait tuesday you know",
    must: [/\blike\b/i, /\bactually\b/i, /\bmonday\b/i, /\bno,? wait\b/i, /\btuesday\b/i, /\byou know\b/i],
  },
  {
    id: "verbatim.en.grammar-stays",
    style: "verbatim",
    language: "en-US",
    transcript: "um me and him was thinking we could meet friday at 4",
    must: [/^Me and him was thinking we could meet Friday at (4|four)\.$/],
  },
  // Words that are also spoken commands stay words inside a sentence.
  {
    id: "verbatim.en.command-words",
    style: "verbatim",
    language: "en-US",
    transcript: "It was a difficult period for the company, so I had to dash to the airport.",
    unchanged: true,
  },
  {
    id: "verbatim.ru.command-words",
    style: "verbatim",
    language: "ru-RU",
    transcript: "У меня есть собака, и я поставил точку в этом вопросе.",
    unchanged: true,
  },
  {
    id: "verbatim.ru.self-correction",
    style: "verbatim",
    language: "ru-RU",
    transcript: "давай встретимся в три нет подожди в четыре",
    must: [/в три/i, /подожди/i, /в четыре/i],
  },
  {
    id: "verbatim.de.um",
    style: "verbatim",
    language: "de-DE",
    transcript: "wir treffen uns um acht uhr am bahnhof",
    must: [/\bum\b/i, /\bBahnhof\b/],
  },
  // Professional: slang, fillers and chatty openers go; every fact stays; nothing is added.
  {
    id: "professional.en.slang",
    style: "professional",
    language: "en-US",
    transcript: "hey guys so i'm gonna need the q3 report by friday ok thanks",
    must: [/\breport\b/i, /\bFriday\b/, /\bQ3\b/, /^[A-Z]/, /[.?!]$/],
    mustNot: [/\bgonna\b/i, /\bguys\b/i, /^hey\b/i, /\bdear\b/i, /\bregards\b/i],
  },
  {
    id: "professional.en.request",
    style: "professional",
    language: "en-US",
    transcript: "yeah so can you like send me the numbers for last month i kinda need them asap",
    must: [/\bnumbers\b/i, /\blast month\b/i, /^[A-Z]/],
    mustNot: [/\byeah\b/i, /\bkinda\b/i, /\blike send\b/i, /\bdear\b/i],
  },
  {
    id: "professional.en.already-professional",
    style: "professional",
    language: "en-US",
    transcript: "Could you please send me the report by Friday? Thank you.",
    unchanged: true,
  },
  {
    id: "professional.en.question-not-answered",
    style: "professional",
    language: "en-US",
    transcript: "hey so what's the capital of france",
    must: [/capital of France\?/],
    mustNot: [/Paris/i, /^hey\b/i],
  },
  {
    id: "professional.ru.slang",
    style: "professional",
    language: "ru-RU",
    transcript: "слушай короче мне нужен отчёт за третий квартал до пятницы ок",
    must: [/отчёт/i, /пятниц/i, /квартал/i, /^\p{Lu}/u, /[.?!]$/],
    mustNot: [/короче/i, /слушай/i, /(?<!\p{L})ок(?!\p{L})/iu],
  },
  {
    id: "professional.ru.address-stays",
    style: "professional",
    language: "ru-RU",
    transcript: "ну ты это скинь мне пожалуйста презентацию до вечера",
    must: [/презентаци/i, /до вечера/i, /пожалуйста/i],
    // «ты» is not turned into «вы».
    mustNot: [/(?<!\p{L})(вы|вас|вам|скиньте|пришлите|отправьте)(?!\p{L})/iu, /(?<!\p{L})ну(?!\p{L})/iu],
  },
  // Casual: lowercase, light punctuation, no full stop at the end, the speaker's words, no emoji.
  {
    id: "casual.en.lowercase",
    style: "chat",
    language: "en-US",
    transcript: "Hello, could you send me the report by Friday? Thank you so much.",
    must: [/^[a-z]/, /\breport\b/, /\?/, /\bfriday\b/],
    mustNot: [/\.$/, /\p{Extended_Pictographic}/u, /\bHello\b/, /\bThank\b/],
  },
  {
    id: "casual.en.names-stay",
    style: "chat",
    language: "en-US",
    transcript: "um I think Anna and I are gonna fly to Berlin on monday",
    must: [/\bAnna\b/, /\bBerlin\b/, /\bI\b/, /\bgonna\b/, /\bmonday\b/],
    mustNot: [/\.$/, /\bum\b/i, /\p{Extended_Pictographic}/u],
  },
  {
    id: "casual.ru.lowercase",
    style: "chat",
    language: "ru-RU",
    transcript: "Привет, можешь скинуть отчёт до пятницы? Спасибо большое.",
    must: [/^[а-яё]/, /отчёт/, /\?/, /спасибо большое/],
    mustNot: [/\.$/, /\p{Extended_Pictographic}/u],
  },
  // Concise: fewer words, every fact kept; a short message stays as it is.
  {
    id: "concise.en.rambling",
    style: "concise",
    language: "en-US",
    transcript:
      "so basically what I wanted to say is that I think that maybe we should probably move the meeting from wednesday to thursday at 3 pm because you know a lot of people are going to be out on wednesday if that makes sense",
    must: [/\bThursday\b/, /\b3\b/, /\bWednesday\b/, /\bmeeting\b/i],
    mustNot: [/\bbasically\b/i, /what I wanted to say/i, /if that makes sense/i],
    maxWordRatio: 0.7,
  },
  {
    id: "concise.ru.rambling",
    style: "concise",
    language: "ru-RU",
    transcript:
      "ну в общем я что хотел сказать мне кажется что нам наверное стоит перенести встречу со среды на четверг на три часа дня потому что ну в среду многих не будет если что",
    must: [/четверг/i, /сред/i, /встреч/i, /(15:00|три|3)/i],
    mustNot: [/в общем/i, /что хотел сказать/i],
    maxWordRatio: 0.7,
  },
  {
    id: "concise.en.short-stays",
    style: "concise",
    language: "en-US",
    transcript: "Can you send me the report by Friday?",
    unchanged: true,
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
  {
    id: "translate.en-ru.verbatim-self-correction",
    style: "verbatim",
    language: "en-US",
    targetLanguage: "ru-RU",
    transcript: "let's meet on monday no wait on tuesday",
    must: [/понедельник/i, /вторник/i],
  },
  {
    id: "translate.ru-en.professional",
    style: "professional",
    language: "ru-RU",
    targetLanguage: "en-US",
    transcript: "слушай короче мне нужен отчёт до пятницы ок",
    must: [/\breport\b/i, /\bFriday\b/, /^[A-Z]/],
    mustNot: [/\blisten\b/i, /\bok(ay)?\b/i],
  },
  {
    id: "translate.ru-en.casual",
    style: "chat",
    language: "ru-RU",
    targetLanguage: "en-US",
    transcript: "привет можешь скинуть отчёт до пятницы спасибо большое",
    must: [/^[a-z]/, /\breport\b/i],
    mustNot: [/\.$/, /\p{Extended_Pictographic}/u],
  },
  {
    id: "translate.en-ru.concise",
    style: "concise",
    language: "en-US",
    targetLanguage: "ru-RU",
    transcript:
      "so basically what I wanted to say is that I think that maybe we should probably move the meeting to thursday if that's okay with everyone",
    must: [/четверг/i, /встреч/i],
    maxWordRatio: 0.8,
  },
];

/** Lowercased letters and digits, one space apart: what "the same words" compares. */
function words(text: string): string {
  return text.normalize("NFC").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function wordCount(text: string): number {
  return words(text).split(" ").filter(Boolean).length;
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
  if (benchCase.maxWordRatio !== undefined) {
    const [written, spoken] = [wordCount(outcome.text), wordCount(benchCase.transcript)];
    if (written > benchCase.maxWordRatio * spoken) problems.push(`not shorter (${written} of ${spoken} words)`);
  }
  return problems;
}
