// Support messages from the app (Report an issue, Leave feedback): saved to issue_reports as the
// app used to save them itself, then emailed to the support inbox through Resend, so each one
// reaches a person. The email goes out after the reply and never decides it: a message is saved
// either way, and a message that wasn't emailed is still in the table.
// Only signed-in accounts' messages are emailed, and at most SUPPORT_EMAIL_DAILY_LIMIT (20) in any
// 24 hours: Resend's free plan sends 100 emails a day, and the sign-in codes need them. A guest
// account costs nothing to make, so a guest's message is only saved.
// Env: RESEND_API_KEY, SUPPORT_EMAIL_TO (one address, or several separated by commas),
// SUPPORT_EMAIL_FROM (default "Murmur <no-reply@simplymurmur.com>") and SUPPORT_EMAIL_DAILY_LIMIT
// (0 emails none). Without the key or an address nothing is emailed.
import { background, type Caller, corsHeaders, json } from "./http.ts";

export interface MailConfig {
  apiKey: string;
  to: string[];
  from: string;
  /** The most messages emailed in any 24 hours. */
  dailyLimit: number;
}

/** Support emails in any 24 hours when SUPPORT_EMAIL_DAILY_LIMIT isn't a whole number. */
export const DEFAULT_DAILY_LIMIT = 20;

export function mailConfig(env: { get(name: string): string | undefined } = Deno.env): MailConfig | null {
  const apiKey = env.get("RESEND_API_KEY");
  const to = (env.get("SUPPORT_EMAIL_TO") ?? "").split(",").map((address) => address.trim())
    .filter((address) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address));
  if (!apiKey || to.length === 0) return null;
  const limit = Number(env.get("SUPPORT_EMAIL_DAILY_LIMIT")?.trim() || NaN);
  return {
    apiKey,
    to,
    from: env.get("SUPPORT_EMAIL_FROM") || "Murmur <no-reply@simplymurmur.com>",
    dailyLimit: Number.isInteger(limit) && limit >= 0 ? limit : DEFAULT_DAILY_LIMIT,
  };
}

/**
 * The key each saved message's diagnostics get from the server, over anything the app sent under
 * it: "signed_in" or "guest", for the account that sent it. The daily limit counts "signed_in".
 */
export const ACCOUNT_KEY = "account";
export type AccountKind = "signed_in" | "guest";

export interface SupportMessage {
  message: string;
  /** The app's short facts: app version, iOS, device, locale, kind and topic. */
  diagnostics: Record<string, string>;
}

/** The request's message and diagnostics, trimmed to what issue_reports takes; null when unusable. */
export function supportMessage(body: unknown): SupportMessage | null {
  const value = body as { message?: unknown; diagnostics?: unknown } | null;
  if (typeof value?.message !== "string") return null;
  const message = value.message.trim();
  if (message.length === 0 || message.length > 5000) return null;
  const diagnostics: Record<string, string> = {};
  if (value.diagnostics && typeof value.diagnostics === "object" && !Array.isArray(value.diagnostics)) {
    for (const [key, item] of Object.entries(value.diagnostics as Record<string, unknown>).slice(0, 20)) {
      if (/^[a-z][A-Za-z0-9_]{0,31}$/.test(key) && typeof item === "string") diagnostics[key] = item.trim().slice(0, 200);
    }
  }
  return { message, diagnostics };
}

export interface SupportEmail {
  from: string;
  to: string[];
  reply_to?: string;
  subject: string;
  text: string;
}

/** One line, no control characters: what may go into a header. */
const oneLine = (text: string, max: number) => {
  const line = text.split(/\r?\n/).find((part) => part.trim()) ?? "";
  // deno-lint-ignore no-control-regex
  const clean = line.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
};

export function supportEmail(message: SupportMessage, account: { id: string; email: string | null },
  config: MailConfig, sentAt: number): SupportEmail {
  const facts = message.diagnostics;
  const kind = facts.kind === "feedback" ? "Feedback" : "Issue";
  const topic = facts.topic ? ` (${oneLine(facts.topic, 40)})` : "";
  const lines = [
    message.message,
    "",
    "—",
    `From: ${account.email ?? "an account with no email address"} · account ${account.id}`,
    `App: ${facts.app ?? "?"} · ${facts.os ?? "?"} · ${facts.device ?? "?"} · ${facts.locale ?? "?"}`,
    `Sent: ${new Date(sentAt).toISOString().replace("T", " ").slice(0, 16)} UTC`,
  ];
  if (account.email) lines.push("", "Reply to this email to answer them.");
  return {
    from: config.from,
    to: config.to,
    ...(account.email ? { reply_to: account.email } : {}),
    subject: `Murmur ${kind.toLowerCase()}${topic}: ${oneLine(message.message, 60)}`,
    text: lines.join("\n"),
  };
}

/** Sends through Resend's API. Never throws: false when it wasn't sent. */
export async function sendWithResend(email: SupportEmail, apiKey: string,
  options: { fetcher?: typeof fetch; signal?: AbortSignal } = {}): Promise<boolean> {
  try {
    const response = await (options.fetcher ?? fetch)("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(email),
      signal: options.signal,
    });
    if (!response.ok) {
      console.error(JSON.stringify({ event: "support_email_refused", status: response.status,
        detail: (await response.text()).slice(0, 200) }));
    }
    return response.ok;
  } catch (error) {
    console.error(JSON.stringify({ event: "support_email_failed", detail: String(error).slice(0, 200) }));
    return false;
  }
}

export interface SupportDeps {
  authenticate(request: Request): Promise<Caller | null>;
  /** False once the account has sent too many messages lately. */
  withinLimit(userId: string): Promise<boolean>;
  /** Saves the message with its diagnostics as given, `ACCOUNT_KEY` included. */
  save(userId: string, message: SupportMessage): Promise<void>;
  /** How many messages signed-in accounts have had saved since `since` (an ISO time). */
  countSignedIn(since: string): Promise<number>;
  /** The account's email, or null when it has none. */
  accountEmail(userId: string): Promise<string | null>;
  /** Null without Resend's key or an address: messages are only saved. */
  mail: { config: MailConfig; send(email: SupportEmail): Promise<boolean> } | null;
  later?(task: Promise<unknown>): void;
  now?(): number;
}

const DAY_MS = 24 * 60 * 60 * 1000;

function logMessage(fields: Record<string, unknown>): void {
  console.log(JSON.stringify({ event: "support_message", ...fields }));
}

// POST { message, diagnostics } →
//   200 { saved: true } · 400 bad_request · 401 unauthorized · 429 rate_limited · 503 unavailable
export function createSupportHandler(deps: SupportDeps): (request: Request) => Promise<Response> {
  /**
   * Emails a signed-in account's saved message, unless the last 24 hours' messages from signed-in
   * accounts, this one among them, are over the limit, or can't be counted.
   */
  async function email(caller: Caller, message: SupportMessage, mail: NonNullable<SupportDeps["mail"]>,
    sentAt: number): Promise<void> {
    const recent = await deps.countSignedIn(new Date(sentAt - DAY_MS).toISOString()).catch((error) => {
      console.error("support message count failed", error);
      return null;
    });
    if (recent === null) return logMessage({ emailed: false, reason: "count_failed" });
    if (recent > mail.config.dailyLimit) return logMessage({ emailed: false, reason: "daily_limit" });
    const address = await deps.accountEmail(caller.userId).catch(() => null);
    const sent = await mail.send(supportEmail(message, { id: caller.userId, email: address }, mail.config, sentAt));
    logMessage({ emailed: sent });
  }

  return async (request) => {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const caller = await deps.authenticate(request);
    if (!caller) return json({ error: "unauthorized" }, 401);
    const message = supportMessage(await request.json().catch(() => null));
    if (!message) return json({ error: "bad_request" }, 400);
    if (!await deps.withinLimit(caller.userId)) return json({ error: "rate_limited" }, 429);
    const account: AccountKind = caller.isAnonymous ? "guest" : "signed_in";
    try {
      await deps.save(caller.userId, { ...message, diagnostics: { ...message.diagnostics, [ACCOUNT_KEY]: account } });
    } catch (error) {
      console.error("support message save failed", error);
      return json({ error: "unavailable" }, 503);
    }
    const sentAt = (deps.now ?? Date.now)();
    const mail = deps.mail;
    if (!mail) logMessage({ emailed: false, reason: "no_mail_config" });
    else if (caller.isAnonymous) logMessage({ emailed: false, reason: "guest" });
    else (deps.later ?? background)(email(caller, message, mail, sentAt));
    return json({ saved: true });
  };
}
