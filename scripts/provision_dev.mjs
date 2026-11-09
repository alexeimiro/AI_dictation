#!/usr/bin/env node
// Creates (or refreshes) Murmur's iOS development provisioning profiles through the App Store
// Connect API and installs them for Xcode, so device builds can use manual signing without an
// Apple ID signed in to Xcode. (xcodebuild's own -authenticationKey* provisioning is rejected by
// Apple for this key even though the key works with the public API.)
//
// Prerequisite — portal only, the public API has no App Groups endpoint:
//   App Group group.com.antonmironenko.murmur, and the three App IDs below with the
//   App Groups capability enabled and that group assigned.
// The app's ID also gets Sign in with Apple here (`capabilities` below), turned on through the API
// if it's off, since the app's entitlements ask for it.
//
// Usage: node scripts/provision_dev.mjs              development profiles (reads Config/asc.env)
//        node scripts/provision_dev.mjs --appstore  App Store profiles for TestFlight uploads,
//                                                   creating a distribution certificate if needed
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

const APP_STORE = process.argv.includes("--appstore");
const PROFILE_PREFIX = APP_STORE ? "Murmur AppStore" : "Murmur Dev";
const APP_GROUP = "group.com.antonmironenko.murmur";
const TARGETS = [
  { identifier: "com.antonmironenko.murmur", profile: `${PROFILE_PREFIX} App`, capabilities: ["APPLE_ID_AUTH"] },
  { identifier: "com.antonmironenko.murmur.keyboard", profile: `${PROFILE_PREFIX} Keyboard` },
  { identifier: "com.antonmironenko.murmur.widgets", profile: `${PROFILE_PREFIX} Widgets` },
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

// 1. The signing certificate whose private key is in this Mac's keychain.
function localIdentities() {
  return execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], { encoding: "utf8" })
    .match(/[0-9A-F]{40}/g) ?? [];
}
async function findCertificate() {
  const types = APP_STORE ? "DISTRIBUTION,IOS_DISTRIBUTION" : "DEVELOPMENT,IOS_DEVELOPMENT";
  const certificates = await api("GET",
    `/v1/certificates?filter[certificateType]=${types}&fields[certificates]=name,certificateContent,expirationDate&limit=200`);
  const local = localIdentities();
  return certificates.data.find((cert) => {
    const der = Buffer.from(cert.attributes.certificateContent, "base64");
    return local.includes(crypto.createHash("sha1").update(der).digest("hex").toUpperCase());
  });
}
// Creates a distribution certificate from a fresh key and imports both into the login keychain.
async function createDistributionCertificate() {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "murmur-dist-"));
  const keyFile = path.join(work, "key.pem");
  const csrFile = path.join(work, "request.csr");
  execFileSync("openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", keyFile,
    "-out", csrFile, "-subj", "/CN=Murmur Distribution"], { stdio: "ignore" });
  const csrContent = fs.readFileSync(csrFile, "utf8").replace(/-----[^-]+-----|\s/g, "");
  const created = await api("POST", "/v1/certificates", {
    data: { type: "certificates", attributes: { certificateType: "DISTRIBUTION", csrContent } },
  });
  const certFile = path.join(work, "cert.cer");
  fs.writeFileSync(certFile, Buffer.from(created.data.attributes.certificateContent, "base64"));
  const pemFile = path.join(work, "cert.pem");
  execFileSync("openssl", ["x509", "-inform", "DER", "-in", certFile, "-out", pemFile]);
  // SHA1/3DES: the only PKCS#12 encryption `security import` accepts.
  const p12File = path.join(work, "identity.p12");
  const password = crypto.randomBytes(12).toString("hex");
  execFileSync("openssl", ["pkcs12", "-export", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
    "-macalg", "sha1", "-inkey", keyFile, "-in", pemFile,
    "-out", p12File, "-passout", `pass:${password}`], { stdio: "ignore" });
  execFileSync("security", ["import", p12File, "-k", path.join(os.homedir(), "Library/Keychains/login.keychain-db"),
    "-P", password, "-T", "/usr/bin/codesign"], { stdio: "inherit" });
  fs.rmSync(work, { recursive: true, force: true });
  console.log(`✔ created distribution certificate ${created.data.id}`);
}
let certificate = await findCertificate();
if (!certificate && APP_STORE) {
  await createDistributionCertificate();
  certificate = await findCertificate();
}
if (!certificate) fail("No matching certificate in this team has a signing identity in the keychain.");
console.log(`✔ certificate ${certificate.attributes.name} (${certificate.id}), expires ${certificate.attributes.expirationDate.slice(0, 10)}`);

// 2. The test devices (DEVICE_UDID is comma-separated), registering any that are new.
// App Store profiles don't list devices.
const devices = [];
for (const udid of APP_STORE ? [] : env.DEVICE_UDID.split(",").map((item) => item.trim()).filter(Boolean)) {
  const found = await api("GET", `/v1/devices?filter[udid]=${udid}&fields[devices]=name,status`);
  let device = found.data[0];
  if (!device) {
    const name = `Murmur test ${udid.slice(-6)}`;
    device = (await api("POST", "/v1/devices", {
      data: { type: "devices", attributes: { name, platform: "IOS", udid } },
    })).data;
    console.log(`✔ registered ${name}`);
  }
  if (device.attributes.status !== "ENABLED") fail(`Device ${udid} is registered but disabled.`);
  console.log(`✔ device ${device.attributes.name} (${device.id})`);
  devices.push(device);
}

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
  for (const type of target.capabilities ?? []) {
    if (capabilities.data.some((capability) => capability.attributes.capabilityType === type)) continue;
    await api("POST", "/v1/bundleIdCapabilities", {
      data: {
        type: "bundleIdCapabilities",
        attributes: {
          capabilityType: type,
          ...(type === "APPLE_ID_AUTH"
            ? { settings: [{ key: "APPLE_ID_AUTH_APP_CONSENT", options: [{ key: "PRIMARY_APP_CONSENT" }] }] }
            : {}),
        },
        relationships: { bundleId: { data: { type: "bundleIds", id: bundleId.id } } },
      },
    });
    console.log(`✔ turned on ${type} for ${target.identifier}`);
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
      attributes: { name: target.profile, profileType: APP_STORE ? "IOS_APP_STORE" : "IOS_APP_DEVELOPMENT" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundleId.id } },
        certificates: { data: [{ type: "certificates", id: certificate.id }] },
        ...(APP_STORE ? {} : { devices: { data: devices.map((device) => ({ type: "devices", id: device.id })) } }),
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
console.log(`Profiles ready. Build with scripts/${APP_STORE ? "testflight_upload" : "device_build"}.sh.`);
