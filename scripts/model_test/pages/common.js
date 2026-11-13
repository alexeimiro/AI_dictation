// Helpers both pages share: the local API, times, and a word diff that matches the report's
// (scripts/bench/metrics.ts): case, punctuation and ё/е don't count as differences.

export async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { "Content-Type": "application/json", ...(options.headers ?? {}) },
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
  return body;
}

export function seconds(ms) {
  return ms == null ? "?" : `${(ms / 1000).toFixed(1)} s`;
}

export function groupName(group) {
  return { ru: "Russian", mix: "Mixed", en: "English" }[group] ?? group;
}

/** A word as the comparison sees it. */
function comparable(word) {
  return word.normalize("NFKC").toLowerCase().replaceAll("ё", "е").replace(/['’ʼ`]/g, "");
}

/** The text as display pieces: words (with the key they compare by) and what is between them. */
export function pieces(text) {
  const parts = [];
  const pattern = /[\p{L}\p{M}\p{N}'’ʼ`]+/gu;
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > last) parts.push({ text: text.slice(last, match.index) });
    parts.push({ text: match[0], key: comparable(match[0]) });
    last = match.index + match[0].length;
  }
  if (last < text.length) parts.push({ text: text.slice(last) });
  return parts;
}

/** Which words of `text` are not matched in `reference` (a longest common subsequence of words). */
export function differing(reference, text) {
  const from = pieces(reference).filter((part) => part.key).map((part) => part.key);
  const parts = pieces(text);
  const words = parts.filter((part) => part.key);
  const to = words.map((part) => part.key);
  const width = to.length + 1;
  const table = new Uint32Array((from.length + 1) * width);
  for (let i = from.length - 1; i >= 0; i--) {
    for (let j = to.length - 1; j >= 0; j--) {
      table[i * width + j] = from[i] === to[j]
        ? table[(i + 1) * width + j + 1] + 1
        : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  const matched = new Set();
  let i = 0;
  let j = 0;
  while (i < from.length && j < to.length) {
    if (from[i] === to[j]) {
      matched.add(j);
      i++;
      j++;
    } else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) i++;
    else j++;
  }
  let index = 0;
  return parts.map((part) => part.key ? { text: part.text, differs: !matched.has(index++) } : { text: part.text, differs: false });
}

/** `text` as HTML, with the words that differ from `reference` marked. */
export function highlighted(reference, text, on = true) {
  return differing(reference, text)
    .map((part) => on && part.differs ? `<mark>${escape(part.text)}</mark>` : escape(part.text))
    .join("");
}

export function escape(text) {
  return text.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
}

/** A remembered choice on this browser only; the page works the same without it. */
export const remembered = {
  get(key, fallback) {
    try {
      const value = localStorage.getItem(`model-test:${key}`);
      return value === null ? fallback : JSON.parse(value);
    } catch {
      return fallback;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(`model-test:${key}`, JSON.stringify(value));
    } catch {
      // Private window: nothing kept.
    }
  },
};
