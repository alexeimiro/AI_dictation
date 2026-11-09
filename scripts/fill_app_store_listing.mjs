#!/usr/bin/env node
// Fills version 1.0 of Murmur in App Store Connect from docs/APP_STORE.md, through the API (key in
// Config/asc.env): the subtitle and privacy policy URL; the description, keywords, promotional
// text, support and marketing URLs; the copyright; the categories; the age rating (no
// objectionable content); the content rights answer; the App Review notes; and the 6.9" iPhone
// screenshots in build/app-store-screenshots, in file name order. Nothing is submitted.
//
// Running it again updates the fields, and replaces the screenshots only when the files changed.
// App Store Connect takes the App Privacy answers and the App Review contact only in its web page.
//
// Usage: node scripts/fill_app_store_listing.mjs [--dry-run]
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const dryRun = process.argv.includes("--dry-run");
const env = Object.fromEntries(
  fs.readFileSync(path.join(root, "Config/asc.env"), "utf8")
    .split("\n")
    .filter((line) => /^[A-Z_]+=/.test(line))
    .map((line) => {
      const [key, ...rest] = line.split("=");
      return [key, rest.join("=").replace("$HOME", os.homedir())];
    }),
);

const BUNDLE_ID = "com.antonmironenko.murmur";
const VERSION = "1.0";
const LOCALE = "en-US";
const SCREENSHOTS = path.join(root, "build/app-store-screenshots");
// The 6.9" iPhone slot (1320 × 2868) is still called APP_IPHONE_67 in the API.
const DISPLAY_TYPE = "APP_IPHONE_67";

// The listing, as docs/APP_STORE.md words it.
const doc = fs.readFileSync(path.join(root, "docs/APP_STORE.md"), "utf8");

/** The `code` after a bold label, in the label's paragraph: **Subtitle** (30): `…`. */
function code(label) {
  const start = doc.indexOf(`**${label}**`);
  if (start < 0) throw new Error(`docs/APP_STORE.md has no **${label}**`);
  const match = /`([^`]+)`/.exec(doc.slice(start).split("\n\n")[0]);
  if (!match) throw new Error(`**${label}** has no \`value\``);
  return match[1];
}

/** The > quoted block after a label or heading; a bare > is a blank line. */
function quote(label) {
  const start = doc.indexOf(label);
  if (start < 0) throw new Error(`docs/APP_STORE.md has no ${label}`);
  const lines = doc.slice(start).split("\n").slice(1);
  const first = lines.findIndex((line) => line.startsWith(">"));
  const block = [];
  for (const line of lines.slice(first)) {
    if (!line.startsWith(">")) break;
    block.push(line.replace(/^> ?/, ""));
  }
  return block.join("\n");
}

const listing = {
  subtitle: code("Subtitle"),
  promotionalText: quote("**Promotional text**"),
  keywords: code("Keywords"),
  description: quote("**Description**"),
  supportUrl: code("Support URL"),
  marketingUrl: code("Marketing URL"),
  privacyPolicyUrl: code("Privacy Policy URL"),
  copyright: code("Copyright"),
  reviewNotes: quote("## App Review notes"),
};
const LIMITS = { subtitle: 30, promotionalText: 170, keywords: 100, description: 4000, reviewNotes: 4000 };
for (const [field, limit] of Object.entries(LIMITS)) {
  if (listing[field].length > limit) throw new Error(`${field} is ${listing[field].length} characters; the limit is ${limit}`);
}
if (/\[[A-Z ]+\]/.test(JSON.stringify(listing))) throw new Error("docs/APP_STORE.md still has a [PLACEHOLDER]");

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
  if (dryRun && method !== "GET") {
    console.log(`  (dry run) ${method} ${route}`);
    return { data: { id: "dry-run", attributes: {} } };
  }
  const url = route.startsWith("http") ? route : `https://api.appstoreconnect.apple.com${route}`;
  const response = await fetch(url, {
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

const relation = (type, id) => ({ data: { type, id } });
const patch = (type, id, attributes, relationships) =>
  api("PATCH", `/v1/${type}/${id}`, { data: { type, id, attributes, relationships } });

// The app, its version 1.0, and their en-US texts.
const app = (await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`)).data[0];
if (!app) throw new Error(`No app with bundle ID ${BUNDLE_ID}`);
const version = (await api("GET", `/v1/apps/${app.id}/appStoreVersions?filter[versionString]=${VERSION}&filter[platform]=IOS`)).data[0];
if (!version) throw new Error(`No version ${VERSION}`);
const info = (await api("GET", `/v1/apps/${app.id}/appInfos`)).data
  .find((item) => item.attributes.appStoreState !== "READY_FOR_SALE") ?? null;
if (!info) throw new Error("No editable App Information");
const infoText = (await api("GET", `/v1/appInfos/${info.id}/appInfoLocalizations`)).data
  .find((item) => item.attributes.locale === LOCALE);
const versionText = (await api("GET", `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).data
  .find((item) => item.attributes.locale === LOCALE);
if (!infoText || !versionText) throw new Error(`No ${LOCALE} texts`);
console.log(`✔ ${app.attributes.name} (${app.id}), version ${VERSION} (${version.attributes.appStoreState})`);

// App Information: subtitle, privacy policy, categories, content rights.
await patch("appInfoLocalizations", infoText.id, { subtitle: listing.subtitle, privacyPolicyUrl: listing.privacyPolicyUrl });
await patch("appInfos", info.id, undefined, {
  primaryCategory: relation("appCategories", "PRODUCTIVITY"),
  secondaryCategory: relation("appCategories", "UTILITIES"),
});
await patch("apps", app.id, { contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" });
console.log("✔ subtitle, privacy policy URL, Productivity / Utilities, no third-party content");

// Age rating: nothing objectionable, no web browsing, chat, ads or content from other people.
const NONE = [
  "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
  "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
  "sexualContentGraphicAndNudity", "sexualContentOrNudity", "violenceCartoonOrFantasy", "violenceRealistic",
  "violenceRealisticProlongedGraphicOrSadistic",
];
const NO = [
  "advertising", "ageAssurance", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat",
  "parentalControls", "socialMedia", "socialMediaAgeRestricted", "unrestrictedWebAccess", "userGeneratedContent",
];
const ageRating = (await api("GET", `/v1/appInfos/${info.id}/ageRatingDeclaration`)).data;
await patch("ageRatingDeclarations", ageRating.id, {
  ...Object.fromEntries(NONE.map((key) => [key, "NONE"])),
  ...Object.fromEntries(NO.map((key) => [key, false])),
});
console.log("✔ age rating answers (no objectionable content)");

// Version 1.0: the listing and the copyright.
await patch("appStoreVersionLocalizations", versionText.id, {
  description: listing.description,
  keywords: listing.keywords,
  promotionalText: listing.promotionalText,
  supportUrl: listing.supportUrl,
  marketingUrl: listing.marketingUrl,
});
await patch("appStoreVersions", version.id, { copyright: listing.copyright });
console.log("✔ description, keywords, promotional text, support and marketing URLs, copyright");

// App Review notes. Sign in with Apple works for review, so no demo account.
const review = (await api("GET", `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)).data;
const reviewAttributes = { notes: listing.reviewNotes, demoAccountRequired: false };
if (review) {
  await patch("appStoreReviewDetails", review.id, reviewAttributes);
} else {
  await api("POST", "/v1/appStoreReviewDetails", {
    data: {
      type: "appStoreReviewDetails", attributes: reviewAttributes,
      relationships: { appStoreVersion: relation("appStoreVersions", version.id) },
    },
  });
}
console.log("✔ App Review notes");

// Screenshots: replaced only when the files differ from what's uploaded.
const files = fs.readdirSync(SCREENSHOTS).filter((name) => name.endsWith(".png")).sort()
  .map((name) => {
    const data = fs.readFileSync(path.join(SCREENSHOTS, name));
    return { name, data, checksum: crypto.createHash("md5").update(data).digest("hex") };
  });
if (files.length === 0 || files.length > 10) throw new Error(`Expected 1–10 screenshots in ${SCREENSHOTS}`);
let set = (await api("GET", `/v1/appStoreVersionLocalizations/${versionText.id}/appScreenshotSets`)).data
  .find((item) => item.attributes.screenshotDisplayType === DISPLAY_TYPE);
const uploaded = set ? (await api("GET", `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data : [];
const same = uploaded.length === files.length && uploaded.every((shot, index) =>
  shot.attributes.sourceFileChecksum === files[index].checksum && shot.attributes.assetDeliveryState?.state === "COMPLETE");
if (same) {
  console.log(`✔ ${files.length} screenshots already uploaded`);
} else {
  if (!set) {
    set = (await api("POST", "/v1/appScreenshotSets", {
      data: {
        type: "appScreenshotSets", attributes: { screenshotDisplayType: DISPLAY_TYPE },
        relationships: { appStoreVersionLocalization: relation("appStoreVersionLocalizations", versionText.id) },
      },
    })).data;
  }
  for (const shot of uploaded) await api("DELETE", `/v1/appScreenshots/${shot.id}`);
  for (const file of files) {
    const shot = (await api("POST", "/v1/appScreenshots", {
      data: {
        type: "appScreenshots", attributes: { fileName: file.name, fileSize: file.data.length },
        relationships: { appScreenshotSet: relation("appScreenshotSets", set.id) },
      },
    })).data;
    if (dryRun) continue;
    for (const operation of shot.attributes.uploadOperations) {
      const response = await fetch(operation.url, {
        method: operation.method,
        headers: Object.fromEntries(operation.requestHeaders.map((header) => [header.name, header.value])),
        body: file.data.subarray(operation.offset, operation.offset + operation.length),
      });
      if (!response.ok) throw new Error(`Uploading ${file.name} → ${response.status}`);
    }
    await patch("appScreenshots", shot.id, { uploaded: true, sourceFileChecksum: file.checksum });
    console.log(`  uploaded ${file.name}`);
  }
  // App Store Connect checks each image after upload; a wrong size fails here.
  for (let attempt = 0; attempt < 30 && !dryRun; attempt++) {
    const states = (await api("GET", `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data
      .map((shot) => ({ name: shot.attributes.fileName, state: shot.attributes.assetDeliveryState }));
    const failed = states.filter((item) => item.state?.state === "FAILED");
    if (failed.length) {
      throw new Error(`Screenshots rejected: ${failed.map((item) => `${item.name} ${JSON.stringify(item.state.errors)}`).join("; ")}`);
    }
    if (states.every((item) => item.state?.state === "COMPLETE")) break;
    await new Promise((resolve) => setTimeout(resolve, 4000));
  }
  console.log(`✔ ${files.length} screenshots uploaded (${DISPLAY_TYPE})`);
}

console.log("\nLeft in App Store Connect's web page: App Privacy, the App Review contact, and adding the");
console.log("two subscriptions to version 1.0 before submitting.");
