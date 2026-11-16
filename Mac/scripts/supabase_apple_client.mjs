#!/usr/bin/env node
// Lets Murmur for Mac sign in with Apple on the hosted project: Supabase checks an Apple ID
// token's audience against the Apple provider's client IDs, so the Mac app's bundle ID joins the
// iPhone app's there. Only that one field is changed, through the Management API (never
// `supabase config push`, which would overwrite the dashboard's auth settings).
//
// Usage: node Mac/scripts/supabase_apple_client.mjs           show the current client IDs
//        node Mac/scripts/supabase_apple_client.mjs --apply   add the Mac app's bundle ID
import { execFileSync } from "node:child_process";

const REF = "aljjzxfzqbbmyfmardaj";
const MAC = "com.antonmironenko.murmur.mac";

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
if (current.includes(MAC)) {
  console.log(`✔ ${MAC} is already allowed`);
} else if (process.argv.includes("--apply")) {
  const updated = await authConfig("PATCH", { external_apple_client_id: [...current, MAC].join(",") });
  console.log(`✔ Client IDs now: ${updated.external_apple_client_id}`);
} else {
  console.log(`(dry run) would add ${MAC}; run with --apply`);
}
