#!/usr/bin/env node
// Builds Murmur's website into build/site: the privacy policy and terms (docs/legal), the support
// page (site/support.md), the home and invite pages (site/*.html), the stylesheet and the app's
// fonts. scripts/publish_site.sh publishes it to GitHub Pages; the app and App Store Connect link
// to its pages.
//
// Usage: node scripts/build_site.mjs
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const out = path.join(root, "build/site");

const PAGES = [
  {
    file: "index.html", source: "site/home.html", title: "Murmur: talk instead of typing",
    description: "Murmur is a voice keyboard for iPhone: talk in any app and it types for you.",
  },
  {
    file: "privacy/index.html", source: "docs/legal/privacy-policy.md", title: "Privacy Policy · Murmur",
    description: "What Murmur collects, why, and the choices you have.",
  },
  {
    file: "terms/index.html", source: "docs/legal/terms-of-use.md", title: "Terms of Use · Murmur",
    description: "The terms for using Murmur and Murmur Pro.",
  },
  {
    file: "support/index.html", source: "site/support.md", title: "Support · Murmur",
    description: "Help with Murmur, and how to reach us.",
  },
  {
    file: "invite/index.html", source: "site/invite.html", title: "Your invite to Murmur",
    description: "A month of Murmur Pro, from a friend.",
  },
];

const FONTS = [
  "Figtree-Regular.ttf", "Figtree-Medium.ttf", "Figtree-SemiBold.ttf", "EBGaramond-Medium.ttf",
  "OFL-Figtree.txt", "OFL-EBGaramond.txt",
];

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

function page({ file, title, description }, body) {
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
<link rel="stylesheet" href="${up}style.css">
</head>
<body>
<header class="site"><a class="brand" href="${up}">Murmur</a></header>
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
fs.mkdirSync(path.join(out, "fonts"));
for (const font of FONTS) {
  fs.copyFileSync(path.join(root, "App/Resources/Fonts", font), path.join(out, "fonts", font));
}
// GitHub Pages serves the files as they are, without Jekyll.
fs.writeFileSync(path.join(out, ".nojekyll"), "");
// The custom domain. Each publish replaces the whole gh-pages branch, so the CNAME file that keeps
// the domain set has to be part of every build.
fs.writeFileSync(path.join(out, "CNAME"), "simplymurmur.com\n");
console.log(`Built ${PAGES.length} pages into ${path.relative(root, out)}`);
