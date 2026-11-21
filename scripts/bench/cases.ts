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
  /** The output has at most this many emoji (0 for the modes that never add one, 2 for Funny). */
  maxEmoji?: number;
  /** The output has [fewest, most] paragraphs, the blocks between blank lines (Rewrite's layout). */
  paragraphs?: [number, number];
}

/** A greeting line, then a blank line: how an Email reply to someone opens. */
const GREETING = /^(?:Hi|Hello|Dear|Good (?:morning|afternoon))\b[^\n]*[,!]\n\n/;
/** A closing line after a blank line, and nothing after it: no sender's name. */
const CLOSING = /\n\n(?:Best regards|Kind regards|Regards|Best|Thanks|Thank you|Many thanks|Cheers)[,!.]?$/;
/** An email that signs a name under its closing. */
const SIGNED = /\n\n(?:Best regards|Kind regards|Regards|Best|Thanks|Thank you|Many thanks|Cheers)[,!.]?\n\S/;
/** A greeting by a name the speaker didn't say: "Hi all," and "Hi team," are fine. */
const NAMED_GREETING = /^(?:Hi|Hello|Dear) (?![Aa]ll\b|[Ee]veryone\b|[Tt]eam\b|[Gg]uys\b)\p{Lu}/u;
const LAUGHING = /[\u{1F602}\u{1F923}\u{1F606}\u{1F605}\u{1F61C}\u{1F92A}\u{1F639}\u{1F61D}]|\b(?:lol|lmao|haha)\b/iu;
/** A word of Latin letters, which a translation into Russian has none of here. */
const LATIN_WORD = /[A-Za-z]{3,}/;
const CYRILLIC = /\p{Script=Cyrillic}/u;
/** A whole Russian word, case-insensitive (`\b` is ASCII-only in JavaScript). */
const ru = (word: string) => new RegExp(`(?<![\\p{L}])${word}(?![\\p{L}])`, "iu");

/** The sentence the app's Style screen shows in every style (`StyleView.spoken`). */
const SCREEN = "um so me and him was thinking maybe we could like meet on friday at 4 if that works for you guys";

/** A voice note on three points (the launch, the website, the budget): Rewrite lays it out in paragraphs. */
const LONG_NOTE =
  "so um quick update on the launch the app is ready and the last build passed all the tests so we can submit it to the store on monday " +
  "and the other thing is the website we still need new screenshots for the home page and anna said she can do them by wednesday " +
  "oh and about the budget we spent more on ads than we planned so i think we should pause the facebook campaign for a week " +
  "and then look at the numbers again before we decide anything";
const LONG_NOTE_RU =
  "короче по запуску приложение готово последняя сборка прошла все тесты так что в понедельник отправляем его в стор " +
  "дальше по сайту нам всё ещё нужны новые скриншоты для главной страницы аня сказала что сделает их к среде " +
  "и ещё по бюджету мы потратили на рекламу больше чем планировали поэтому я думаю надо поставить рекламу в фейсбуке на паузу на неделю " +
  "а потом ещё раз посмотреть на цифры прежде чем что-то решать";

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
    id: "professional.en.bare-hour",
    style: "professional",
    language: "en-US",
    transcript: "so yeah me and the team was thinking we could do the review on tuesday at 3 if nobody minds",
    must: [/\bTuesday at 3\b/],
    mustNot: [/\b[ap]\.?m\b/i, /15:00/, /\byeah\b/i],
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
  // The four modes (November 21, 2026): the Style screen's sentence in each, then each mode's promises.
  {
    id: "screen.rewrite",
    style: "rewrite",
    language: "en-US",
    transcript: SCREEN,
    must: [/\bhe and I were\b/i, /\bFriday at 4\b/],
    mustNot: [/\bum\b/i, /\bme and him\b/i, /\b[ap]\.?m\b/i, /^(?:hi|hello|dear)\b/i, /\bregards\b/i],
    maxEmoji: 0,
    paragraphs: [1, 1],
  },
  {
    id: "screen.email",
    style: "email",
    language: "en-US",
    transcript: SCREEN,
    must: [GREETING, /\bFriday at 4\b/, CLOSING],
    mustNot: [/\bum\b/i, /\bme and him\b/i, /\b[ap]\.?m\b/i, /\bsubject\b/i, SIGNED, NAMED_GREETING],
    maxEmoji: 0,
  },
  {
    id: "screen.funny",
    style: "funny",
    language: "en-US",
    transcript: SCREEN,
    must: [/\bFriday\b/, /\b4\b/],
    mustNot: [/\bum\b/i, /\b[ap]\.?m\b/i, /#\w/],
    maxEmoji: 2,
  },
  // Rewrite: better sentences, nothing said twice, the speaker's register.
  {
    id: "rewrite.en.repetition",
    style: "rewrite",
    language: "en-US",
    transcript:
      "so the the plan is we we launch on monday and um yeah the plan is we launch on monday because the server is ready and the team is ready too",
    must: [/\bMonday\b/, /\bserver\b/i, /\bteam\b/i],
    mustNot: [/\bthe the\b/i, /\bwe we\b/i, /\bum\b/i, /Monday[\s\S]*Monday/],
    maxWordRatio: 0.8,
    maxEmoji: 0,
    paragraphs: [1, 1],
  },
  {
    id: "rewrite.en.casual-stays-casual",
    style: "rewrite",
    language: "en-US",
    transcript: "hey can you grab me a coffee on your way in i'm like dying here",
    must: [/\bcoffee\b/i, /\b(?:hey|grab)\b/i],
    mustNot: [/\b(?:could you please|would you kindly|dear|regards)\b/i],
    maxEmoji: 0,
    paragraphs: [1, 1],
  },
  {
    id: "rewrite.ru.structure",
    style: "rewrite",
    language: "ru-RU",
    transcript:
      "ну короче мы вчера с петей созвонились и петя сказал что релиз переносим на среду потому что тесты ну не прошли",
    must: [/Пет/, /сред/i, /тест/i, /релиз/i],
    mustNot: [ru("короче"), ru("ну")],
    maxEmoji: 0,
    paragraphs: [1, 1],
  },
  // Rewrite's layout (November 21, 2026): a long text in paragraphs by meaning, a short one in one.
  {
    id: "rewrite.en.long-paragraphs",
    style: "rewrite",
    language: "en-US",
    transcript: LONG_NOTE,
    must: [/\bMonday\b/, /\bAnna\b/, /\bWednesday\b/, /\bFacebook\b/, /\bweek\b/i],
    mustNot: [/\bum\b/i, /^(?:hi|hello|dear)\b/i, /\bregards\b/i],
    maxEmoji: 0,
    paragraphs: [2, 4],
  },
  {
    id: "rewrite.ru.long-paragraphs",
    style: "rewrite",
    language: "ru-RU",
    transcript: LONG_NOTE_RU,
    must: [/понедельник/i, /Ан[яиюе]/, /сред/i, /недел/i, /(?:Facebook|[Фф]ейсбук)/],
    mustNot: [ru("короче")],
    maxEmoji: 0,
    paragraphs: [2, 4],
  },
  {
    // Short, but the speaker asked for the break: it stays.
    id: "rewrite.en.spoken-paragraph",
    style: "rewrite",
    language: "en-US",
    transcript: "hi anna new paragraph the meeting moved to friday so see you then",
    must: [/\bAnna\b[^\n]*\n/, /\bFriday\b/],
    mustNot: [/\bnew paragraph\b/i],
    maxEmoji: 0,
  },
  // Email: a greeting and a closing for a message, a name only when the speaker gave it.
  {
    id: "email.en.named",
    style: "email",
    language: "en-US",
    transcript: "hey anna so can you send me the slides from yesterday's meeting before friday thanks",
    must: [/^(?:Hi|Hello|Dear) Anna,\n\n/, /\bslides\b/i, /\bFriday\b/, CLOSING],
    mustNot: [/\b[ap]\.?m\b/i, /\bsubject\b/i, SIGNED],
    maxEmoji: 0,
  },
  {
    id: "email.en.unnamed",
    style: "email",
    language: "en-US",
    transcript: "so the office is closed on monday and everyone should work from home that day",
    must: [GREETING, /\bMonday\b/, /\bhome\b/i, CLOSING],
    mustNot: [NAMED_GREETING, SIGNED],
    maxEmoji: 0,
  },
  {
    id: "email.en.no-invented-details",
    style: "email",
    language: "en-US",
    transcript: "hi can we move the call to next week something came up",
    must: [/\bnext week\b/i],
    mustNot: [/\b(?:Monday|Tuesday|Wednesday|Thursday|Friday)\b/, /\d/, /\b(?:apologi[sz]e|sorry)\b/i, SIGNED, NAMED_GREETING],
    maxEmoji: 0,
  },
  {
    id: "email.en.fragment",
    style: "email",
    language: "en-US",
    transcript: "remember to renew the domain and pay the hosting bill",
    must: [/\bdomain\b/i, /\bhosting\b/i],
    mustNot: [GREETING, /\b(?:regards|dear)\b/i, /\n\n(?:Thanks|Thank you)/],
    maxEmoji: 0,
  },
  {
    id: "email.ru.ty",
    style: "email",
    language: "ru-RU",
    transcript: "привет слушай можешь скинуть мне договор до пятницы",
    must: [/^Привет/, /договор/i, /пятниц/i, /(?:[Пп]рисл|[Сс]кин|[Оо]тправ)/],
    mustNot: [/(?:Пришлите|Отправьте|Скиньте|Можете)/, ru("короче"), ru("слушай")],
    maxEmoji: 0,
  },
  {
    id: "email.ru.vy",
    style: "email",
    language: "ru-RU",
    transcript: "здравствуйте можете прислать счёт до конца недели",
    must: [/^(?:Здравствуйте|Добрый день)/, /сч[её]т/i, /недел/i],
    mustNot: [/(?:Пришли,|Скинь|Отправь )/],
    maxEmoji: 0,
  },
  // Funny: light and kind, at most two emoji, warm for sad news.
  {
    id: "funny.en.light",
    style: "funny",
    language: "en-US",
    transcript: "i finished the quarterly report and sent it to the client this morning",
    must: [/\breport\b/i, /\bclient\b/i, /\bmorning\b/i],
    mustNot: [/#\w/],
    maxEmoji: 2,
  },
  {
    id: "funny.en.sad-news-stays-kind",
    style: "funny",
    language: "en-US",
    transcript: "my grandmother passed away last night so i won't be at work today",
    must: [/\bgrand(?:mother|ma)\b/i, /\btoday\b/i],
    mustNot: [LAUGHING, /#\w/],
    maxEmoji: 2,
  },
  {
    id: "funny.ru.light",
    style: "funny",
    language: "ru-RU",
    transcript: "я сегодня опоздаю минут на десять потому что проспал",
    must: [/(?:десят|10)/i, /просп/i],
    mustNot: [/#[\p{L}]/u],
    maxEmoji: 2,
  },
  // The modes in a translation.
  {
    id: "translate.rewrite.ru-en",
    style: "rewrite",
    language: "ru-RU",
    targetLanguage: "en-US",
    transcript: "ну короче мы вчера с петей созвонились и петя сказал что релиз переносим на среду",
    must: [/\bPet(?:y|i)?a\b/, /\bWednesday\b/, /\brelease\b/i],
    mustNot: [CYRILLIC],
    maxEmoji: 0,
    paragraphs: [1, 1],
  },
  {
    id: "translate.rewrite.ru-en.long",
    style: "rewrite",
    language: "ru-RU",
    targetLanguage: "en-US",
    transcript: LONG_NOTE_RU,
    must: [/\bMonday\b/, /\bWednesday\b/, /\bAn(?:y|n|j)a\b/, /\bFacebook\b/, /\bweek\b/i],
    mustNot: [CYRILLIC],
    maxEmoji: 0,
    paragraphs: [2, 4],
  },
  {
    id: "translate.email.ru-en",
    style: "email",
    language: "ru-RU",
    targetLanguage: "en-US",
    transcript: "привет аня можешь прислать отчёт до пятницы спасибо",
    must: [/^(?:Hi|Hello|Dear) An(?:n|y|j)a,\n\n/, /\breport\b/i, /\bFriday\b/, CLOSING],
    mustNot: [CYRILLIC, SIGNED],
    maxEmoji: 0,
  },
  {
    id: "translate.funny.ru-en",
    style: "funny",
    language: "ru-RU",
    targetLanguage: "en-US",
    transcript: "я наконец доделал отчёт и прямо сейчас его отправляю",
    must: [/\breport\b/i],
    mustNot: [CYRILLIC, /#\w/],
    maxEmoji: 2,
  },
  {
    id: "translate.rewrite.en-ru",
    style: "rewrite",
    language: "en-US",
    targetLanguage: "ru-RU",
    transcript: "so the client called and the client said they want the new design by next week",
    must: [/клиент/i, /дизайн/i, /следующ/i],
    mustNot: [LATIN_WORD],
    maxEmoji: 0,
    paragraphs: [1, 1],
  },
  {
    id: "translate.email.en-ru",
    style: "email",
    language: "en-US",
    targetLanguage: "ru-RU",
    transcript: "hi tom can you send me the invoice by friday thanks",
    must: [/^(?:Здравствуйте|Привет|Добрый день)[^\n]*\n\n/, /Том/, /сч[её]т/i, /пятниц/i],
    mustNot: [LATIN_WORD],
    maxEmoji: 0,
  },
  {
    id: "translate.funny.en-ru",
    style: "funny",
    language: "en-US",
    targetLanguage: "ru-RU",
    transcript: "the pizza is here everyone come to the kitchen before it gets cold",
    must: [/пицц/i, /кухн/i],
    mustNot: [LATIN_WORD],
    maxEmoji: 2,
  },
];

/** Lowercased letters and digits, one space apart: what "the same words" compares. */
function words(text: string): string {
  return text.normalize("NFC").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

function wordCount(text: string): number {
  return words(text).split(" ").filter(Boolean).length;
}

/** Emoji in the text, one per character as it shows: a family or a flag is one. */
export function emojiCount(text: string): number {
  let count = 0;
  for (const { segment } of new Intl.Segmenter("en", { granularity: "grapheme" }).segment(text)) {
    if (/\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(segment)) count++;
  }
  return count;
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
  if (benchCase.maxEmoji !== undefined) {
    const emoji = emojiCount(outcome.text);
    if (emoji > benchCase.maxEmoji) problems.push(`${emoji} emoji (at most ${benchCase.maxEmoji})`);
  }
  if (benchCase.maxWordRatio !== undefined) {
    const [written, spoken] = [wordCount(outcome.text), wordCount(benchCase.transcript)];
    if (written > benchCase.maxWordRatio * spoken) problems.push(`not shorter (${written} of ${spoken} words)`);
  }
  if (benchCase.paragraphs) {
    const [fewest, most] = benchCase.paragraphs;
    const count = paragraphCount(outcome.text);
    if (count < fewest || count > most) {
      problems.push(`${count} paragraphs (want ${fewest === most ? fewest : `${fewest}–${most}`})`);
    }
  }
  return problems;
}

/** The blocks of text between blank lines. */
export function paragraphCount(text: string): number {
  return text.split(/\n\s*\n/).filter((block) => block.trim() !== "").length;
}
