#!/usr/bin/env node
// Murmur's sign-in email on the hosted Supabase project, through the Management API: the subject
// and HTML of Supabase Auth's "Magic link" (existing users) and "Confirm signup" (new users)
// templates, which are both the 6-digit code email in supabase/templates/sign_in_code.html with the
// subject from supabase/config.toml; and, once custom SMTP (Resend) is on, the hourly email limit.
// Never use `supabase config push` for this: it would overwrite every auth setting made in the
// dashboard (URLs, Apple, Google, anonymous sign-ins) with the local config.toml.
//
// Without --apply it only reads: it prints the live email settings and what would change.
// The token is SUPABASE_ACCESS_TOKEN, or else the Supabase CLI's login in the macOS keychain. It is
// never printed.
//
// Usage: node scripts/supabase_auth_email.mjs [--apply]
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const apply = process.argv.includes("--apply");

const refFile = path.join(root, "supabase/.temp/project-ref");
const REF = fs.existsSync(refFile) ? fs.readFileSync(refFile, "utf8").trim() : "aljjzxfzqbbmyfmardaj";
/** Emails an hour, project-wide. Supabase's default once custom SMTP is on; Resend's free plan
 *  sends at most 100 a day, shared with the support emails. */
const EMAIL_LIMIT = 30;
/** The app takes exactly this many digits (EmailSignInView). */
const CODE_LENGTH = 6;
/** The email says "It works for 1 hour". */
const CODE_SECONDS = 3600;
/** The variables Supabase fills in these templates that Murmur may use. */
const VARIABLES = new Set(["Token", "ConfirmationURL", "TokenHash", "SiteURL", "RedirectTo", "Email"]);

const html = fs.readFileSync(path.join(root, "supabase/templates/sign_in_code.html"), "utf8");
const config = fs.readFileSync(path.join(root, "supabase/config.toml"), "utf8");

/** The `subject` of one `[auth.email.template.<name>]` block in config.toml. */
function subject(name) {
  const block = new RegExp(`\\[auth\\.email\\.template\\.${name}\\]\\s*\\nsubject = "([^"\\n]*)"`).exec(config);
  if (!block) throw new Error(`supabase/config.toml has no subject for [auth.email.template.${name}]`);
  return block[1];
}

/** Refuses a template Supabase would fail to render: every email would then fail to send. */
function checkTemplate(label, text, { needsToken }) {
  const actions = [...text.matchAll(/\{\{\s*\.([A-Za-z]+)\s*\}\}/g)];
  for (const [, name] of actions) {
    if (!VARIABLES.has(name)) throw new Error(`${label}: unknown variable {{ .${name} }}`);
  }
  const opens = text.split("{{").length - 1;
  const closes = text.split("}}").length - 1;
  if (opens !== actions.length || closes !== actions.length) {
    throw new Error(`${label}: a {{ … }} that isn't a plain variable, or a stray brace`);
  }
  if (needsToken && !actions.some(([, name]) => name === "Token")) {
    throw new Error(`${label}: no {{ .Token }}, so nobody would get a code`);
  }
}

function accessToken() {
  const fromEnv = process.env.SUPABASE_ACCESS_TOKEN?.trim();
  if (fromEnv) return fromEnv;
  let stored;
  try {
    stored = execFileSync("/usr/bin/security", ["find-generic-password", "-s", "Supabase CLI", "-a", "supabase", "-w"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {
    throw new Error("No SUPABASE_ACCESS_TOKEN, and no Supabase CLI login in the keychain (run `supabase login`).");
  }
  // go-keyring, which the CLI uses, may wrap the value.
  if (stored.startsWith("go-keyring-base64:")) {
    return Buffer.from(stored.slice("go-keyring-base64:".length), "base64").toString("utf8").trim();
  }
  if (stored.startsWith("go-keyring-encoded:")) {
    return Buffer.from(stored.slice("go-keyring-encoded:".length), "hex").toString("utf8").trim();
  }
  return stored;
}

const token = accessToken();
if (!/^sbp_[A-Za-z0-9]+$/.test(token)) throw new Error("The Supabase token doesn't look like a personal access token (sbp_…).");

async function authConfig(method, body) {
  const response = await fetch(`https://api.supabase.com/v1/projects/${REF}/config/auth`, {
    method,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(20000),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} config/auth answered ${response.status}: ${text.slice(0, 300)}`);
  return JSON.parse(text);
}

const subjects = { magic: subject("magic_link"), confirmation: subject("confirmation") };
checkTemplate("sign_in_code.html", html, { needsToken: true });
checkTemplate("magic_link subject", subjects.magic, { needsToken: false });
checkTemplate("confirmation subject", subjects.confirmation, { needsToken: false });

const live = await authConfig("GET");
const customSMTP = Boolean(live.smtp_host);

console.log(`Project ${REF}, live email settings:`);
console.log(customSMTP
  ? `- Mail: ${live.smtp_host}:${live.smtp_port}, user ${live.smtp_user}, from "${live.smtp_sender_name}" <${live.smtp_admin_email}>`
  : "- Mail: Supabase's built-in mailer (it only writes to the project's team members)");
console.log(`- Email sign-in ${live.external_email_enabled ? "on" : "OFF"}; new accounts confirm by email: ${live.mailer_autoconfirm ? "no" : "yes"}`);
console.log(`- Code: ${live.mailer_otp_length} digits, valid ${live.mailer_otp_exp} s; one email per address every ${live.smtp_max_frequency ?? "?"} s`);
console.log(`- Emails an hour, project-wide: ${live.rate_limit_email_sent}`);
console.log(`- Subjects: magic link "${live.mailer_subjects_magic_link ?? ""}", confirm signup "${live.mailer_subjects_confirmation ?? ""}"`);
console.log(`- Templates: magic link ${live.mailer_templates_magic_link_content === html ? "= repo" : "differs from repo"}, confirm signup ${live.mailer_templates_confirmation_content === html ? "= repo" : "differs from repo"}`);

const warnings = [];
if (live.mailer_otp_length !== CODE_LENGTH) warnings.push(`codes have ${live.mailer_otp_length} digits; the app takes exactly ${CODE_LENGTH}`);
if (live.mailer_otp_exp !== CODE_SECONDS) warnings.push(`codes last ${live.mailer_otp_exp} s; the email says 1 hour`);
if (!live.external_email_enabled) warnings.push("email sign-in is off");
for (const warning of warnings) console.log(`WARNING: ${warning}`);

const want = {
  mailer_subjects_magic_link: subjects.magic,
  mailer_subjects_confirmation: subjects.confirmation,
  mailer_templates_magic_link_content: html,
  mailer_templates_confirmation_content: html,
};
if (customSMTP && (live.rate_limit_email_sent ?? 0) < EMAIL_LIMIT) want.rate_limit_email_sent = EMAIL_LIMIT;
const patch = Object.fromEntries(Object.entries(want).filter(([key, value]) => live[key] !== value));
const describe = (key) => (key.includes("templates") ? `${key} (${html.length} characters)` : `${key} = ${JSON.stringify(patch[key])}`);

if (!Object.keys(patch).length) {
  console.log("Nothing to change.");
} else if (!apply) {
  console.log(`Would change (run with --apply):\n${Object.keys(patch).map((key) => `- ${describe(key)}`).join("\n")}`);
} else {
  await authConfig("PATCH", patch);
  const after = await authConfig("GET");
  const wrong = Object.keys(patch).filter((key) => after[key] !== patch[key]);
  if (wrong.length) throw new Error(`Saved, but these read back differently: ${wrong.join(", ")}`);
  console.log(`Changed and read back:\n${Object.keys(patch).map((key) => `- ${describe(key)}`).join("\n")}`);
}
if (!customSMTP) console.log("The email limit can only be raised once custom SMTP is on.");
