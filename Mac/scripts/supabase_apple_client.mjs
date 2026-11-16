#!/usr/bin/env node
// Sign in with Apple on the hosted project, for both apps. Only the Apple provider's fields change,
// through the Management API (never `supabase config push`, which would overwrite the dashboard's
// auth settings).
//
// - The iPhone app signs in natively: Supabase checks the Apple ID token's audience against the
//   provider's client IDs, so its bundle ID is one of them.
// - Murmur for Mac signs in on the web, because Apple gives Developer ID apps (a download) no
//   Sign in with Apple entitlement. Supabase runs Apple's web flow with the FIRST client ID, which
//   must be a Services ID (registered in the developer portal, with this project's callback as its
//   return URL), and with a client secret: a JWT signed with the Sign in with Apple key, which
//   Apple accepts for at most six months. Re-run with --apply before it runs out (the date is
//   printed); the same Apple account lands on the same Murmur account either way.
//
// Usage: node Mac/scripts/supabase_apple_client.mjs           show the current setup
//        node Mac/scripts/supabase_apple_client.mjs --apply   Services ID first, a fresh secret
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REF = "aljjzxfzqbbmyfmardaj";
const SERVICES_ID = "com.antonmironenko.murmur.signin";
const TEAM_ID = "DMC53DDZQV";
const KEY_ID = "B5F8XKUC65";
const KEY_FILE = process.env.APPLE_SIGNIN_KEY
  ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "../..", `AuthKey_${KEY_ID}.p8`);
/// Apple's limit is 15,777,000 seconds (about six months); stay a little under it.
const SECRET_LIFETIME = 180 * 24 * 3600;

function accessToken() {
  const fromEnv = process.env.SUPABASE_ACCESS_TOKEN?.trim();
  if (fromEnv) return fromEnv;
  const stored = execFileSync("/usr/bin/security", ["find-generic-password", "-s", "Supabase CLI", "-a", "supabase", "-w"],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  if (stored.startsWith("go-keyring-base64:")) {
    return Buffer.from(stored.slice("go-keyring-base64:".length), "base64").toString("utf8").trim();
  }
  if (stored.startsWith("go-keyring-encoded:")) {
    return Buffer.from(stored.slice("go-keyring-encoded:".length), "hex").toString("utf8").trim();
  }
  return stored;
}

/// The client secret for Apple's web flow: an ES256 JWT from the Services ID to Apple.
function clientSecret(now = Math.floor(Date.now() / 1000)) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
  const input = `${encode({ alg: "ES256", kid: KEY_ID })}.${encode({
    iss: TEAM_ID, iat: now, exp: now + SECRET_LIFETIME, aud: "https://appleid.apple.com", sub: SERVICES_ID,
  })}`;
  const signature = crypto.sign("sha256", Buffer.from(input), { key: fs.readFileSync(KEY_FILE), dsaEncoding: "ieee-p1363" });
  return { secret: `${input}.${signature.toString("base64url")}`, expires: new Date((now + SECRET_LIFETIME) * 1000) };
}

const token = accessToken();
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

const config = await authConfig("GET");
const current = (config.external_apple_client_id ?? "").split(",").map((id) => id.trim()).filter(Boolean);
console.log(`Apple provider enabled: ${config.external_apple_enabled}`);
console.log(`Client IDs now: ${current.join(", ") || "(none)"}`);
console.log(`Client secret set: ${config.external_apple_secret ? "yes" : "no"}`);

const wanted = [SERVICES_ID, ...current.filter((id) => id !== SERVICES_ID)];
const { secret, expires } = clientSecret();
if (!process.argv.includes("--apply")) {
  console.log(`(dry run) would set the client IDs to ${wanted.join(", ")} and a secret valid until ${expires.toISOString().slice(0, 10)}; run with --apply`);
} else {
  const updated = await authConfig("PATCH", { external_apple_client_id: wanted.join(","), external_apple_secret: secret });
  console.log(`✔ Client IDs now: ${updated.external_apple_client_id}`);
  console.log(`✔ client secret set, valid until ${expires.toISOString().slice(0, 10)}: re-run --apply before then`);
}
