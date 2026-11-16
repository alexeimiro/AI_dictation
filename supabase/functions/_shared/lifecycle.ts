// Lifecycle emails: who gets which email and when, and the run that sends them through Resend.
// Every 15 minutes pg_cron calls the lifecycle-emails function (migration
// 20261116000000_lifecycle_emails); each run looks at the accounts made in the last 60 days and
// sends each one at most one email. The emails' words are in _shared/lifecycle_emails.ts.
//
// The schedule counts from the moment the account was made (auth.users.created_at), as Wispr
// Flow's does:
//   welcome       15 min (waits up to 6 h for the trial to be decided)
//   setup         1 h, only if the account hasn't dictated yet
//   founder       day 1
//   personalize   day 4
//   week_one      day 7 (the stats, or a nudge if it hasn't dictated)
//   beyond        day 9
//   score         day 10, only if it has dictated
//   trial_ending  24 h before the Pro trial ends, unless it has paid
// An email whose moment has long passed (cron down, account unsubscribed and back) is skipped,
// never sent late; no two go out within 12 hours, except setup after welcome and trial_ending.
//
// Env (Edge Function secrets):
//   LIFECYCLE_EMAILS          off (default) · test (only LIFECYCLE_TEST_TO's accounts) · live
//   LIFECYCLE_START           ISO time; live mode emails only accounts made after it (required)
//   LIFECYCLE_POSTAL_ADDRESS  the company's postal address for the footer (required for live)
//   LIFECYCLE_TEST_TO         comma-separated addresses: test mode's accounts, and where previews may go
//   LIFECYCLE_FOUNDER         the name that signs the day-1 note; without it the team signs it
//   LIFECYCLE_FROM            default "Murmur <hello@simplymurmur.com>"
//   LIFECYCLE_REPLY_TO        default SUPPORT_EMAIL_TO's first address
//   LIFECYCLE_DAILY_CAP       emails in any 24 hours, default 50 (Resend's free plan: 100 a day,
//                             shared with the sign-in codes)
//   LIFECYCLE_ADMIN_KEY       lets scripts ask for a dry run or a preview (x-murmur-admin)
//   RESEND_API_KEY            Resend's sending key, as for support emails
import { corsHeaders, json } from "./http.ts";
import {
  buildEmail,
  type EmailContext,
  type EmailFacts,
  KINDS,
  type Kind,
  type PlanState,
  renderEmail,
} from "./lifecycle_emails.ts";

const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;

export type Mode = "off" | "test" | "live";

export interface LifecycleConfig {
  mode: Mode;
  /** Live mode emails only accounts made at or after this time (ms). */
  start: number | null;
  testTo: string[];
  apiKey: string | null;
  from: string;
  replyTo: string | null;
  founder: string | null;
  postalAddress: string | null;
  dailyCap: number;
  adminKey: string | null;
  /** "https://simplymurmur.com" */
  site: string;
  /** ".../functions/v1", for the one-click unsubscribe link. */
  functionsUrl: string;
}

const addresses = (value: string | undefined) =>
  (value ?? "").split(",").map((address) => address.trim().toLowerCase())
    .filter((address) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address));

const optional = (value: string | undefined, max: number) => {
  // deno-lint-ignore no-control-regex
  const clean = (value ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  return clean && clean.length <= max ? clean : null;
};

export function lifecycleConfig(env: { get(name: string): string | undefined } = Deno.env): LifecycleConfig {
  const mode = (env.get("LIFECYCLE_EMAILS") ?? "").trim().toLowerCase();
  const start = Date.parse(env.get("LIFECYCLE_START") ?? "");
  const cap = Number(env.get("LIFECYCLE_DAILY_CAP")?.trim() || NaN);
  const adminKey = env.get("LIFECYCLE_ADMIN_KEY")?.trim() ?? "";
  return {
    mode: mode === "live" || mode === "test" ? mode : "off",
    start: Number.isFinite(start) ? start : null,
    testTo: addresses(env.get("LIFECYCLE_TEST_TO")),
    apiKey: env.get("RESEND_API_KEY")?.trim() || null,
    from: optional(env.get("LIFECYCLE_FROM"), 120) ?? "Murmur <hello@simplymurmur.com>",
    replyTo: addresses(env.get("LIFECYCLE_REPLY_TO"))[0] ?? addresses(env.get("SUPPORT_EMAIL_TO"))[0] ?? null,
    founder: optional(env.get("LIFECYCLE_FOUNDER"), 60),
    postalAddress: optional(env.get("LIFECYCLE_POSTAL_ADDRESS"), 200),
    dailyCap: Number.isInteger(cap) && cap >= 0 ? cap : 50,
    adminKey: adminKey.length >= 24 ? adminKey : null,
    site: "https://simplymurmur.com",
    functionsUrl: `${(env.get("SUPABASE_URL") ?? "").replace(/\/+$/, "")}/functions/v1`,
  };
}

/** The settings the mode needs that aren't there; empty when it can run. */
export function missingSettings(config: LifecycleConfig): string[] {
  const missing: string[] = [];
  if (config.mode === "off") return missing;
  if (!config.apiKey) missing.push("RESEND_API_KEY");
  if (config.mode === "live") {
    if (config.start === null) missing.push("LIFECYCLE_START");
    if (!config.postalAddress) missing.push("LIFECYCLE_POSTAL_ADDRESS");
  } else if (config.testTo.length === 0) {
    missing.push("LIFECYCLE_TEST_TO");
  }
  return missing;
}

// ---------------------------------------------------------------------------
// The schedule
// ---------------------------------------------------------------------------

/** One account, as lifecycle_candidates gives it. */
export interface Candidate {
  userId: string;
  email: string;
  fullName: string | null;
  createdAt: number;
  /** A Murmur Pro subscription (or a grant) is active. */
  paid: boolean;
  /** How the trial was decided: granted, device_used, unchecked, legacy; null until it is. */
  trialCheck: string | null;
  trialEndsAt: number | null;
  token: string | null;
  dictations: number;
  words: number;
  daysUsed: number;
  longestStreak: number;
  /** Every email already handled: sent, skipped, failed or being sent. */
  handled: Set<string>;
  lastSentAt: number | null;
}

export type Decision =
  | { action: "send" }
  | { action: "skip"; reason: string }
  | { action: "wait" };

const WAIT: Decision = { action: "wait" };
const SEND: Decision = { action: "send" };
const skip = (reason: string): Decision => ({ action: "skip", reason });

/** The order emails are looked at in: the time-critical ones first. */
const ORDER: readonly Kind[] = ["welcome", "setup", "trial_ending", "founder", "personalize", "week_one", "beyond", "score"];

/** Day-numbered emails: when they're due after the account was made, and how late they may go. */
const DAYS: Partial<Record<Kind, { due: number; late: number }>> = {
  founder: { due: 1 * DAY_MS, late: 2 * DAY_MS },
  personalize: { due: 4 * DAY_MS, late: 2 * DAY_MS },
  week_one: { due: 7 * DAY_MS, late: 2 * DAY_MS },
  beyond: { due: 9 * DAY_MS, late: 2 * DAY_MS },
  score: { due: 10 * DAY_MS, late: 3 * DAY_MS },
};

/** The gap kept after any email, except before these. */
const GAP_MS = 12 * HOUR_MS;
const NO_GAP: ReadonlySet<Kind> = new Set(["setup", "trial_ending"]);

export function planState(person: Candidate, now: number): PlanState {
  if (person.paid) return { kind: "paid" };
  if (person.trialEndsAt !== null && person.trialEndsAt > now) return { kind: "trial", endsAt: person.trialEndsAt };
  return { kind: "basic" };
}

/** What to do now about one email for one account. */
export function decide(kind: Kind, person: Candidate, now: number): Decision {
  const age = now - person.createdAt;
  if (kind !== "welcome" && !person.handled.has("welcome")) return WAIT;
  switch (kind) {
    case "welcome":
      if (age < 15 * MINUTE_MS) return WAIT;
      if (age > 3 * DAY_MS) return skip("late");
      // The app decides the trial right after sign-up; give it a few hours, so the welcome says
      // the right thing about it.
      if (person.trialCheck === null && !person.paid && age < 6 * HOUR_MS) return WAIT;
      return SEND;
    case "setup":
      if (person.dictations > 0) return skip("dictated");
      if (age < HOUR_MS) return WAIT;
      if (age > DAY_MS) return skip("late");
      return SEND;
    case "trial_ending": {
      if (person.paid) return skip("paid");
      const ends = person.trialEndsAt;
      if (ends === null) {
        // device_used and friends never get a trial; an undecided one has a while to be decided.
        return person.trialCheck !== null || age > 16 * DAY_MS ? skip("no_trial") : WAIT;
      }
      if (ends - now > DAY_MS) return WAIT;
      // Under two hours left, "ends tomorrow" would be wrong.
      if (ends - now < 2 * HOUR_MS) return skip("late");
      return SEND;
    }
    default: {
      const timing = DAYS[kind];
      if (!timing) return skip("unknown");
      if (age < timing.due) return WAIT;
      if (age > timing.due + timing.late) return skip("late");
      if (kind === "score" && person.dictations === 0) return skip("never_dictated");
      return SEND;
    }
  }
}

export interface Plan {
  skips: { kind: Kind; reason: string }[];
  send: Kind | null;
}

/** The emails to record as skipped now, and the one email to send now, if any. */
export function planFor(person: Candidate, now: number): Plan {
  const plan: Plan = { skips: [], send: null };
  const gapOpen = person.lastSentAt === null || now - person.lastSentAt >= GAP_MS;
  for (const kind of ORDER) {
    if (person.handled.has(kind)) continue;
    const decision = decide(kind, person, now);
    if (decision.action === "skip") plan.skips.push({ kind, reason: decision.reason });
    else if (decision.action === "send" && plan.send === null && (gapOpen || NO_GAP.has(kind))) plan.send = kind;
  }
  return plan;
}

/** The first word of the account's name, if it looks like a name. */
export function firstName(fullName: string | null): string | null {
  // deno-lint-ignore no-control-regex
  const word = (fullName ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().split(/\s+/)[0] ?? "";
  if (!word || word.length > 40 || /[@<>/\\:\d]/.test(word)) return null;
  return word;
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

export interface OutgoingEmail {
  from: string;
  to: string[];
  reply_to?: string;
  subject: string;
  html: string;
  text: string;
  headers: Record<string, string>;
  tags: { name: string; value: string }[];
}

export type SendResult =
  | { ok: true; id: string }
  /** `permanent`: this address won't take it (don't retry). `config`: our key or domain is refused. */
  | { ok: false; permanent: boolean; config: boolean; detail: string };

export function outgoingEmail(kind: Kind, to: string, facts: EmailFacts, token: string,
  config: LifecycleConfig, subjectPrefix = ""): OutgoingEmail {
  const context: EmailContext = {
    site: config.site,
    token,
    founder: config.founder,
    postalAddress: config.postalAddress,
  };
  const rendered = renderEmail(buildEmail(kind, facts, context), context);
  return {
    from: config.from,
    to: [to],
    ...(config.replyTo ? { reply_to: config.replyTo } : {}),
    subject: `${subjectPrefix}${rendered.subject}`,
    html: rendered.html,
    text: rendered.text,
    headers: {
      // RFC 8058 one-click unsubscribe: mail apps POST to it; email-preferences handles it.
      "List-Unsubscribe": `<${config.functionsUrl}/email-preferences?t=${encodeURIComponent(token)}&a=unsubscribe>`,
      "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
    },
    tags: [{ name: "stream", value: "lifecycle" }, { name: "kind", value: kind }],
  };
}

/** Sends through Resend's API. Never throws. */
export async function sendThroughResend(email: OutgoingEmail, apiKey: string, idempotencyKey: string | null,
  options: { fetcher?: typeof fetch; signal?: AbortSignal } = {}): Promise<SendResult> {
  try {
    const response = await (options.fetcher ?? fetch)("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
      },
      body: JSON.stringify(email),
      signal: options.signal,
    });
    const body = await response.text();
    if (response.ok) {
      const id = (JSON.parse(body) as { id?: unknown }).id;
      return { ok: true, id: typeof id === "string" ? id : "" };
    }
    const status = response.status;
    return {
      ok: false,
      config: status === 401 || status === 403,
      permanent: status >= 400 && status < 500 && status !== 401 && status !== 403 && status !== 409 && status !== 429,
      detail: `${status} ${body.slice(0, 160)}`,
    };
  } catch (error) {
    return { ok: false, permanent: false, config: false, detail: String(error).slice(0, 160) };
  }
}

// ---------------------------------------------------------------------------
// The function
// ---------------------------------------------------------------------------

export interface LifecycleDeps {
  config: LifecycleConfig;
  /** Whether the cron call's secret is Vault's (lifecycle_cron_ok). */
  cronSecretOk(secret: string): Promise<boolean>;
  candidates(since: number): Promise<Candidate[]>;
  /** The account's link token, made if it has none yet. */
  token(userId: string): Promise<string>;
  /** Records the email for the account; false if it was already there. */
  claim(userId: string, kind: Kind, status: "sending" | "skipped", detail: string | null): Promise<boolean>;
  finish(userId: string, kind: Kind, status: "sent" | "failed", detail: string): Promise<void>;
  /** Forgets a claim whose email didn't go out, so a later run tries again. */
  release(userId: string, kind: Kind): Promise<void>;
  /** Emails sent since `since` (ms). */
  sentSince(since: number): Promise<number>;
  send(email: OutgoingEmail, idempotencyKey: string | null): Promise<SendResult>;
  now?(): number;
  sleep?(ms: number): Promise<void>;
}

/** The most emails one run sends. */
export const PER_RUN = 40;
/** Between two sends: Resend takes a few requests a second. */
const SEND_PAUSE_MS = 600;

function safeEqual(a: string, b: string): boolean {
  const left = new TextEncoder().encode(a);
  const right = new TextEncoder().encode(b);
  let difference = left.length ^ right.length;
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

function log(event: string, fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ event, ...fields }));
}

export function factsFor(person: Candidate, now: number): EmailFacts {
  return {
    firstName: firstName(person.fullName),
    plan: planState(person, now),
    dictations: person.dictations,
    words: person.words,
    daysUsed: person.daysUsed,
    longestStreak: person.longestStreak,
    now,
  };
}

interface RunReport {
  mode: Mode;
  considered: number;
  sent: number;
  skipped: number;
  failed: number;
  /** Due, but over the run's or the day's limit: the next run sends them. */
  deferred: number;
  decisions?: { user: string; kind: Kind; action: "send" | "skip"; reason?: string }[];
}

/** The day each email goes out on, for previews' trial days. */
const PREVIEW_DAY: Record<Kind, number> = {
  welcome: 0, setup: 0, founder: 1, personalize: 4, week_one: 7, beyond: 9, score: 10, trial_ending: 13,
};

/** The sample account a preview is written for, `day` days into its 14-day trial. */
export function previewFacts(variant: string, now: number, name: string | null, day = 7): EmailFacts {
  const dictated = variant !== "new";
  return {
    firstName: firstName(name),
    plan: variant === "paid"
      ? { kind: "paid" }
      : variant === "basic"
      ? { kind: "basic" }
      : { kind: "trial", endsAt: now + (14 - day) * DAY_MS - HOUR_MS },
    dictations: dictated ? 23 : 0,
    words: dictated ? 1840 : 0,
    daysUsed: dictated ? 5 : 0,
    longestStreak: dictated ? 3 : 0,
    now,
  };
}

// POST { action: "run", dryRun? }            cron (x-murmur-cron) or admin (x-murmur-admin)
// POST { action: "preview", to, kinds?, variant?, name? }   admin only: every email, with sample
//   facts, to an address in LIFECYCLE_TEST_TO or the reply-to; nothing is recorded.
//   200 report · 400 bad_request · 401 unauthorized
export function createLifecycleHandler(deps: LifecycleDeps): (request: Request) => Promise<Response> {
  const now = () => (deps.now ?? Date.now)();
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const config = deps.config;

  async function run(dryRun: boolean): Promise<RunReport | { mode: Mode; error: string; missing: string[] }> {
    const report: RunReport = { mode: config.mode, considered: 0, sent: 0, skipped: 0, failed: 0, deferred: 0 };
    if (config.mode === "off") return report;
    const missing = missingSettings(config);
    if (missing.length > 0) {
      log("lifecycle_not_configured", { mode: config.mode, missing });
      return { mode: config.mode, error: "not_configured", missing };
    }
    const started = now();
    const since = config.mode === "live" ? config.start! : (config.start ?? started - 60 * DAY_MS);
    let people = await deps.candidates(since);
    if (config.mode === "test") people = people.filter((person) => config.testTo.includes(person.email.toLowerCase()));
    report.considered = people.length;
    if (dryRun) report.decisions = [];
    let budget = Math.max(0, Math.min(PER_RUN, config.dailyCap - await deps.sentSince(started - DAY_MS)));
    let stopped = false;

    for (const person of people) {
      const user = person.userId.slice(0, 8);
      try {
        const plan = planFor(person, started);
        for (const skipped of plan.skips) {
          report.skipped++;
          if (dryRun) report.decisions!.push({ user, kind: skipped.kind, action: "skip", reason: skipped.reason });
          else await deps.claim(person.userId, skipped.kind, "skipped", skipped.reason);
        }
        const kind = plan.send;
        if (!kind) continue;
        if (stopped || budget <= 0) {
          report.deferred++;
          continue;
        }
        if (dryRun) {
          report.decisions!.push({ user, kind, action: "send" });
          continue;
        }
        if (!await deps.claim(person.userId, kind, "sending", null)) continue;
        budget--;
        const token = person.token ?? await deps.token(person.userId);
        const email = outgoingEmail(kind, person.email, factsFor(person, started), token, config);
        if (report.sent + report.failed > 0) await sleep(SEND_PAUSE_MS);
        const result = await deps.send(email, `lifecycle-${person.userId}-${kind}`);
        if (result.ok) {
          report.sent++;
          await deps.finish(person.userId, kind, "sent", result.id);
          log("lifecycle_email", { user, kind, sent: true });
        } else {
          report.failed++;
          if (result.permanent) await deps.finish(person.userId, kind, "failed", result.detail);
          else await deps.release(person.userId, kind);
          log("lifecycle_email", { user, kind, sent: false, permanent: result.permanent, detail: result.detail });
          // Our key or domain was refused: every other email would be too.
          if (result.config) stopped = true;
        }
      } catch (error) {
        report.failed++;
        log("lifecycle_email_error", { user, detail: String(error).slice(0, 200) });
      }
    }
    log("lifecycle_run", { ...report, decisions: undefined, dryRun, ms: now() - started });
    return report;
  }

  async function preview(body: Record<string, unknown>): Promise<Response> {
    const to = typeof body.to === "string" ? body.to.trim().toLowerCase() : "";
    const allowed = new Set([...config.testTo, ...(config.replyTo ? [config.replyTo] : [])]);
    if (!allowed.has(to)) return json({ error: "bad_request", detail: "to must be in LIFECYCLE_TEST_TO" }, 400);
    if (!config.apiKey) return json({ error: "not_configured", missing: ["RESEND_API_KEY"] }, 400);
    const kinds = Array.isArray(body.kinds)
      ? KINDS.filter((kind) => (body.kinds as unknown[]).includes(kind))
      : [...KINDS];
    const variant = typeof body.variant === "string" ? body.variant : "trial";
    const name = typeof body.name === "string" ? body.name : null;
    const at = now();
    const results: { kind: Kind; sent: boolean; detail?: string }[] = [];
    for (const kind of kinds) {
      if (results.length > 0) await sleep(SEND_PAUSE_MS);
      const email = outgoingEmail(kind, to, previewFacts(variant, at, name, PREVIEW_DAY[kind]),
        "00000000-0000-0000-0000-000000000000",
        config, "[Preview] ");
      const result = await deps.send(email, null);
      results.push(result.ok ? { kind, sent: true } : { kind, sent: false, detail: result.detail });
    }
    log("lifecycle_preview", { kinds: kinds.length, sent: results.filter((result) => result.sent).length, variant });
    return json({ results });
  }

  return async (request) => {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const adminHeader = request.headers.get("x-murmur-admin") ?? "";
    const cronHeader = request.headers.get("x-murmur-cron") ?? "";
    const admin = config.adminKey !== null && adminHeader !== "" && safeEqual(adminHeader, config.adminKey);
    const cron = !admin && cronHeader !== "" && await deps.cronSecretOk(cronHeader).catch(() => false);
    if (!admin && !cron) return json({ error: "unauthorized" }, 401);
    const body = await request.json().catch(() => null) as Record<string, unknown> | null;
    if (!body || typeof body !== "object") return json({ error: "bad_request" }, 400);
    if (body.action === "run") {
      try {
        return json(await run(admin && body.dryRun === true));
      } catch (error) {
        log("lifecycle_run_failed", { detail: String(error).slice(0, 200) });
        return json({ error: "unavailable" }, 503);
      }
    }
    if (body.action === "preview" && admin) return await preview(body);
    return json({ error: "bad_request" }, 400);
  };
}
