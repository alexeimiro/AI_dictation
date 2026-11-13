import { assert, assertEquals } from "jsr:@std/assert@1";
import type { Caller } from "../_shared/http.ts";
import {
  createSupportHandler,
  DEFAULT_DAILY_LIMIT,
  mailConfig,
  type MailConfig,
  sendWithResend,
  type SupportDeps,
  supportEmail,
  type SupportEmail,
  supportMessage,
  type SupportMessage,
} from "../_shared/support.ts";

const USER = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const GUEST: Caller = { userId: "6fa459ea-ee8a-4ca4-894e-db77e160355e", isAnonymous: true };
const NOW = Date.UTC(2026, 10, 13, 9, 5);
const CONFIG: MailConfig = { apiKey: "re_test", to: ["help@example.com"], from: "Murmur <no-reply@simplymurmur.com>",
  dailyLimit: 20 };
const DIAGNOSTICS = { app: "1.0 (202611131200)", os: "iOS 26.1", device: "iPhone", locale: "ru-RU", kind: "issue",
  topic: "Dictation" };

interface World {
  deps: SupportDeps;
  saved: SupportMessage[];
  emails: SupportEmail[];
  /** The `since` of each count of signed-in messages. */
  counted: string[];
  later: Promise<unknown>[];
}

function world(options: { mail?: boolean; email?: string | null; limited?: boolean; saveFails?: boolean;
  caller?: Caller | null; dailyLimit?: number; recent?: number | Error } = {}): World {
  const saved: SupportMessage[] = [];
  const emails: SupportEmail[] = [];
  const counted: string[] = [];
  const later: Promise<unknown>[] = [];
  const deps: SupportDeps = {
    authenticate: () => Promise.resolve(options.caller === undefined ? { userId: USER, isAnonymous: false } : options.caller),
    withinLimit: () => Promise.resolve(!options.limited),
    save: (_userId, message) => {
      if (options.saveFails) return Promise.reject(new Error("database down"));
      saved.push(message);
      return Promise.resolve();
    },
    // By default this message is the day's first.
    countSignedIn: (since) => {
      counted.push(since);
      const recent = options.recent ?? 1;
      return recent instanceof Error ? Promise.reject(recent) : Promise.resolve(recent);
    },
    accountEmail: () => Promise.resolve(options.email === undefined ? "olga@example.com" : options.email),
    mail: options.mail === false ? null : {
      config: { ...CONFIG, dailyLimit: options.dailyLimit ?? CONFIG.dailyLimit },
      send: (email) => {
        emails.push(email);
        return Promise.resolve(true);
      },
    },
    later: (task) => later.push(task),
    now: () => NOW,
  };
  return { deps, saved, emails, counted, later };
}

/** Runs `work` with console.log and console.error silenced, and returns what was logged as JSON. */
async function logged(work: () => Promise<unknown>): Promise<Record<string, unknown>[]> {
  const lines: Record<string, unknown>[] = [];
  const { log, error } = console;
  console.log = (line: string) => void lines.push(JSON.parse(line));
  console.error = () => {};
  try {
    await work();
  } finally {
    console.log = log;
    console.error = error;
  }
  return lines;
}

async function send(w: World, body: unknown = { message: "The mic stops after a minute.", diagnostics: DIAGNOSTICS }) {
  const response = await createSupportHandler(w.deps)(new Request("http://localhost/support", {
    method: "POST", headers: { Authorization: "Bearer jwt" }, body: JSON.stringify(body),
  }));
  await Promise.all(w.later);
  return { status: response.status, body: await response.json().catch(() => null) };
}

Deno.test("no key or no address: nothing is emailed", () => {
  assertEquals(mailConfig(new Map()), null);
  assertEquals(mailConfig(new Map([["RESEND_API_KEY", "re_x"]])), null);
  assertEquals(mailConfig(new Map([["RESEND_API_KEY", "re_x"], ["SUPPORT_EMAIL_TO", "not an address"]])), null);
  assertEquals(mailConfig(new Map([["RESEND_API_KEY", "re_x"], ["SUPPORT_EMAIL_TO", " a@example.com, b@example.org "]])),
    { apiKey: "re_x", to: ["a@example.com", "b@example.org"], from: "Murmur <no-reply@simplymurmur.com>", dailyLimit: 20 });
});

Deno.test("the daily limit is 20 unless SUPPORT_EMAIL_DAILY_LIMIT is a whole number; 0 emails none", () => {
  const limit = (value?: string) => {
    const env = new Map([["RESEND_API_KEY", "re_x"], ["SUPPORT_EMAIL_TO", "a@example.com"]]);
    if (value !== undefined) env.set("SUPPORT_EMAIL_DAILY_LIMIT", value);
    return mailConfig(env)?.dailyLimit;
  };
  assertEquals(DEFAULT_DAILY_LIMIT, 20);
  assertEquals([limit(), limit(""), limit(" 50 "), limit("0")], [20, 20, 50, 0]);
  for (const odd of ["-1", "2.5", "lots"]) assertEquals(limit(odd), 20, odd);
});

Deno.test("a message is trimmed to what the table takes, and diagnostics to short strings", () => {
  assertEquals(supportMessage({ message: "  hi  ", diagnostics: { app: "1.0", kind: "issue" } }),
    { message: "hi", diagnostics: { app: "1.0", kind: "issue" } });
  assertEquals(supportMessage({ message: "   " }), null);
  assertEquals(supportMessage({ message: "x".repeat(5001) }), null);
  assertEquals(supportMessage({ message: 7 }), null);
  assertEquals(supportMessage(null), null);
  const odd = supportMessage({ message: "hi", diagnostics: { "Bad Key": "x", nested: { a: 1 }, long: "y".repeat(300) } });
  assertEquals(odd?.diagnostics, { long: "y".repeat(200) });
  assertEquals(supportMessage({ message: "hi", diagnostics: ["app"] })?.diagnostics, {});
});

Deno.test("a message is saved, answered at once, then emailed with a way to reply", async () => {
  const w = world();
  assertEquals(await send(w), { status: 200, body: { saved: true } });
  assertEquals(w.saved, [{ message: "The mic stops after a minute.", diagnostics: { ...DIAGNOSTICS, account: "signed_in" } }]);
  assertEquals(w.emails.length, 1);
  const email = w.emails[0];
  assertEquals(email.to, ["help@example.com"]);
  assertEquals(email.from, "Murmur <no-reply@simplymurmur.com>");
  assertEquals(email.reply_to, "olga@example.com");
  assertEquals(email.subject, "Murmur issue (Dictation): The mic stops after a minute.");
  assert(email.text.startsWith("The mic stops after a minute.\n"));
  assert(email.text.includes(`From: olga@example.com · account ${USER}`));
  assert(email.text.includes("App: 1.0 (202611131200) · iOS 26.1 · iPhone · ru-RU"));
  assert(email.text.includes("Sent: 2026-11-13 09:05 UTC"));
});

Deno.test("an account with no email address is emailed without a reply address", async () => {
  const w = world({ email: null });
  await send(w, { message: "Love it", diagnostics: { kind: "feedback" } });
  assertEquals(w.emails[0].reply_to, undefined);
  assertEquals(w.emails[0].subject, "Murmur feedback: Love it");
  assert(w.emails[0].text.includes("From: an account with no email address"));
  assert(!w.emails[0].text.includes("Reply to this email"));
});

Deno.test("a guest's message is saved as a guest's and never emailed, whatever the app says", async () => {
  const w = world({ caller: GUEST });
  // A guest account costs nothing to make: its messages must not reach Resend's daily emails.
  const lines = await logged(() => send(w, { message: "Spam", diagnostics: { kind: "issue", account: "signed_in" } }));
  assertEquals(w.saved, [{ message: "Spam", diagnostics: { kind: "issue", account: "guest" } }]);
  assertEquals(w.emails, []);
  assertEquals(w.counted, [], "a guest's message never counts towards the day's emails");
  assertEquals(lines, [{ event: "support_message", emailed: false, reason: "guest" }]);
});

Deno.test("signed-in messages are emailed up to the daily limit, counted over the last 24 hours", async () => {
  // This message is among those counted: the 20th of the last 24 hours goes out, the 21st doesn't.
  const last = world({ recent: 20 });
  await send(last);
  assertEquals(last.emails.length, 1);
  assertEquals(last.counted, ["2026-11-12T09:05:00.000Z"]);

  const over = world({ recent: 21 });
  const lines = await logged(() => send(over));
  assertEquals(over.saved.length, 1, "it is still saved");
  assertEquals(over.emails, []);
  assertEquals(lines, [{ event: "support_message", emailed: false, reason: "daily_limit" }]);

  const none = world({ dailyLimit: 0 });
  await logged(() => send(none));
  assertEquals([none.saved.length, none.emails.length], [1, 0], "a limit of 0 emails nothing");
});

Deno.test("a count that fails emails nothing", async () => {
  const w = world({ recent: new Error("database down") });
  const lines = await logged(() => send(w));
  assertEquals([w.saved.length, w.emails.length], [1, 0]);
  assertEquals(lines, [{ event: "support_message", emailed: false, reason: "count_failed" }]);
});

Deno.test("without mail settings a message is only saved", async () => {
  const w = world({ mail: false });
  const lines = await logged(async () => assertEquals(await send(w), { status: 200, body: { saved: true } }));
  assertEquals(w.saved.length, 1);
  assertEquals([w.emails, w.counted], [[], []]);
  assertEquals(lines, [{ event: "support_message", emailed: false, reason: "no_mail_config" }]);
});

Deno.test("refused requests save nothing and email nothing", async () => {
  for (const [w, body, status] of [
    [world({ caller: null }), undefined, 401],
    [world(), { message: "" }, 400],
    [world({ limited: true }), undefined, 429],
    [world({ saveFails: true }), undefined, 503],
  ] as const) {
    assertEquals((await send(w, body)).status, status);
    assertEquals(w.saved, []);
    assertEquals(w.emails, []);
  }
});

Deno.test("the subject is one clean line, whatever the message holds", () => {
  const email = supportEmail({ message: "\n\nFirst line\u0007 here\nsecond line", diagnostics: { topic: "Key\nboard" } },
    { id: USER, email: null }, CONFIG, NOW);
  assertEquals(email.subject, "Murmur issue (Key): First line here");
  const long = supportEmail({ message: "w".repeat(100), diagnostics: {} }, { id: USER, email: null }, CONFIG, NOW);
  assertEquals(long.subject, `Murmur issue: ${"w".repeat(59)}…`);
});

Deno.test("Resend gets the email as JSON with the key, and a refusal is false", async () => {
  const sent: { url: string; init: RequestInit }[] = [];
  const answer = (status: number) => ((url: string | URL | Request, init?: RequestInit) => {
    sent.push({ url: String(url), init: init ?? {} });
    return Promise.resolve(new Response("{}", { status }));
  }) as typeof fetch;
  const email = supportEmail({ message: "hi", diagnostics: {} }, { id: USER, email: "o@example.com" }, CONFIG, NOW);
  assertEquals(await sendWithResend(email, "re_key", { fetcher: answer(200) }), true);
  assertEquals(sent[0].url, "https://api.resend.com/emails");
  assertEquals(new Headers(sent[0].init.headers).get("Authorization"), "Bearer re_key");
  assertEquals(JSON.parse(String(sent[0].init.body)), email);
  assertEquals(await sendWithResend(email, "re_key", { fetcher: answer(422) }), false);
  const offline = (() => Promise.reject(new TypeError("offline"))) as typeof fetch;
  assertEquals(await sendWithResend(email, "re_key", { fetcher: offline }), false);
});
