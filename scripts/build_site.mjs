#!/usr/bin/env node
// Builds Murmur's website into build/site: the privacy policy and terms (docs/legal), the support
// page (site/support.md), the home and invite pages, the pages the lifecycle emails link to
// (site/*.html) and the stylesheet.
// scripts/publish_site.sh publishes it to GitHub Pages; the app and App Store Connect link to its
// pages.
//
// Usage: node scripts/build_site.mjs
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const out = path.join(root, "build/site");

const PAGES = [
  {
    file: "index.html", source: "site/home.html", title: "Redmic: talk instead of typing",
    description: "Redmic is a keyboard for iPhone that writes what you say, in any text field.",
    appStoreBanner: true,
  },
  {
    file: "privacy/index.html", source: "docs/legal/privacy-policy.md", title: "Privacy Policy · Redmic",
    description: "What Redmic collects, why, and the choices you have.",
  },
  {
    file: "terms/index.html", source: "docs/legal/terms-of-use.md", title: "Terms of Use · Redmic",
    description: "The terms for using Redmic and Redmic Pro.",
  },
  {
    file: "support/index.html", source: "site/support.md", title: "Support · Redmic",
    description: "Help with Redmic, and how to reach us.",
  },
  {
    file: "invite/index.html", source: "site/invite.html", title: "Your invite to Redmic",
    description: "A month of Redmic Pro, from a friend.",
  },
  // Where the lifecycle emails' links go (supabase/functions/_shared/lifecycle_emails.ts).
  {
    file: "open/index.html", source: "site/open.html", title: "Open Redmic",
    description: "Opens Redmic on your iPhone.",
  },
  {
    file: "unsubscribe/index.html", source: "site/unsubscribe.html", title: "Unsubscribe · Redmic",
    description: "Stop Redmic's tips and reminders.",
  },
  {
    file: "score/index.html", source: "site/score.html", title: "Thanks for answering · Redmic",
    description: "How likely are you to recommend Redmic to a friend?",
  },
];

// Redmic's mark, the red dot in a ring, on the app's 24-unit grid (MarkGeometry in MurmurBrand).
const MARK = `<svg viewBox="0 0 24 24" aria-hidden="true"><circle class="mark-dot" cx="12" cy="12" r="4.2"/>`
  + `<circle cx="12" cy="12" r="9.2" fill="none" stroke="currentColor" stroke-width="1.8"/></svg>`;

const escape = (text) =>
  text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

/** Links, bare URLs and emails become anchors; then **bold** and `code`. */
function inline(text) {
  const anchors = [];
  const keep = (html) => `\u0000${anchors.push(html) - 1}\u0000`;
  const marked = text
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, url) => keep(`<a href="${escape(url)}">${escape(label)}</a>`))
    .replace(/https?:\/\/[^\s)<]*[^\s)<.,;:]/g, (url) => keep(`<a href="${escape(url)}">${escape(url)}</a>`))
    .replace(/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/g, (email) => keep(`<a href="mailto:${email}">${email}</a>`));
  return escape(marked)
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\u0000(\d+)\u0000/g, (_, index) => anchors[Number(index)]);
}

/** The Markdown the legal pages use: headings, paragraphs, and lists whose items wrap. */
function markdown(text) {
  const html = [];
  let paragraph = [];
  let list = null;
  const flushParagraph = () => {
    if (paragraph.length) html.push(`<p>${inline(paragraph.join(" "))}</p>`);
    paragraph = [];
  };
  const flushList = () => {
    if (list) html.push(`<${list.tag}>\n${list.items.map((item) => `<li>${inline(item)}</li>`).join("\n")}\n</${list.tag}>`);
    list = null;
  };
  for (const line of text.replace(/\r/g, "").split("\n")) {
    const heading = /^(#{1,3})\s+(.*)$/.exec(line);
    const item = /^(-|\d+\.)\s+(.*)$/.exec(line);
    if (!line.trim()) {
      flushParagraph();
      flushList();
    } else if (heading) {
      flushParagraph();
      flushList();
      const level = heading[1].length;
      html.push(`<h${level}>${inline(heading[2])}</h${level}>`);
    } else if (item) {
      flushParagraph();
      const tag = item[1] === "-" ? "ul" : "ol";
      if (list && list.tag !== tag) flushList();
      list ??= { tag, items: [] };
      list.items.push(item[2]);
    } else if (list && /^\s+\S/.test(line)) {
      list.items[list.items.length - 1] += ` ${line.trim()}`;
    } else {
      flushList();
      paragraph.push(line.trim());
    }
  }
  flushParagraph();
  flushList();
  return html.join("\n");
}

// Safari on iPhone shows its App Store banner (Open or Get) for this app ID.
const APP_STORE_ID = "6829429992";

function page({ file, title, description, appStoreBanner }, body) {
  const depth = file.split("/").length - 1;
  const up = depth ? "../".repeat(depth) : "./";
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${escape(title)}</title>
<meta name="description" content="${escape(description)}">
${appStoreBanner ? `<meta name="apple-itunes-app" content="app-id=${APP_STORE_ID}">\n` : ""}<link rel="stylesheet" href="${up}style.css">
</head>
<body>
<header class="site"><a class="brand" href="${up}" aria-label="Redmic">${MARK}<span><span class="red">r</span>ed<span class="red">m</span>ic</span></a></header>
<main>
${body.trim()}
</main>
<footer class="site">
<nav><a href="${up}support/">Support</a><a href="${up}privacy/">Privacy Policy</a><a href="${up}terms/">Terms of Use</a></nav>
<p>© 2026 OKNENOR L.L.C-FZ</p>
</footer>
</body>
</html>
`;
}

fs.rmSync(out, { recursive: true, force: true });
for (const spec of PAGES) {
  const source = fs.readFileSync(path.join(root, spec.source), "utf8");
  const body = spec.source.endsWith(".md") ? markdown(source) : source;
  const target = path.join(out, spec.file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, page(spec, body));
}
fs.copyFileSync(path.join(root, "site/style.css"), path.join(out, "style.css"));
// GitHub Pages serves the files as they are, without Jekyll.
fs.writeFileSync(path.join(out, ".nojekyll"), "");
// The custom domain. Each publish replaces the whole gh-pages branch, so the CNAME file that keeps
// the domain set has to be part of every build.
fs.writeFileSync(path.join(out, "CNAME"), "simplymurmur.com\n");
console.log(`Built ${PAGES.length} pages into ${path.relative(root, out)}`);
