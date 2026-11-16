#!/usr/bin/env node
// Murmur for Mac's App ID and provisioning profiles, through the App Store Connect API:
//   1. the App ID com.antonmironenko.murmur.mac (macOS) with Sign in with Apple on;
//   2. this Mac as a development device;
//   3. "Murmur Mac Dev" (development, the Apple Development certificate, this Mac);
//   4. "Murmur Mac Direct" (Developer ID, for the download), once a Developer ID identity is in
//      the keychain (the Account Holder creates that certificate: see developer_id.mjs).
// Profiles are installed where Xcode looks for them. Re-running reuses what exists.
//
// Usage: node Mac/scripts/provision_mac.mjs
import { execFileSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { api } from "./asc.mjs";

const BUNDLE = "com.antonmironenko.murmur.mac";
const PROFILES_DIR = path.join(os.homedir(), "Library/Developer/Xcode/UserData/Provisioning Profiles");

function keychainIdentities() {
  return execFileSync("security", ["find-identity", "-v", "-p", "codesigning"], { encoding: "utf8" })
    .split("\n")
    .map((line) => line.match(/([0-9A-F]{40}) "(.+)"/))
    .filter(Boolean)
    .map((match) => ({ sha1: match[1], name: match[2] }));
}

/// The team certificate of `types` whose private key is in this Mac's keychain.
async function certificate(types) {
  const list = await api("GET", `/v1/certificates?filter[certificateType]=${types}&fields[certificates]=name,certificateType,certificateContent,expirationDate&limit=200`);
  const local = keychainIdentities().map((identity) => identity.sha1);
  return list.data.find((cert) => {
    const der = Buffer.from(cert.attributes.certificateContent, "base64");
    return local.includes(crypto.createHash("sha1").update(der).digest("hex").toUpperCase());
  });
}

// 1. The App ID.
let bundle = (await api("GET", `/v1/bundleIds?filter[identifier]=${BUNDLE}&fields[bundleIds]=identifier,platform,name`))
  .data.find((item) => item.attributes.identifier === BUNDLE);
if (!bundle) {
  bundle = (await api("POST", "/v1/bundleIds", {
    data: { type: "bundleIds", attributes: { identifier: BUNDLE, name: "Murmur for Mac", platform: "MAC_OS" } },
  })).data;
  console.log(`✔ registered App ID ${BUNDLE} (${bundle.id})`);
} else {
  console.log(`✔ App ID ${BUNDLE} (${bundle.id}, ${bundle.attributes.platform})`);
}
const capabilities = await api("GET", `/v1/bundleIds/${bundle.id}/bundleIdCapabilities`);
if (!capabilities.data.some((item) => item.attributes.capabilityType === "APPLE_ID_AUTH")) {
  await api("POST", "/v1/bundleIdCapabilities", {
    data: {
      type: "bundleIdCapabilities",
      attributes: {
        capabilityType: "APPLE_ID_AUTH",
        settings: [{ key: "APPLE_ID_AUTH_APP_CONSENT", options: [{ key: "PRIMARY_APP_CONSENT" }] }],
      },
      relationships: { bundleId: { data: { type: "bundleIds", id: bundle.id } } },
    },
  });
  console.log("✔ Sign in with Apple turned on for the App ID");
} else {
  console.log("✔ Sign in with Apple already on");
}

// 2. This Mac.
const udid = execFileSync("system_profiler", ["SPHardwareDataType"], { encoding: "utf8" })
  .match(/Provisioning UDID: (\S+)/)?.[1];
if (!udid) throw new Error("No Provisioning UDID in system_profiler");
let device = (await api("GET", `/v1/devices?filter[udid]=${udid}&fields[devices]=name,status,platform`)).data[0];
if (!device) {
  device = (await api("POST", "/v1/devices", {
    data: { type: "devices", attributes: { name: "Murmur dev Mac", platform: "MAC_OS", udid } },
  })).data;
  console.log(`✔ registered this Mac (${udid})`);
} else {
  console.log(`✔ this Mac is ${device.attributes.name} (${device.attributes.status})`);
}

async function profile(name, profileType, cert, devices) {
  const existing = await api("GET", `/v1/profiles?filter[name]=${encodeURIComponent(name)}&fields[profiles]=name,profileState,expirationDate,profileContent,uuid`);
  let found = existing.data.find((item) => item.attributes.name === name && item.attributes.profileState === "ACTIVE");
  if (!found) {
    for (const stale of existing.data) await api("DELETE", `/v1/profiles/${stale.id}`);
    found = (await api("POST", "/v1/profiles", {
      data: {
        type: "profiles",
        attributes: { name, profileType },
        relationships: {
          bundleId: { data: { type: "bundleIds", id: bundle.id } },
          certificates: { data: [{ type: "certificates", id: cert.id }] },
          ...(devices.length ? { devices: { data: devices.map((item) => ({ type: "devices", id: item.id })) } } : {}),
        },
      },
    })).data;
    console.log(`✔ created profile "${name}"`);
  }
  fs.mkdirSync(PROFILES_DIR, { recursive: true });
  const file = path.join(PROFILES_DIR, `${found.attributes.uuid}.provisionprofile`);
  fs.writeFileSync(file, Buffer.from(found.attributes.profileContent, "base64"));
  console.log(`✔ profile "${name}" installed, expires ${found.attributes.expirationDate.slice(0, 10)}`);
}

// 3. Development.
const development = await certificate("DEVELOPMENT,MAC_APP_DEVELOPMENT");
if (!development) throw new Error("No Apple Development certificate with its key in this keychain");
await profile("Murmur Mac Dev", "MAC_APP_DEVELOPMENT", development, [device]);

// 4. Developer ID.
const developerID = await certificate("DEVELOPER_ID_APPLICATION_G2,DEVELOPER_ID_APPLICATION");
if (developerID) {
  await profile("Murmur Mac Direct", "MAC_APP_DIRECT", developerID, []);
} else {
  console.log("… no Developer ID certificate with its key here yet: \"Murmur Mac Direct\" waits for it");
}
