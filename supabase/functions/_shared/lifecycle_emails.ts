// The lifecycle emails' words and their layout: each email is a list of blocks, rendered as HTML
// in the look of the sign-in code email (supabase/templates/sign_in_code.html: Murmur's mark,
// black on white, light and dark, no images) and as plain text. _shared/lifecycle.ts decides who
// gets which email and when.

export type Kind =
  | "welcome"
  | "setup"
  | "founder"
  | "personalize"
  | "week_one"
  | "beyond"
  | "score"
  | "trial_ending";

export const KINDS: readonly Kind[] = [
  "welcome", "setup", "founder", "personalize", "week_one", "beyond", "score", "trial_ending",
];

/** Where an account stands on its plan when the email goes out. */
export type PlanState =
  | { kind: "trial"; endsAt: number }
  | { kind: "paid" }
  | { kind: "basic" };

/** What an email may say about the account. */
export interface EmailFacts {
  /** The first word of the account's name, if it has one. */
  firstName: string | null;
  plan: PlanState;
  dictations: number;
  words: number;
  daysUsed: number;
  longestStreak: number;
  now: number;
}

/** Links and lines that are the same for every account, and the account's own links. */
export interface EmailContext {
  /** "https://simplymurmur.com", without a trailing slash. */
  site: string;
  /** The account's link token (email_settings.token). */
  token: string;
  /** The name that signs the founder note, or null to sign it from the team. */
  founder: string | null;
  /** The company's postal address for the footer, or null. */
  postalAddress: string | null;
}

export type Block =
  | { type: "banner"; text: string; link: Link }
  | { type: "heading"; text: string }
  | { type: "paragraph"; text: string }
  | { type: "steps"; items: string[] }
  | { type: "cards"; items: { title: string; text: string }[] }
  | { type: "stats"; items: { value: string; label: string }[] }
  | { type: "button"; link: Link }
  | { type: "tip"; text: string }
  | { type: "scale"; links: string[]; low: string; high: string }
  | { type: "signature"; lines: string[] };

export interface Link {
  label: string;
  href: string;
}

export interface Email {
  kind: Kind;
  subject: string;
  /** The line inboxes show after the subject. */
  preheader: string;
  blocks: Block[];
}

export interface RenderedEmail {
  subject: string;
  html: string;
  text: string;
}

const DAY_MS = 24 * 60 * 60 * 1000;

/** The site page that opens the app on a screen the app's link routes know ("" is Home). */
export function openLink(context: EmailContext, screen: "" | "pro" | "settings" = ""): string {
  return `${context.site}/open/${screen ? `?to=${screen}` : ""}`;
}

export function unsubscribeLink(context: EmailContext): string {
  return `${context.site}/unsubscribe/?t=${encodeURIComponent(context.token)}`;
}

export function scoreLink(context: EmailContext, score: number): string {
  return `${context.site}/score/?t=${encodeURIComponent(context.token)}&s=${score}`;
}

/** Whole days of trial left, rounded up: "5 days". */
export function daysLeft(endsAt: number, now: number): number {
  return Math.max(0, Math.ceil((endsAt - now) / DAY_MS));
}

const plural = (count: number, one: string, many = `${one}s`) =>
  `${count.toLocaleString("en-US")} ${count === 1 ? one : many}`;

/** Minutes saved against typing on a phone (about 40 words a minute) instead of talking (about 150). */
export function minutesSaved(words: number): number {
  return Math.floor(words / 40 - words / 150);
}

const greeting = (facts: EmailFacts) => facts.firstName ? `Hi ${facts.firstName},` : "Hi there,";

const FIRST_DICTATION = [
  "Open any app where you type: Messages, Mail, Notes, ChatGPT.",
  "Tap a text field, then hold the globe key and pick Murmur.",
  "On the keyboard, tap to start Murmur. The app opens for a moment to switch on the microphone; then head back to your app.",
  "Tap to speak, and talk. Tap again when you’re done, and your words appear.",
];

function trialBanner(facts: EmailFacts, context: EmailContext): Block[] {
  if (facts.plan.kind !== "trial") return [];
  const left = daysLeft(facts.plan.endsAt, facts.now);
  if (left < 1) return [];
  return [{
    type: "banner",
    text: `${plural(left, "day")} of Pro left on your trial.`,
    link: { label: "Keep unlimited words", href: openLink(context, "pro") },
  }];
}

function welcome(facts: EmailFacts, context: EmailContext): Email {
  const plan = facts.plan;
  const planLine = plan.kind === "trial"
    ? `You have ${plural(daysLeft(plan.endsAt, facts.now), "day")} of Murmur Pro, on us: unlimited words, no card needed.`
    : plan.kind === "paid"
    ? "Your Murmur Pro subscription is active: no weekly word limit."
    : "Basic gives you 1,000 words of dictation every week, free.";
  return {
    kind: "welcome",
    subject: "Welcome to Murmur",
    preheader: plan.kind === "trial" ? "Two weeks of Pro, on us. Here’s how to start." : "Here’s how to start talking instead of typing.",
    blocks: [
      { type: "heading", text: "Welcome to Murmur" },
      { type: "paragraph", text: greeting(facts) },
      { type: "paragraph", text: `Murmur writes what you say, in any app where you can type. ${planLine}` },
      { type: "heading", text: "Your first dictation" },
      { type: "steps", items: FIRST_DICTATION },
      { type: "button", link: { label: "Open Murmur", href: openLink(context) } },
      {
        type: "tip",
        text: "Talk the way you talk. Change your mind halfway (“Friday at 3… actually 4”) and Murmur writes what you meant: “Friday at 4.”",
      },
      { type: "paragraph", text: "Questions or stuck? Reply to this email. A person reads every one." },
    ],
  };
}

function setup(facts: EmailFacts, context: EmailContext): Email {
  return {
    kind: "setup",
    subject: "One minute left to set up Murmur",
    preheader: "Add the keyboard, then try your first dictation.",
    blocks: [
      { type: "heading", text: "Finish setting up Murmur" },
      { type: "paragraph", text: greeting(facts) },
      {
        type: "paragraph",
        text: "Your Murmur account is ready, but you haven’t dictated yet. Setting up takes about a minute:",
      },
      {
        type: "steps",
        items: [
          "In Settings, open Murmur, tap Keyboards, and turn on Murmur and Allow Full Access.",
          "In any app, tap a text field, hold the globe key and pick Murmur.",
          "Tap to start Murmur, then tap to speak and say something.",
        ],
      },
      { type: "button", link: { label: "Finish setup in Murmur", href: openLink(context) } },
      {
        type: "paragraph",
        text: "Full Access lets the keyboard talk to the Murmur app. Murmur only listens while the mic is on, and never sells what you say.",
      },
      { type: "paragraph", text: "Something not working? Reply to this email and we’ll help." },
    ],
  };
}

function founder(facts: EmailFacts, context: EmailContext): Email {
  return {
    kind: "founder",
    subject: context.founder ? `A note from ${context.founder} at Murmur` : "Three places to try Murmur today",
    preheader: "Messages, email and AI chats: where talking beats typing.",
    blocks: [
      { type: "heading", text: "Talk where you type the most" },
      { type: "paragraph", text: greeting(facts) },
      {
        type: "paragraph",
        text: context.founder
          ? `I’m ${context.founder}, and I make Murmur. I built it because thumbs are slow and thoughts are fast: most people talk about three times faster than they type on a phone. Three places to feel the difference today:`
          : "We made Murmur because thumbs are slow and thoughts are fast: most people talk about three times faster than they type on a phone. Three places to feel the difference today:",
      },
      {
        type: "cards",
        items: [
          { title: "Messages", text: "Answer friends and family in full sentences, not just “ok”." },
          { title: "Email", text: "Say what you mean. Murmur adds the punctuation and leaves out the “um”s." },
          {
            title: "AI chats",
            text: "Give ChatGPT or Claude the whole picture. A long prompt is easy when you can just say it.",
          },
        ],
      },
      { type: "button", link: { label: "Open Murmur", href: openLink(context) } },
      {
        type: "paragraph",
        text: "What you say stays yours. Our server doesn’t keep your recordings or their text, and your transcripts stay on your iPhone.",
      },
      {
        type: "paragraph",
        text: context.founder
          ? "If anything gets in the way, reply to this email. I read every one."
          : "If anything gets in the way, reply to this email. We read every one.",
      },
      { type: "signature", lines: context.founder ? [context.founder, "Founder of Murmur"] : ["The Murmur team"] },
    ],
  };
}

function personalize(facts: EmailFacts, context: EmailContext): Email {
  return {
    kind: "personalize",
    subject: "Make Murmur write like you",
    preheader: "Styles, your Dictionary and Snippets.",
    blocks: [
      ...trialBanner(facts, context),
      { type: "heading", text: "Make it yours" },
      { type: "paragraph", text: "The more Murmur knows about how you write, the less you fix. Three places to start:" },
      {
        type: "cards",
        items: [
          {
            title: "Style",
            text: "Pick how your words come out: Word for word, Improve my grammar, Professional, Casual or Concise. Change it any time from the keyboard.",
          },
          {
            title: "Dictionary",
            text: "Teach Murmur the names and words it gets wrong, like a colleague’s name or your company’s product.",
          },
          {
            title: "Snippets",
            text: "Save text you use often, like your address or a booking link. Say the snippet while dictating, and Murmur types the text in its place.",
          },
        ],
      },
      { type: "button", link: { label: "Open Murmur", href: openLink(context) } },
      {
        type: "tip",
        text: "Speak two languages? Murmur dictates in up to two and switches between them from the keyboard. Pick them in Settings › Languages.",
      },
    ],
  };
}

function weekOne(facts: EmailFacts, context: EmailContext): Email {
  if (facts.dictations === 0) {
    return {
      kind: "week_one",
      subject: "Your first week with Murmur",
      preheader: "One dictation is all it takes to see the difference.",
      blocks: [
        ...trialBanner(facts, context),
        { type: "heading", text: "Your first week" },
        { type: "paragraph", text: greeting(facts) },
        {
          type: "paragraph",
          text: "You haven’t dictated with Murmur yet. Give it one minute today: reply to a message by talking instead of typing.",
        },
        { type: "steps", items: FIRST_DICTATION },
        { type: "button", link: { label: "Open Murmur", href: openLink(context) } },
        { type: "paragraph", text: "If something stopped you, reply and tell us what. We’ll help." },
      ],
    };
  }
  const saved = minutesSaved(facts.words);
  const stats = [
    { value: facts.words.toLocaleString("en-US"), label: facts.words === 1 ? "word dictated" : "words dictated" },
    { value: String(facts.daysUsed), label: facts.daysUsed === 1 ? "day with Murmur" : "days with Murmur" },
    { value: plural(facts.longestStreak, "day"), label: "longest streak" },
  ];
  if (saved >= 1) stats.push({ value: `${saved} min`, label: "time saved" });
  const planLine: Block[] = facts.plan.kind === "trial"
    ? [{
      type: "paragraph",
      text: `Your Pro trial has ${plural(daysLeft(facts.plan.endsAt, facts.now), "day")} left, with no limit on words. After it, Basic gives you 1,000 words a week, free.`,
    }]
    : facts.plan.kind === "basic"
    ? [{ type: "paragraph", text: "Your 1,000 free words come back every week." }]
    : [];
  return {
    kind: "week_one",
    subject: "Your first week with Murmur",
    preheader: `${plural(facts.words, "word")} in your first week.`,
    blocks: [
      { type: "heading", text: "Your first week" },
      { type: "paragraph", text: `${greeting(facts)} here’s your first week with Murmur:` },
      { type: "stats", items: stats },
      ...(saved >= 1
        ? [{
          type: "paragraph" as const,
          text: "Time saved is an estimate: typing on a phone runs at about 40 words a minute, talking at about 150.",
        }]
        : []),
      ...planLine,
      {
        type: "paragraph",
        text: "This week, try Murmur in one app you haven’t used it in yet. Long emails and notes to yourself are good places to start.",
      },
      {
        type: "button",
        link: facts.plan.kind === "trial"
          ? { label: "See Murmur Pro", href: openLink(context, "pro") }
          : { label: "Open Murmur", href: openLink(context) },
      },
    ],
  };
}

function beyond(facts: EmailFacts, context: EmailContext): Email {
  return {
    kind: "beyond",
    subject: "Murmur without the keyboard",
    preheader: "Notes, the Action Button and Siri.",
    blocks: [
      ...trialBanner(facts, context),
      { type: "heading", text: "Dictate before you know where it goes" },
      { type: "paragraph", text: "The keyboard isn’t the only way in. For thoughts that can’t wait:" },
      {
        type: "cards",
        items: [
          {
            title: "Notes",
            text: "A place to dictate when you have nowhere else to put it: an idea, a to-do list, a first draft. Copy it where it belongs later.",
          },
          {
            title: "Action Button",
            text: "On an iPhone with an Action Button, open Settings › Action Button, choose Shortcut, then Murmur’s Dictate. One press and you’re talking.",
          },
          { title: "Siri", text: "Say “Dictate with Murmur” or “New Murmur note”." },
        ],
      },
      { type: "button", link: { label: "Open Murmur", href: openLink(context) } },
    ],
  };
}

function score(_facts: EmailFacts, context: EmailContext): Email {
  return {
    kind: "score",
    subject: "One quick question",
    preheader: "How likely are you to recommend Murmur to a friend?",
    blocks: [
      { type: "heading", text: "How likely are you to recommend Murmur to a friend?" },
      { type: "paragraph", text: "Tap a number. It takes a second, and it tells us what to fix next." },
      {
        type: "scale",
        links: Array.from({ length: 10 }, (_, index) => scoreLink(context, index + 1)),
        low: "1 = not likely",
        high: "10 = very likely",
      },
      { type: "paragraph", text: "After you tap, you can tell us why. We read every answer." },
    ],
  };
}

function trialEnding(facts: EmailFacts, context: EmailContext): Email {
  return {
    kind: "trial_ending",
    subject: "Your Pro trial ends tomorrow",
    preheader: "Nothing to cancel: you’ll move to Basic, free.",
    blocks: [
      { type: "heading", text: "Your Pro trial ends tomorrow" },
      { type: "paragraph", text: greeting(facts) },
      {
        type: "paragraph",
        text: "Your free Murmur Pro trial ends within the next day. There’s nothing to cancel and nothing to pay: if you do nothing, your account moves to Basic.",
      },
      {
        type: "cards",
        items: [
          { title: "Basic, free", text: "1,000 words of dictation a week. They come back every week." },
          {
            title: "Murmur Pro",
            text: "Unlimited words, every week, and translate and polish as much as you like.",
          },
          {
            title: "Everything you set up stays",
            text: "Your style, Dictionary, Snippets and Notes stay the same on either plan.",
          },
        ],
      },
      { type: "button", link: { label: "Keep Pro", href: openLink(context, "pro") } },
      {
        type: "tip",
        text: "Invite a friend from Menu › Invite a friend. They get a month of Pro, and you get a month when they first dictate.",
      },
    ],
  };
}

const BUILDERS: Record<Kind, (facts: EmailFacts, context: EmailContext) => Email> = {
  welcome,
  setup,
  founder,
  personalize,
  week_one: weekOne,
  beyond,
  score,
  trial_ending: trialEnding,
};

export function buildEmail(kind: Kind, facts: EmailFacts, context: EmailContext): Email {
  return BUILDERS[kind](facts, context);
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif";
const INK = "#0D0D0D";
const SECOND = "#5D5D5D";
const THIRD = "#6B6B6B";
const FILL = "#F4F4F4";
const LINE = "#E5E5E5";

export function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

const cell = (style: string, content: string, className = "") =>
  `<tr><td${className ? ` class="${className}"` : ""} style="${style}">${content}</td></tr>`;

function blockHtml(block: Block): string {
  switch (block.type) {
    case "banner":
      return cell(
        `padding:0 0 28px;`,
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>`
          + `<td class="m-fill m-second" style="padding:12px 16px;border-radius:12px;background-color:${FILL};font-family:${FONT};font-size:14px;line-height:20px;color:${SECOND};">`
          + `${escapeHtml(block.text)} <a href="${escapeHtml(block.link.href)}" class="m-ink" style="color:${INK};font-weight:600;text-decoration:underline;">${escapeHtml(block.link.label)}</a>`
          + `</td></tr></table>`,
      );
    case "heading":
      return cell(
        `padding:0 0 14px;font-family:${FONT};font-size:24px;line-height:30px;font-weight:700;letter-spacing:-0.4px;color:${INK};`,
        escapeHtml(block.text),
        "m-ink",
      );
    case "paragraph":
      return cell(
        `padding:0 0 18px;font-family:${FONT};font-size:16px;line-height:24px;color:${SECOND};`,
        escapeHtml(block.text),
        "m-second",
      );
    case "steps":
      return cell(
        "padding:0 0 22px;",
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">`
          + block.items.map((item, index) =>
            `<tr><td valign="top" width="36" style="padding:0 0 12px;">`
            + `<div class="m-fill m-ink" style="width:26px;height:26px;border-radius:13px;background-color:${FILL};font-family:${FONT};font-size:14px;line-height:26px;font-weight:600;text-align:center;color:${INK};">${index + 1}</div></td>`
            + `<td valign="top" class="m-second" style="padding:2px 0 12px;font-family:${FONT};font-size:16px;line-height:23px;color:${SECOND};">${escapeHtml(item)}</td></tr>`
          ).join("")
          + `</table>`,
      );
    case "cards":
      return cell(
        "padding:0 0 22px;",
        block.items.map((item) =>
          `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 10px;"><tr>`
          + `<td class="m-line" style="padding:16px 18px;border:1px solid ${LINE};border-radius:14px;">`
          + `<div class="m-ink" style="font-family:${FONT};font-size:16px;line-height:22px;font-weight:600;color:${INK};padding:0 0 4px;">${escapeHtml(item.title)}</div>`
          + `<div class="m-second" style="font-family:${FONT};font-size:15px;line-height:22px;color:${SECOND};">${escapeHtml(item.text)}</div>`
          + `</td></tr></table>`
        ).join(""),
      );
    case "stats": {
      // Two to a row, so they fit a phone.
      const rows: string[] = [];
      for (let index = 0; index < block.items.length; index += 2) {
        const pair = block.items.slice(index, index + 2);
        rows.push(`<tr>${
          pair.map((item, column) =>
            `<td width="50%" valign="top" style="padding:0 ${column === 0 ? "5px" : "0"} 10px ${column === 1 ? "5px" : "0"};">`
            + `<div class="m-fill" style="padding:16px;border-radius:14px;background-color:${FILL};">`
            + `<div class="m-ink" style="font-family:${FONT};font-size:26px;line-height:32px;font-weight:700;letter-spacing:-0.4px;color:${INK};">${escapeHtml(item.value)}</div>`
            + `<div class="m-second" style="font-family:${FONT};font-size:14px;line-height:20px;color:${SECOND};">${escapeHtml(item.label)}</div>`
            + `</div></td>`
          ).join("")
        }${pair.length === 1 ? `<td width="50%"></td>` : ""}</tr>`);
      }
      return cell(
        "padding:0 0 12px;",
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${rows.join("")}</table>`,
      );
    }
    case "button":
      return cell(
        "padding:6px 0 26px;",
        `<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>`
          + `<td class="m-button" style="border-radius:999px;background-color:${INK};">`
          + `<a href="${escapeHtml(block.link.href)}" class="m-button-text" style="display:inline-block;padding:14px 26px;font-family:${FONT};font-size:16px;line-height:20px;font-weight:600;color:#FFFFFF;text-decoration:none;border-radius:999px;">${escapeHtml(block.link.label)}</a>`
          + `</td></tr></table>`,
      );
    case "tip":
      return cell(
        "padding:0 0 22px;",
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>`
          + `<td class="m-fill" style="padding:16px 18px;border-radius:14px;background-color:${FILL};font-family:${FONT};font-size:15px;line-height:22px;">`
          + `<span class="m-ink" style="font-weight:600;color:${INK};">Tip</span> `
          + `<span class="m-second" style="color:${SECOND};">${escapeHtml(block.text)}</span>`
          + `</td></tr></table>`,
      );
    case "scale":
      return cell(
        "padding:0 0 18px;",
        `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>`
          + block.links.map((href, index) =>
            `<td width="10%" align="center" style="padding:0 2px;">`
            + `<a href="${escapeHtml(href)}" class="m-fill m-ink" style="display:block;padding:12px 0;border-radius:10px;background-color:${FILL};font-family:${FONT};font-size:16px;line-height:20px;font-weight:600;color:${INK};text-decoration:none;">${index + 1}</a></td>`
          ).join("")
          + `</tr></table>`
          + `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>`
          + `<td class="m-third" style="padding:8px 0 0;font-family:${FONT};font-size:13px;line-height:18px;color:${THIRD};">${escapeHtml(block.low)}</td>`
          + `<td align="right" class="m-third" style="padding:8px 0 0;font-family:${FONT};font-size:13px;line-height:18px;color:${THIRD};">${escapeHtml(block.high)}</td>`
          + `</tr></table>`,
      );
    case "signature":
      return cell(
        `padding:0 0 18px;font-family:${FONT};font-size:16px;line-height:24px;color:${INK};`,
        block.lines.map((line, index) =>
          index === 0 ? escapeHtml(line) : `<span class="m-second" style="color:${SECOND};">${escapeHtml(line)}</span>`
        ).join("<br>"),
        "m-ink",
      );
  }
}

function blockText(block: Block): string {
  switch (block.type) {
    case "banner":
      return `${block.text} ${block.link.label}: ${block.link.href}`;
    case "heading":
      return block.text.toUpperCase();
    case "paragraph":
      return block.text;
    case "steps":
      return block.items.map((item, index) => `${index + 1}. ${item}`).join("\n");
    case "cards":
      return block.items.map((item) => `- ${item.title}: ${item.text}`).join("\n");
    case "stats":
      return block.items.map((item) => `- ${item.value} ${item.label}`).join("\n");
    case "button":
      return `${block.link.label}: ${block.link.href}`;
    case "tip":
      return `Tip: ${block.text}`;
    case "scale":
      return `${block.links.map((href, index) => `${index + 1}: ${href}`).join("\n")}\n(${block.low}, ${block.high})`;
    case "signature":
      return block.lines.join("\n");
  }
}

function footerLines(context: EmailContext): string[] {
  return [
    "You’re getting this because you created a Murmur account.",
    ["Murmur · OKNENOR L.L.C-FZ", context.postalAddress].filter(Boolean).join(" · "),
  ];
}

export function renderEmail(email: Email, context: EmailContext): RenderedEmail {
  const unsubscribe = unsubscribeLink(context);
  const [why, company] = footerLines(context);
  const footer = `<tr><td class="m-line m-third" style="padding:18px 0 0;border-top:1px solid ${LINE};font-family:${FONT};font-size:13px;line-height:20px;color:${THIRD};">`
    + `${escapeHtml(why)} <a href="${escapeHtml(unsubscribe)}" class="m-third" style="color:${THIRD};text-decoration:underline;">Unsubscribe</a><br>`
    + `${escapeHtml(company)} · <a href="${escapeHtml(context.site)}" class="m-third" style="color:${THIRD};text-decoration:underline;">simplymurmur.com</a>`
    + `</td></tr>`;
  // Spacers after the preheader keep inboxes from showing the body's first words after it.
  const spacer = "&#8199;&#847;".repeat(40);
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="x-apple-disable-message-reformatting">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<title>${escapeHtml(email.subject)}</title>
<style>
  :root { color-scheme: light dark; supported-color-schemes: light dark; }
  body { margin: 0; padding: 0; -webkit-text-size-adjust: 100%; }
  a[x-apple-data-detectors] { color: inherit !important; text-decoration: none !important; }
  @media (prefers-color-scheme: dark) {
    .m-canvas { background-color: #121212 !important; }
    .m-fill { background-color: #2C2C2E !important; }
    .m-second { color: #C7C7CC !important; }
    .m-third { color: #A0A0A6 !important; }
    .m-ink { color: #FFFFFF !important; }
    .m-line { border-color: #3A3A3C !important; }
    .m-ring { border-color: #FFFFFF !important; }
    .m-dot { background-color: #FFFFFF !important; }
    .m-button { background-color: #FFFFFF !important; }
    .m-button-text { color: #0D0D0D !important; }
  }
</style>
</head>
<body class="m-canvas" style="margin:0;padding:0;background-color:#FFFFFF;">
<div style="display:none;max-height:0;max-width:0;overflow:hidden;opacity:0;mso-hide:all;">${escapeHtml(email.preheader)}${spacer}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" class="m-canvas" style="background-color:#FFFFFF;">
  <tr>
    <td align="center" style="padding:40px 16px 48px;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;">
        <tr>
          <td style="padding:0 0 32px;">
            <table role="presentation" cellpadding="0" cellspacing="0" border="0">
              <tr>
                <td valign="middle" style="padding:0 8px 0 0;">
                  <div class="m-ring" style="width:16px;height:16px;border:2px solid ${INK};border-radius:50%;">
                    <div class="m-dot" style="width:8px;height:8px;margin:4px;border-radius:50%;background-color:${INK};font-size:0;line-height:0;">&nbsp;</div>
                  </div>
                </td>
                <td valign="middle" class="m-ink" style="font-family:${FONT};font-size:20px;line-height:20px;font-weight:600;letter-spacing:-0.4px;color:${INK};">murmur</td>
              </tr>
            </table>
          </td>
        </tr>
${email.blocks.map(blockHtml).join("\n")}
${footer}
      </table>
    </td>
  </tr>
</table>
</body>
</html>
`;
  const text = [
    ...email.blocks.map(blockText),
    "—",
    `${why} Unsubscribe: ${unsubscribe}`,
    `${company} · ${context.site}`,
  ].join("\n\n") + "\n";
  return { subject: email.subject, html, text };
}
