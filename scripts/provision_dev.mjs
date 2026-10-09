#!/usr/bin/env node
// Creates (or refreshes) Murmur's iOS development provisioning profiles through the App Store
// Connect API and installs them for Xcode, so device builds can use manual signing without an
// Apple ID signed in to Xcode. (xcodebuild's own -authenticationKey* provisioning is rejected by
// Apple for this key even though the key works with the public API.)
//
// Prerequisite — portal only, the public API has no App Groups endpoint:
//   App Group group.com.antonmironenko.murmur, and the three App IDs below with the
//   App Groups capability enabled and that group assigned.
//
// Usage: node scripts/provision_dev.mjs   (reads Config/asc.env)
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const env = Object.fromEntries(
  fs.readFileSync(path.join(root, "Config/asc.env"), "utf8")
    .split("\n")
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => {
      const [key, ...rest] = line.split("=");
      return [key, rest.join("=").replace("$HOME", os.homedir())];
    }),
);

const APP_GROUP = "group.com.antonmironenko.murmur";
const TARGETS = [
  { identifier: "com.antonmironenko.murmur", profile: "Murmur Dev App" },
  { identifier: "com.antonmironenko.murmur.keyboard", profile: "Murmur Dev Keyboard" },
  { identifier: "com.antonmironenko.murmur.widgets", profile: "Murmur Dev Widgets" },
];
const PROFILES_DIR = path.join(os.homedir(), "Library/Developer/Xcode/UserData/Provisioning Profiles");

function token() {
  const b64url = (data) => Buffer.from(data).toString("base64url");
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "ES256", kid: env.ASC_KEY_ID, typ: "JWT" }));
  const payload = b64url(JSON.stringify({
    iss: env.ASC_ISSUER_ID, iat: now, exp: now + 600, aud: "appstoreconnect-v1",
  }));
  const key = crypto.createPrivateKey(fs.readFileSync(env.ASC_KEY_PATH));
  const signature = crypto.sign("sha256", Buffer.from(`${header}.${payload}`), { key, dsaEncoding: "ieee-p1363" });
  return `${header}.${payload}.${b64url(signature)}`;
}

async function api(method, route, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${route}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  const json = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const detail = json?.errors?.map((error) => `${error.title}: ${error.detail}`).join("; ");
    throw new Error(`${method} ${route} → ${response.status} ${detail ?? text}`);
  }
  return json;
}

function fail(message) {
  console.error(`✘ ${message}`);
  process.exit(1);
}

// 1. The development certificate whose private key is in this Mac's keychain.
const localIdentities = execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], { encoding: "utf8" })
  .match(/[0-9A-F]{40}/g) ?? [];
const certificates = await api("GET",
  "/v1/certificates?filter[certificateType]=DEVELOPMENT,IOS_DEVELOPMENT&fields[certificates]=name,certificateContent,expirationDate&limit=200");
const certificate = certificates.data.find((cert) => {
  const der = Buffer.from(cert.attributes.certificateContent, "base64");
  return localIdentities.includes(crypto.createHash("sha1").update(der).digest("hex").toUpperCase());
});
if (!certificate) fail("No development certificate in this team matches a signing identity in the keychain.");
console.log(`✔ certificate ${certificate.attributes.name} (${certificate.id}), expires ${certificate.attributes.expirationDate.slice(0, 10)}`);

// 2. The test device.
const devices = await api("GET", `/v1/devices?filter[udid]=${env.DEVICE_UDID}&fields[devices]=name,status`);
const device = devices.data.find((item) => item.attributes.status === "ENABLED");
if (!device) fail(`Device ${env.DEVICE_UDID} is not registered and enabled.`);
console.log(`✔ device ${device.attributes.name} (${device.id})`);

fs.mkdirSync(PROFILES_DIR, { recursive: true });

for (const target of TARGETS) {
  // 3. The App ID, which must have App Groups enabled.
  const bundleIds = await api("GET", `/v1/bundleIds?filter[identifier]=${target.identifier}&fields[bundleIds]=identifier,name`);
  const bundleId = bundleIds.data.find((item) => item.attributes.identifier === target.identifier);
  if (!bundleId) fail(`App ID ${target.identifier} doesn't exist yet — create it in the developer portal.`);
  const capabilities = await api("GET", `/v1/bundleIds/${bundleId.id}/bundleIdCapabilities`);
  if (!capabilities.data.some((capability) => capability.attributes.capabilityType === "APP_GROUPS")) {
    fail(`${target.identifier} doesn't have the App Groups capability enabled.`);
  }

  // 4. Replace any previous profile with this name (profiles snapshot capabilities when created).
  const existing = await api("GET",
    `/v1/profiles?filter[name]=${encodeURIComponent(target.profile)}&fields[profiles]=name,uuid`);
  for (const profile of existing.data) {
    await api("DELETE", `/v1/profiles/${profile.id}`);
  }
  const created = await api("POST", "/v1/profiles", {
    data: {
      type: "profiles",
      attributes: { name: target.profile, profileType: "IOS_APP_DEVELOPMENT" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundleId.id } },
        certificates: { data: [{ type: "certificates", id: certificate.id }] },
        devices: { data: [{ type: "devices", id: device.id }] },
      },
    },
  });

  // 5. Install for Xcode and check the App Group made it into the profile.
  const { uuid, profileContent } = created.data.attributes;
  const file = path.join(PROFILES_DIR, `${uuid}.mobileprovision`);
  fs.writeFileSync(file, Buffer.from(profileContent, "base64"));
  const decoded = execFileSync("security", ["cms", "-D", "-i", file], { encoding: "utf8" });
  if (!decoded.includes(APP_GROUP)) {
    fail(`${target.profile} was created but doesn't include ${APP_GROUP}. Assign the group to ` +
      `${target.identifier} under App Groups › Configure in the portal, then run this again.`);
  }
  console.log(`✔ ${target.profile} → ${target.identifier} (installed ${uuid})`);
}
console.log("Profiles ready. Build with scripts/device_build.sh.");
