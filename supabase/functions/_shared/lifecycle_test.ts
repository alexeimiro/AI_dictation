import { assert, assertEquals, assertFalse, assertStringIncludes } from "jsr:@std/assert@1";
import { createPreferencesHandler, type PreferencesDeps } from "./email_preferences.ts";
import {
  type Candidate,
  createLifecycleHandler,
  decide,
  firstName,
  lifecycleConfig,
  type LifecycleConfig,
  type LifecycleDeps,
  missingSettings,
  type OutgoingEmail,
  outgoingEmail,
  PER_RUN,
  planFor,
  previewFacts,
  sendThroughResend,
  type SendResult,
} from "./lifecycle.ts";
import { buildEmail, type EmailContext, KINDS, type Kind, minutesSaved, renderEmail } from "./lifecycle_emails.ts";

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const NOW = Date.UTC(2026, 10, 16, 12, 0);
const USER = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const TOKEN = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";

const env = (values: Record<string, string>) => ({ get: (name: string) => values[name] });

const LIVE: LifecycleConfig = {
  ...lifecycleConfig(env({ SUPABASE_URL: "https://ref.supabase.co" })),
  mode: "live",
  start: NOW - 30 * DAY,
  apiKey: "re_test",
  postalAddress: "PO Box 1, Dubai, UAE",
  replyTo: "help@example.com",
  adminKey: "admin-key-0123456789abcdef",
};

function person(overrides: Partial<Candidate> = {}): Candidate {
  return {
    userId: USER,
    email: "ivy@example.com",
    fullName: "Ivy Chen",
    createdAt: NOW - 20 * MINUTE,
    paid: false,
    trialCheck: "granted",
    trialEndsAt: NOW - 20 * MINUTE + 14 * DAY,
    token: TOKEN,
    dictations: 0,
    words: 0,
    daysUsed: 0,
    longestStreak: 0,
    handled: new Set(),
    lastSentAt: null,
    ...overrides,
  };
}

const handled = (...kinds: Kind[]) => new Set<string>(kinds);
const dayOld = (days: number, overrides: Partial<Candidate> = {}) =>
  person({
    createdAt: NOW - days * DAY,
    trialEndsAt: NOW - days * DAY + 14 * DAY,
    handled: handled("welcome", "setup"),
    lastSentAt: NOW - 2 * DAY,
    ...overrides,
  });

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

Deno.test("settings: off by default, with the sender, reply-to and cap defaults", () => {
  const config = lifecycleConfig(env({ SUPPORT_EMAIL_TO: "Team@Example.com, other@example.com" }));
  assertEquals(config.mode, "off");
  assertEquals(config.from, "Redmic <hello@simplymurmur.com>");
  assertEquals(config.replyTo, "team@example.com");
  assertEquals(config.dailyCap, 50);
  assertEquals(config.adminKey, null);
  assertEquals(missingSettings(config), []);
});

Deno.test("settings: live needs the key, a start and a postal address; test needs its addresses", () => {
  assertEquals(missingSettings(lifecycleConfig(env({ LIFECYCLE_EMAILS: "live" }))),
    ["RESEND_API_KEY", "LIFECYCLE_START", "LIFECYCLE_POSTAL_ADDRESS"]);
  assertEquals(missingSettings(lifecycleConfig(env({ LIFECYCLE_EMAILS: "test", RESEND_API_KEY: "re_x" }))),
    ["LIFECYCLE_TEST_TO"]);
  const live = lifecycleConfig(env({
    LIFECYCLE_EMAILS: " Live ", RESEND_API_KEY: "re_x", LIFECYCLE_START: "2026-11-20T00:00:00Z",
    LIFECYCLE_POSTAL_ADDRESS: "PO Box 1\nDubai", LIFECYCLE_DAILY_CAP: "500", LIFECYCLE_FOUNDER: "Anton",
  }));
  assertEquals(missingSettings(live), []);
  assertEquals(live.start, Date.UTC(2026, 10, 20));
  assertEquals(live.postalAddress, "PO Box 1 Dubai");
  assertEquals(live.dailyCap, 500);
  assertEquals(live.founder, "Anton");
});

// ---------------------------------------------------------------------------
// The schedule
// ---------------------------------------------------------------------------

Deno.test("schedule: the welcome comes 15 minutes in, once the trial is decided", () => {
  assertEquals(decide("welcome", person({ createdAt: NOW - 10 * MINUTE }), NOW), { action: "wait" });
  assertEquals(decide("welcome", person(), NOW), { action: "send" });
  // Undecided: wait up to six hours, then welcome anyway.
  assertEquals(decide("welcome", person({ trialCheck: null, trialEndsAt: null, createdAt: NOW - 2 * HOUR }), NOW),
    { action: "wait" });
  assertEquals(decide("welcome", person({ trialCheck: null, trialEndsAt: null, createdAt: NOW - 7 * HOUR }), NOW),
    { action: "send" });
  assertEquals(decide("welcome", person({ createdAt: NOW - 4 * DAY }), NOW), { action: "skip", reason: "late" });
});

Deno.test("schedule: nothing else goes out before the welcome is handled", () => {
  assertEquals(decide("founder", person({ createdAt: NOW - 1.5 * DAY }), NOW), { action: "wait" });
  assertEquals(decide("setup", person({ createdAt: NOW - 2 * HOUR }), NOW), { action: "wait" });
});

Deno.test("schedule: the setup nudge only goes to an account that hasn't dictated", () => {
  const welcomed = { handled: handled("welcome"), lastSentAt: NOW - 45 * MINUTE };
  assertEquals(decide("setup", person({ ...welcomed, createdAt: NOW - 40 * MINUTE }), NOW), { action: "wait" });
  assertEquals(decide("setup", person({ ...welcomed, createdAt: NOW - 70 * MINUTE }), NOW), { action: "send" });
  assertEquals(decide("setup", person({ ...welcomed, createdAt: NOW - 70 * MINUTE, dictations: 1 }), NOW),
    { action: "skip", reason: "dictated" });
  assertEquals(decide("setup", person({ ...welcomed, createdAt: NOW - 2 * DAY }), NOW),
    { action: "skip", reason: "late" });
  // The 12-hour gap doesn't hold the setup nudge back.
  assertEquals(planFor(person({ ...welcomed, createdAt: NOW - 70 * MINUTE }), NOW).send, "setup");
});

Deno.test("schedule: the day-numbered emails, each on its day, skipped once late", () => {
  const due: [Kind, number][] = [["founder", 1], ["personalize", 4], ["week_one", 7], ["beyond", 9], ["score", 10]];
  for (const [kind, day] of due) {
    assertEquals(decide(kind, dayOld(day - 0.1, { dictations: 3 }), NOW), { action: "wait" }, `${kind} early`);
    assertEquals(decide(kind, dayOld(day + 0.1, { dictations: 3 }), NOW), { action: "send" }, `${kind} on time`);
    assertEquals(decide(kind, dayOld(day + 3.5, { dictations: 3 }), NOW), { action: "skip", reason: "late" },
      `${kind} late`);
  }
  assertEquals(decide("score", dayOld(10.1), NOW), { action: "skip", reason: "never_dictated" });
});

Deno.test("schedule: the trial reminder goes out in the last day, unless paid or no trial", () => {
  const ending = (left: number, overrides: Partial<Candidate> = {}) =>
    dayOld(13, { trialEndsAt: NOW + left, ...overrides });
  assertEquals(decide("trial_ending", ending(30 * HOUR), NOW), { action: "wait" });
  assertEquals(decide("trial_ending", ending(20 * HOUR), NOW), { action: "send" });
  assertEquals(decide("trial_ending", ending(HOUR), NOW), { action: "skip", reason: "late" });
  assertEquals(decide("trial_ending", ending(20 * HOUR, { paid: true }), NOW), { action: "skip", reason: "paid" });
  assertEquals(decide("trial_ending", dayOld(2, { trialCheck: "device_used", trialEndsAt: null }), NOW),
    { action: "skip", reason: "no_trial" });
  assertEquals(decide("trial_ending", dayOld(2, { trialCheck: null, trialEndsAt: null }), NOW), { action: "wait" });
  assertEquals(decide("trial_ending", dayOld(17, { trialCheck: null, trialEndsAt: null }), NOW),
    { action: "skip", reason: "no_trial" });
  // An invite month moves the end: the reminder follows it.
  assertEquals(decide("trial_ending", dayOld(13, { trialEndsAt: NOW + 31 * DAY }), NOW), { action: "wait" });
});

Deno.test("plan: one email per run, the 12-hour gap, and late ones skipped", () => {
  // Day 4 after a week offline: founder is late, personalize is due.
  const plan = planFor(dayOld(4.2, { handled: handled("welcome", "setup") }), NOW);
  assertEquals(plan.skips, [{ kind: "founder", reason: "late" }]);
  assertEquals(plan.send, "personalize");
  // An email went out 3 hours ago: the next one waits for the gap, the trial reminder doesn't.
  assertEquals(planFor(dayOld(4.2, { handled: handled("welcome", "setup", "founder"), lastSentAt: NOW - 3 * HOUR }),
    NOW).send, null);
  assertEquals(planFor(dayOld(13, { handled: handled("welcome", "setup", "founder", "personalize", "week_one", "beyond",
    "score"), lastSentAt: NOW - 3 * HOUR, trialEndsAt: NOW + 20 * HOUR }), NOW).send, "trial_ending");
});

Deno.test("names: the first word, or none when it doesn't look like a name", () => {
  assertEquals(firstName("Ivy Chen"), "Ivy");
  assertEquals(firstName("  Анна  "), "Анна");
  assertEquals(firstName(null), null);
  assertEquals(firstName("ivy@example.com"), null);
  assertEquals(firstName("user123"), null);
});

// ---------------------------------------------------------------------------
// The emails
// ---------------------------------------------------------------------------

const CONTEXT: EmailContext = { site: "https://simplymurmur.com", token: TOKEN, founder: null, postalAddress: null };

Deno.test("emails: every one renders with its unsubscribe link, in HTML and text, and no gaps", () => {
  for (const variant of ["trial", "basic", "paid", "new"]) {
    for (const kind of KINDS) {
      const rendered = renderEmail(buildEmail(kind, previewFacts(variant, NOW, "Ivy"), CONTEXT), CONTEXT);
      const where = `${kind} (${variant})`;
      assertStringIncludes(rendered.html, `https://simplymurmur.com/unsubscribe/?t=${TOKEN}`, where);
      assertStringIncludes(rendered.text, `Unsubscribe: https://simplymurmur.com/unsubscribe/?t=${TOKEN}`, where);
      assertStringIncludes(rendered.html, "OKNENOR L.L.C-FZ", where);
      for (const gap of ["undefined", "null", "NaN", "[object"]) {
        assertFalse(rendered.html.includes(gap) || rendered.text.includes(gap) || rendered.subject.includes(gap),
          `${where} has "${gap}"`);
      }
    }
  }
});

Deno.test("emails: names are escaped, and the trial and plan lines follow the account", () => {
  const facts = { ...previewFacts("trial", NOW, null), firstName: "<b>Ivy</b>" };
  const html = renderEmail(buildEmail("welcome", facts, CONTEXT), CONTEXT).html;
  assertStringIncludes(html, "Hi &lt;b&gt;Ivy&lt;/b&gt;,");
  assertStringIncludes(html, "7 days of Redmic Pro, on us");
  const basic = renderEmail(buildEmail("welcome", previewFacts("basic", NOW, null), CONTEXT), CONTEXT).text;
  assertStringIncludes(basic, "1,000 words of dictation every week");
  assertStringIncludes(basic, "Hi there,");
  // The trial banner shows only on a trial.
  assertStringIncludes(renderEmail(buildEmail("beyond", previewFacts("trial", NOW, null), CONTEXT), CONTEXT).text,
    "7 days of Pro left");
  assertFalse(renderEmail(buildEmail("beyond", previewFacts("paid", NOW, null), CONTEXT), CONTEXT).text
    .includes("Pro left"));
});

Deno.test("emails: week one shows the stats, or a nudge before the first dictation", () => {
  const stats = renderEmail(buildEmail("week_one", previewFacts("trial", NOW, null), CONTEXT), CONTEXT).text;
  assertStringIncludes(stats, "- 1,840 words dictated");
  assertStringIncludes(stats, "- 5 days with Redmic");
  assertStringIncludes(stats, "- 3 days longest streak");
  assertStringIncludes(stats, `- ${minutesSaved(1840)} min time saved`);
  const nudge = renderEmail(buildEmail("week_one", previewFacts("new", NOW, null), CONTEXT), CONTEXT).text;
  assertStringIncludes(nudge, "You haven’t dictated with Redmic yet.");
  assertEquals(minutesSaved(1840), 33);
});

Deno.test("emails: the founder note is signed by the founder when named, and the address shows", () => {
  const context = { ...CONTEXT, founder: "Anton", postalAddress: "PO Box 1, Dubai" };
  const rendered = renderEmail(buildEmail("founder", previewFacts("trial", NOW, null), context), context);
  assertEquals(rendered.subject, "A note from Anton at Redmic");
  assertStringIncludes(rendered.text, "Anton\nFounder of Redmic");
  assertStringIncludes(rendered.text, "Redmic · OKNENOR L.L.C-FZ · PO Box 1, Dubai");
  const team = renderEmail(buildEmail("founder", previewFacts("trial", NOW, null), CONTEXT), CONTEXT);
  assertStringIncludes(team.text, "The Redmic team");
});

Deno.test("emails: the 1–10 question links each number to the score page", () => {
  const text = renderEmail(buildEmail("score", previewFacts("trial", NOW, null), CONTEXT), CONTEXT).text;
  for (let score = 1; score <= 10; score++) {
    assertStringIncludes(text, `${score}: https://simplymurmur.com/score/?t=${TOKEN}&s=${score}`);
  }
});

Deno.test("outgoing: one-click unsubscribe headers, reply-to and tags", () => {
  const email = outgoingEmail("welcome", "ivy@example.com", previewFacts("trial", NOW, null), TOKEN, LIVE);
  assertEquals(email.to, ["ivy@example.com"]);
  assertEquals(email.reply_to, "help@example.com");
  assertEquals(email.headers["List-Unsubscribe"],
    `<https://ref.supabase.co/functions/v1/email-preferences?t=${TOKEN}&a=unsubscribe>`);
  assertEquals(email.headers["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click");
  assertEquals(email.tags, [{ name: "stream", value: "lifecycle" }, { name: "kind", value: "welcome" }]);
});

Deno.test("resend: an id on success; 401/403 stop the run, 422 is permanent, 429/5xx retry", async () => {
  const answer = (status: number, body: string) => () => Promise.resolve(new Response(body, { status }));
  const email = outgoingEmail("welcome", "ivy@example.com", previewFacts("trial", NOW, null), TOKEN, LIVE);
  let sentKey: string | null = null;
  const ok = await sendThroughResend(email, "re_x", "lifecycle-a-welcome", {
    fetcher: (_url, init) => {
      sentKey = new Headers(init?.headers).get("Idempotency-Key");
      return Promise.resolve(new Response(`{"id":"em_1"}`, { status: 200 }));
    },
  });
  assertEquals(ok, { ok: true, id: "em_1" });
  assertEquals(sentKey, "lifecycle-a-welcome");
  const refused = await sendThroughResend(email, "re_x", null, { fetcher: answer(403, "domain not verified") });
  assert(!refused.ok && refused.config && !refused.permanent);
  const invalid = await sendThroughResend(email, "re_x", null, { fetcher: answer(422, "invalid to") });
  assert(!invalid.ok && invalid.permanent && !invalid.config);
  const busy = await sendThroughResend(email, "re_x", null, { fetcher: answer(429, "slow down") });
  assert(!busy.ok && !busy.permanent && !busy.config);
  const down = await sendThroughResend(email, "re_x", null, { fetcher: () => Promise.reject(new Error("reset")) });
  assert(!down.ok && !down.permanent);
});

// ---------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------

interface Fake {
  deps: LifecycleDeps;
  rows: Map<string, { status: string; detail: string | null }>;
  sent: { email: OutgoingEmail; key: string | null }[];
}

function fake(people: Candidate[], options: {
  config?: Partial<LifecycleConfig>;
  results?: SendResult[];
  sentToday?: number;
  cronSecret?: string;
} = {}): Fake {
  const rows = new Map<string, { status: string; detail: string | null }>();
  const sent: { email: OutgoingEmail; key: string | null }[] = [];
  const results = [...(options.results ?? [])];
  const deps: LifecycleDeps = {
    config: { ...LIVE, ...options.config },
    cronSecretOk: (secret) => Promise.resolve(secret === (options.cronSecret ?? "cron-secret")),
    candidates: () => Promise.resolve(people),
    token: () => Promise.resolve(TOKEN),
    claim: (userId, kind, status, detail) => {
      const key = `${userId}:${kind}`;
      if (rows.has(key)) return Promise.resolve(false);
      rows.set(key, { status, detail });
      return Promise.resolve(true);
    },
    finish: (userId, kind, status, detail) => {
      rows.set(`${userId}:${kind}`, { status, detail });
      return Promise.resolve();
    },
    release: (userId, kind) => {
      rows.delete(`${userId}:${kind}`);
      return Promise.resolve();
    },
    sentSince: () => Promise.resolve(options.sentToday ?? 0),
    send: (email, key) => {
      sent.push({ email, key });
      return Promise.resolve(results.shift() ?? { ok: true, id: `em_${sent.length}` });
    },
    now: () => NOW,
    sleep: () => Promise.resolve(),
  };
  return { deps, rows, sent };
}

const call = (handler: (request: Request) => Promise<Response>, body: unknown, headers: Record<string, string>) =>
  handler(new Request("https://ref.supabase.co/functions/v1/lifecycle-emails", {
    method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body),
  }));
const CRON = { "x-murmur-cron": "cron-secret" };
const ADMIN = { "x-murmur-admin": "admin-key-0123456789abcdef" };

Deno.test("run: refuses calls without Vault's secret or the admin key", async () => {
  const { deps, sent } = fake([person()]);
  const handler = createLifecycleHandler(deps);
  assertEquals((await call(handler, { action: "run" }, {})).status, 401);
  assertEquals((await call(handler, { action: "run" }, { "x-murmur-cron": "guess" })).status, 401);
  assertEquals((await call(handler, { action: "run" }, { "x-murmur-admin": "admin-key-0123456789abcdeX" })).status,
    401);
  assertEquals(sent.length, 0);
});

Deno.test("run: off sends nothing, and live without its settings says what's missing", async () => {
  const off = fake([person()], { config: { mode: "off" } });
  assertEquals(await (await call(createLifecycleHandler(off.deps), { action: "run" }, CRON)).json(),
    { mode: "off", considered: 0, sent: 0, skipped: 0, failed: 0, deferred: 0 });
  const bare = fake([person()], { config: { postalAddress: null } });
  assertEquals(await (await call(createLifecycleHandler(bare.deps), { action: "run" }, CRON)).json(),
    { mode: "live", error: "not_configured", missing: ["LIFECYCLE_POSTAL_ADDRESS"] });
  assertEquals(off.sent.length + bare.sent.length, 0);
});

Deno.test("run: sends what's due once, records skips, and a second run sends nothing more", async () => {
  const late = dayOld(4.2, { userId: "11111111-1111-1111-1111-111111111111", email: "jon@example.com" });
  const { deps, rows, sent } = fake([person(), late]);
  const handler = createLifecycleHandler(deps);
  const report = await (await call(handler, { action: "run" }, CRON)).json();
  assertEquals(report, { mode: "live", considered: 2, sent: 2, skipped: 1, failed: 0, deferred: 0 });
  assertEquals(sent.map((item) => item.email.subject), ["Welcome to Redmic", "Make Redmic write like you"]);
  assertEquals(sent[0].key, `lifecycle-${USER}-welcome`);
  assertEquals(rows.get(`${USER}:welcome`), { status: "sent", detail: "em_1" });
  assertEquals(rows.get("11111111-1111-1111-1111-111111111111:founder"), { status: "skipped", detail: "late" });
  // The candidates are the same objects, so the claims hold them back.
  await call(handler, { action: "run" }, CRON);
  assertEquals(sent.length, 2);
});

Deno.test("run: a refused key stops the run; a busy Resend is tried again; a bad address isn't", async () => {
  const people = ["a", "b", "c"].map((letter, index) =>
    person({ userId: `${letter.repeat(8)}-0000-0000-0000-00000000000${index}`, email: `${letter}@example.com` })
  );
  const busy = fake(people, {
    results: [
      { ok: false, permanent: false, config: false, detail: "429" },
      { ok: false, permanent: true, config: false, detail: "422" },
    ],
  });
  const report = await (await call(createLifecycleHandler(busy.deps), { action: "run" }, CRON)).json();
  assertEquals([report.sent, report.failed], [1, 2]);
  assertFalse(busy.rows.has(`${people[0].userId}:welcome`), "released for the next run");
  assertEquals(busy.rows.get(`${people[1].userId}:welcome`)?.status, "failed");

  const refused = fake(people, { results: [{ ok: false, permanent: false, config: true, detail: "403" }] });
  const stopped = await (await call(createLifecycleHandler(refused.deps), { action: "run" }, CRON)).json();
  assertEquals([stopped.sent, stopped.failed, stopped.deferred], [0, 1, 2]);
  assertEquals(refused.sent.length, 1);
});

Deno.test("run: the daily cap and the per-run limit defer the rest to later runs", async () => {
  const many = Array.from({ length: PER_RUN + 5 }, (_, index) =>
    person({ userId: `${String(index).padStart(8, "0")}-0000-0000-0000-000000000000`, email: `p${index}@example.com` }));
  const capped = fake(many, { sentToday: 48 });
  const report = await (await call(createLifecycleHandler(capped.deps), { action: "run" }, CRON)).json();
  assertEquals([report.sent, report.deferred], [2, PER_RUN + 3]);
  const limited = fake(many, { config: { dailyCap: 1000 } });
  const second = await (await call(createLifecycleHandler(limited.deps), { action: "run" }, CRON)).json();
  assertEquals([second.sent, second.deferred], [PER_RUN, 5]);
});

Deno.test("run: test mode only emails LIFECYCLE_TEST_TO's accounts; a dry run records nothing", async () => {
  const people = [person(), person({ userId: "22222222-2222-2222-2222-222222222222", email: "Tester@Example.com" })];
  const test = fake(people, { config: { mode: "test", start: null, testTo: ["tester@example.com"] } });
  const report = await (await call(createLifecycleHandler(test.deps), { action: "run" }, CRON)).json();
  assertEquals([report.considered, report.sent], [1, 1]);
  assertEquals(test.sent[0].email.to, ["Tester@Example.com"]);

  const dry = fake([person(), dayOld(4.2)]);
  const plan = await (await call(createLifecycleHandler(dry.deps), { action: "run", dryRun: true }, ADMIN)).json();
  assertEquals(plan.decisions, [
    { user: "7c9e6679", kind: "welcome", action: "send" },
    { user: "7c9e6679", kind: "founder", action: "skip", reason: "late" },
    { user: "7c9e6679", kind: "personalize", action: "send" },
  ]);
  assertEquals([dry.rows.size, dry.sent.length], [0, 0]);
  // Only the admin key gets a dry run: cron's call always runs for real.
  assertEquals((await call(createLifecycleHandler(fake([]).deps), { action: "preview", to: "x" }, CRON)).status, 400);
});

Deno.test("preview: every email to an allowed address, marked, with nothing recorded", async () => {
  const { deps, rows, sent } = fake([], { config: { testTo: ["tester@example.com"] } });
  const handler = createLifecycleHandler(deps);
  assertEquals((await call(handler, { action: "preview", to: "stranger@example.com" }, ADMIN)).status, 400);
  const response = await call(handler, { action: "preview", to: "Tester@example.com", name: "Ivy" }, ADMIN);
  assertEquals((await response.json()).results.length, KINDS.length);
  assertEquals(sent.length, KINDS.length);
  assert(sent.every((item) => item.email.subject.startsWith("[Preview] ") && item.key === null));
  assertStringIncludes(sent[0].email.text, "Hi Ivy,");
  assertEquals(rows.size, 0);
  // The reply-to address may get previews too.
  assertEquals((await call(handler, { action: "preview", to: "help@example.com", kinds: ["score"] }, ADMIN)).status,
    200);
});

// ---------------------------------------------------------------------------
// email-preferences
// ---------------------------------------------------------------------------

function preferences(overrides: Partial<PreferencesDeps> = {}) {
  const state = { subscribed: true, score: null as number | null, comment: null as string | null };
  const handler = createPreferencesHandler({
    site: "https://simplymurmur.com",
    findUser: (token) => Promise.resolve(token === TOKEN ? USER : null),
    setSubscribed: (_user, subscribed) => {
      state.subscribed = subscribed;
      return Promise.resolve();
    },
    saveScore: (_user, score, comment) => {
      state.score = score;
      if (comment !== null) state.comment = comment;
      return Promise.resolve();
    },
    withinLimit: () => Promise.resolve(true),
    ...overrides,
  });
  return { handler, state };
}

const BASE = "https://ref.supabase.co/functions/v1/email-preferences";
const post = (body: unknown, query = "") =>
  new Request(`${BASE}${query}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

Deno.test("preferences: opening the link asks first; the one-click POST unsubscribes", async () => {
  const { handler, state } = preferences();
  const opened = await handler(new Request(`${BASE}?t=${TOKEN}&a=unsubscribe`));
  assertEquals(opened.status, 302);
  assertEquals(opened.headers.get("Location"), `https://simplymurmur.com/unsubscribe/?t=${TOKEN}`);
  assert(state.subscribed, "a GET changes nothing");
  const oneClick = await handler(new Request(`${BASE}?t=${TOKEN}&a=unsubscribe`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: "List-Unsubscribe=One-Click",
  }));
  assertEquals(oneClick.status, 200);
  assertFalse(state.subscribed);
});

Deno.test("preferences: the pages unsubscribe, subscribe again and save a score with its reason", async () => {
  const { handler, state } = preferences();
  assertEquals(await (await handler(post({ token: TOKEN, action: "unsubscribe" }))).json(),
    { done: true, subscribed: false });
  assertEquals(await (await handler(post({ token: TOKEN.toUpperCase(), action: "resubscribe" }))).json(),
    { done: true, subscribed: true });
  assertEquals((await handler(post({ token: TOKEN, action: "score", score: 9 }))).status, 200);
  assertEquals((await handler(post({ token: TOKEN, action: "score", score: 9, comment: "  Fast.  " }))).status, 200);
  assertEquals((await handler(post({ token: TOKEN, action: "score", score: 8 }))).status, 200);
  assertEquals([state.score, state.comment], [8, "Fast."]);
  for (const score of [0, 11, 7.5, "9"]) {
    assertEquals((await handler(post({ token: TOKEN, action: "score", score }))).status, 400, String(score));
  }
});

Deno.test("preferences: an unknown token is 404, a bad one 400, and too many requests 429", async () => {
  const { handler } = preferences();
  assertEquals((await handler(post({ token: "00000000-0000-0000-0000-000000000000", action: "unsubscribe" }))).status,
    404);
  assertEquals((await handler(post({ token: "nope", action: "unsubscribe" }))).status, 400);
  assertEquals((await handler(post({ token: TOKEN, action: "delete" }))).status, 400);
  const limited = preferences({ withinLimit: () => Promise.resolve(false) });
  assertEquals((await limited.handler(post({ token: TOKEN, action: "unsubscribe" }))).status, 429);
});
