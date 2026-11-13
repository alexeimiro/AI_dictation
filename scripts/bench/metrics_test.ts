import { assertEquals } from "jsr:@std/assert@1";
import { comparableWords, describeDiff, differenceRate, totalDifference, wordDiff, wordDifference } from "./metrics.ts";

Deno.test("words are compared without case, punctuation or the ё", () => {
  assertEquals(comparableWords("Ещё, не всё — «да»!"), ["еще", "не", "все", "да"]);
  assertEquals(comparableWords("Don’t e-mail  Кто-то.\nNew line"), ["dont", "e", "mail", "кто", "то", "new", "line"]);
  // A decomposed letter is the same letter.
  assertEquals(comparableWords("ёлка й"), ["елка", "й"]);
  assertEquals(comparableWords("3,5 км за 20 минут"), ["3", "5", "км", "за", "20", "минут"]);
  assertEquals(comparableWords(" … "), []);
});

Deno.test("the same words written differently are no difference", () => {
  const difference = wordDifference("Привет, как дела? Всё хорошо.", "привет как дела все хорошо");
  assertEquals(difference, { words: 5, changed: 0, missing: 0, added: 0 });
  assertEquals(differenceRate(difference), 0);
});

Deno.test("changed, missing and added words are counted apart", () => {
  assertEquals(wordDifference("the quick brown fox", "the quack brown fox jumps"), { words: 4, changed: 1, missing: 0, added: 1 });
  assertEquals(wordDifference("a b c d", "a c d"), { words: 4, changed: 0, missing: 1, added: 0 });
  assertEquals(differenceRate(wordDifference("the quick brown fox", "the quack brown fox jumps")), 0.5);
  // Nothing heard: every word is missing.
  assertEquals(wordDifference("one two three", ""), { words: 3, changed: 0, missing: 3, added: 0 });
  assertEquals(differenceRate(wordDifference("one two three", "")), 1);
});

Deno.test("without a reference there is no rate", () => {
  const difference = wordDifference("", "something heard");
  assertEquals(difference, { words: 0, changed: 0, missing: 0, added: 2 });
  assertEquals(differenceRate(difference), null);
});

Deno.test("the steps follow the text, and the report line names only what differs", () => {
  const steps = wordDiff("send it to Okafor by Friday", "send it to a car for by Friday please");
  assertEquals(steps.filter((step) => step.kind === "same").map((step) => step.kind === "same" && step.word), ["send", "it", "to", "by", "friday"]);
  // One reference word against three heard: one change and two additions, in some order.
  const difference = wordDifference("send it to Okafor by Friday", "send it to a car for by Friday please");
  assertEquals(difference, { words: 6, changed: 1, missing: 0, added: 3 });
  assertEquals(describeDiff(wordDiff("the fox ran", "a fox ran away")), "the→a +away");
  assertEquals(describeDiff(wordDiff("я иду домой", "я домой")), "−иду");
  assertEquals(describeDiff(wordDiff("same words", "Same words.")), "");
});

Deno.test("several clips add up by their words", () => {
  const total = totalDifference([
    wordDifference("one two three four five six seven eight nine ten", "one two three four five six seven eight nine ten"),
    wordDifference("hello there", "hello"),
  ]);
  assertEquals(total, { words: 12, changed: 0, missing: 1, added: 0 });
  assertEquals(differenceRate(total), 1 / 12);
  assertEquals(differenceRate(totalDifference([])), null);
});
