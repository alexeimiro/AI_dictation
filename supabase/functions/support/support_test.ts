import { assert, assertEquals } from "jsr:@std/assert@1";
import type { Caller } from "../_shared/http.ts";
import {
  createSupportHandler,
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
const NOW = Date.UTC(2026, 10, 13, 9, 5);
const CONFIG: MailConfig = { apiKey: "re_test", to: ["help@example.com"], from: "Murmur <no-reply@simplymurmur.com>" };
const DIAGNOSTICS = { app: "1.0 (202611131200)", os: "iOS 26.1", device: "iPhone", locale: "ru-RU", kind: "issue",
  topic: "Dictation" };

interface World {
  deps: SupportDeps;
  saved: SupportMessage[];
  emails: SupportEmail[];
  later: Promise<unknown>[];
}

function world(options: { mail?: boolean; email?: string | null; limited?: boolean; saveFails?: boolean;
  caller?: Caller | null } = {}): World {
  const saved: SupportMessage[] = [];
  const emails: SupportEmail[] = [];
  const later: Promise<unknown>[] = [];
  const deps: SupportDeps = {
    authenticate: () => Promise.resolve(options.caller === undefined ? { userId: USER, isAnonymous: false } : options.caller),
    withinLimit: () => Promise.resolve(!options.limited),
    save: (_userId, message) => {
      if (options.saveFails) return Promise.reject(new Error("database down"));
      saved.push(message);
      return Promise.resolve();
    },
    accountEmail: () => Promise.resolve(options.email === undefined ? "olga@example.com" : options.email),
    mail: options.mail === false ? null : {
      config: CONFIG,
      send: (email) => {
        emails.push(email);
        return Promise.resolve(true);
      },
    },
    later: (task) => later.push(task),
    now: () => NOW,
  };
  return { deps, saved, emails, later };
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
    { apiKey: "re_x", to: ["a@example.com", "b@example.org"], from: "Murmur <no-reply@simplymurmur.com>" });
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
  assertEquals(w.saved, [{ message: "The mic stops after a minute.", diagnostics: DIAGNOSTICS }]);
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

Deno.test("a guest's message is emailed without a reply address", async () => {
  const w = world({ email: null });
  await send(w, { message: "Love it", diagnostics: { kind: "feedback" } });
  assertEquals(w.emails[0].reply_to, undefined);
  assertEquals(w.emails[0].subject, "Murmur feedback: Love it");
  assert(w.emails[0].text.includes("From: a guest, with no email"));
  assert(!w.emails[0].text.includes("Reply to this email"));
});

Deno.test("without mail settings a message is only saved", async () => {
  const w = world({ mail: false });
  assertEquals(await send(w), { status: 200, body: { saved: true } });
  assertEquals(w.saved.length, 1);
  assertEquals(w.emails, []);
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
