#!/usr/bin/env node
// Asks the live lifecycle-emails function for a dry run or a preview, with the admin key kept in
// the git-ignored scripts/out/lifecycle_admin.env (the same value is the LIFECYCLE_ADMIN_KEY
// secret). See supabase/functions/_shared/lifecycle.ts for the settings.
//
// Usage:
//   node scripts/lifecycle_emails.mjs dry-run
//       What the next run would send or skip (user ID prefixes only); nothing is sent.
//   node scripts/lifecycle_emails.mjs preview <address> [trial|basic|paid|new] [name] [kind,kind,…]
//       Every email, marked [Preview], to <address>, which must be in LIFECYCLE_TEST_TO or be
//       the reply-to address (SUPPORT_EMAIL_TO's first).
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const url = "https://aljjzxfzqbbmyfmardaj.supabase.co/functions/v1/lifecycle-emails";
const envFile = path.join(root, "scripts/out/lifecycle_admin.env");
const key = /LIFECYCLE_ADMIN_KEY=(\S+)/.exec(fs.existsSync(envFile) ? fs.readFileSync(envFile, "utf8") : "")?.[1];
if (!key) {
  console.error(`No LIFECYCLE_ADMIN_KEY in ${path.relative(root, envFile)}`);
  process.exit(1);
}

const [command, ...rest] = process.argv.slice(2);
let body;
if (command === "dry-run") {
  body = { action: "run", dryRun: true };
} else if (command === "preview" && rest[0]) {
  const [to, variant = "trial", name, kinds] = rest;
  body = { action: "preview", to, variant, ...(name ? { name } : {}), ...(kinds ? { kinds: kinds.split(",") } : {}) };
} else {
  console.error("Usage: lifecycle_emails.mjs dry-run | preview <address> [variant] [name] [kinds]");
  process.exit(1);
}

const response = await fetch(url, {
  method: "POST",
  headers: { "Content-Type": "application/json", "x-murmur-admin": key },
  body: JSON.stringify(body),
});
console.log(response.status, JSON.stringify(await response.json().catch(() => null), null, 2));
process.exit(response.ok ? 0 : 1);
