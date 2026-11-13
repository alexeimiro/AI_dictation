// A spoken test set for live_bench.ts, made with the Mac's own voices: each line below becomes
// `<group>-say-NN.wav` (PCM16, mono, 16 kHz: what the app sends) and `<group>-say-NN.txt`, its
// reference text. Synthetic speech: good for timing a service and for seeing how it writes
// punctuation, numbers, names and spoken commands, not for judging how well it hears a person.
//
//   deno run --allow-run=say --allow-write scripts/bench/say_clips.ts [--out scripts/out/live_bench_clips] [--ru Milena] [--en Samantha]
//
// `say -v '?'` lists the voices installed; more come from System Settings › Accessibility › Spoken Content.
import { flagValue } from "./live_spike.ts";

interface Line {
  /** What the voice reads. */
  say: string;
  /** How a good transcript writes it, when that isn't what is read: numbers as figures. */
  text?: string;
}

/** By group: the clip's name starts with it, and the voice of its language reads it ("mix" is Russian with English terms). */
const LINES: Record<string, Line[]> = {
  ru: [
    // A dictation that is over almost as it starts.
    { say: "Да, хорошо, давай так и сделаем." },
    { say: "Привет! Я сегодня задержусь на работе, буду дома около восьми." },
    { say: "Ты не забыл купить молоко и хлеб по дороге домой?" },
    // Numbers, a date, a time, money.
    {
      say: "Встреча перенесена на двадцать третье ноября, на пятнадцать тридцать. Бюджет — две тысячи пятьсот долларов.",
      text: "Встреча перенесена на 23 ноября, на 15:30. Бюджет — 2500 долларов.",
    },
    // Names: try them with --keywords Мироненко,Окафор and without.
    { say: "Передай Антону Мироненко, что документы для Окафора готовы." },
    // Spoken commands: a service may write them as words or act on them.
    { say: "Список покупок двоеточие новая строка молоко запятая хлеб запятая сыр точка" },
    {
      say: "Я посмотрел новый макет главного экрана. В целом мне нравится, но кнопка записи слишком маленькая, " +
        "и её трудно нажать одной рукой. Давай увеличим её и поднимем чуть выше. Ещё я бы убрал вторую строку " +
        "под заголовком, она ничего не добавляет. Пришли, пожалуйста, обновлённый вариант до конца недели.",
    },
  ],
  en: [
    { say: "OK, sounds good, thanks." },
    { say: "Hi! I'm running about ten minutes late, so please start without me." },
    { say: "Did you get a chance to look at the report I sent yesterday?" },
    {
      say: "The meeting moved to November twenty-third at three thirty p.m. The budget is two thousand five hundred dollars.",
      text: "The meeting moved to November 23rd at 3:30 p.m. The budget is $2,500.",
    },
    { say: "Please tell Anton Mironenko that the documents for Okafor are ready." },
    { say: "Shopping list colon new line milk comma bread comma cheese period" },
    {
      say: "I looked at the new design for the home screen. Overall I like it, but the record button is too small " +
        "and hard to reach with one hand. Let's make it bigger and move it up a little. I would also remove the " +
        "second line under the title, because it doesn't add anything. Please send me the updated version by the end of the week.",
    },
  ],
  mix: [
    { say: "Скинь мне, пожалуйста, pull request до пятницы, я посмотрю его на выходных." },
    { say: "У нас завтра stand-up в десять, а потом demo для клиента." },
  ],
};

if (import.meta.main) {
  const out = flagValue("--out") ?? "scripts/out/live_bench_clips";
  const voices: Record<string, string> = {
    ru: flagValue("--ru") ?? "Milena",
    en: flagValue("--en") ?? "Samantha",
    mix: flagValue("--ru") ?? "Milena",
  };
  await Deno.mkdir(out, { recursive: true });
  let made = 0;
  for (const [group, lines] of Object.entries(LINES)) {
    for (const [index, line] of lines.entries()) {
      const name = `${out}/${group}-say-${String(index + 1).padStart(2, "0")}`;
      const { success, stderr } = await new Deno.Command("say", {
        args: ["-v", voices[group], "-o", `${name}.wav`, "--data-format=LEI16@16000", line.say],
        stderr: "piped",
      }).output();
      if (!success) throw new Error(`say could not read a ${group} line with the voice ${voices[group]}: ${new TextDecoder().decode(stderr).trim()}`);
      await Deno.writeTextFile(`${name}.txt`, `${line.text ?? line.say}\n`);
      made++;
    }
  }
  console.error(`${made} clips in ${out}`);
}
