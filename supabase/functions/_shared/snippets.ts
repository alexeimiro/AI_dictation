// A snippet's place in a text: ⟦s:<id>⟧, which the app swaps for the snippet's text on the device.
// The model was asked to put the placeholders in itself, and in the live checks of November 2026 it
// didn't every time: a trigger at the start of a punctuated sentence came back as "My ⟦…⟧" five
// times of five, a Russian one was left as words or rewritten in another case («по моему адресу»),
// and a translation translated it. A placeholder already in the transcript was kept 25 times of
// 25. So the trigger said word for word is marked here, before the model reads the transcript, and
// the model is left the cases only it can judge (another form of the phrase). The app marks a text
// no model writes the same way (`SnippetPlaceholders` in MurmurCore).
import type { SnippetRef } from "./types.ts";

const PLACEHOLDER = "⟦s:[0-9a-f]{8}⟧";

/** `phrase` as a pattern that matches it literally. Russian «ё» is written and recognized as «е» too. */
function phrasePattern(phrase: string): string {
  return phrase
    .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    .replace(/[её]/g, "[её]")
    .replace(/[ЕЁ]/g, "[ЕЁ]");
}

/**
 * Puts each snippet's placeholder where its trigger stands in `text`: the whole phrase, in any
 * capitals. One pass, so a trigger never matches inside a placeholder, and of two triggers that
 * start at the same word the longer wins ("my work email" over "my email").
 */
export function markSnippets(text: string, snippets: SnippetRef[]): string {
  const spoken = snippets.filter((snippet) => snippet.trigger.length > 0)
    .sort((a, b) => b.trigger.length - a.trigger.length);
  if (spoken.length === 0) return text;
  const triggers = spoken.map((snippet) => `(${phrasePattern(snippet.trigger)})`).join("|");
  // A placeholder already in the text matches first, with no group, and stays as it is.
  const pattern = new RegExp(`${PLACEHOLDER}|(?<![\\p{L}\\p{N}])(?:${triggers})(?![\\p{L}\\p{N}])`, "giu");
  return text.replace(pattern, (match: string, ...groups: unknown[]) => {
    const said = groups.slice(0, spoken.length).findIndex((group) => group !== undefined);
    return said < 0 ? match : spoken[said].token;
  });
}

/**
 * The model's reply with the snippets it missed marked too. Its words for a trigger left beside
 * that trigger's own placeholder go (the whole trigger, or the part it didn't replace: "My ⟦…⟧"
 * for "my home address"), and a trigger still written as words is marked as in the transcript.
 */
export function repairSnippets(reply: string, snippets: SnippetRef[]): string {
  let output = reply;
  for (const snippet of snippets) {
    if (!output.includes(snippet.token)) continue;
    const words = snippet.trigger.split(/\s+/u).filter((word) => word.length > 0);
    const token = phrasePattern(snippet.token);
    // The longest part first: the whole trigger, then "my home ⟦…⟧", then "my ⟦…⟧".
    for (let count = words.length; count >= 1; count--) {
      const start = phrasePattern(words.slice(0, count).join(" "));
      const end = phrasePattern(words.slice(-count).join(" "));
      output = output
        .replace(new RegExp(`(?<![\\p{L}\\p{N}])${start}\\s+${token}`, "giu"), () => snippet.token)
        .replace(new RegExp(`${token}\\s+${end}(?![\\p{L}\\p{N}])`, "giu"), () => snippet.token);
    }
  }
  return markSnippets(output, snippets);
}
