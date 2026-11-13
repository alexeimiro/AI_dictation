#!/usr/bin/env node
// Fills version 1.0 of Murmur in App Store Connect from docs/APP_STORE.md, through the API (key in
// Config/asc.env): the subtitle and privacy policy URL; the description, keywords, promotional
// text, support and marketing URLs; the copyright; the categories; the age rating (no
// objectionable content); the content rights answer; the App Review notes; the 6.9" iPhone
// screenshots in build/app-store-screenshots, in file name order; the paywall shot as each
// subscription's review screenshot; and, with --build, the build App Review gets. Nothing is
// submitted.
//
// Each field is printed against what App Store Connect has now (= stays, ~ changes). Running it
// again updates the fields, and replaces screenshots only when the files changed. --dry-run reads
// App Store Connect and prints the same, but sends nothing.
// App Store Connect takes the App Privacy answers and the App Review contact only in its web page.
//
// Usage: node scripts/fill_app_store_listing.mjs [--dry-run] [--build <build number>]
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const dryRun = process.argv.includes("--dry-run");
const buildFlag = process.argv.indexOf("--build");
const buildNumber = buildFlag > 0 ? process.argv[buildFlag + 1] : null;
if (buildFlag > 0 && !/^\d+$/.test(buildNumber ?? "")) throw new Error("--build takes a build number, such as 202611131411");
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
// The screenshot App Review gets for each subscription: the paywall shot at 1290 × 2796, a size App
// Store Connect has taken for them (it refused a 1178 × 2556 one). docs/APP_STORE.md makes it.
const REVIEW_SHOT = path.join(SCREENSHOTS, "review/paywall.png");

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
    console.log(`    (dry run) ${method} ${route}`);
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

/** The lines only `before` has (-) and only `after` has (+), in order; shared lines are left out. */
function lineDiff(before, after) {
  const a = before.split("\n");
  const b = after.split("\n");
  // Longest common subsequence of lines, read from the end.
  const common = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      common[i][j] = a[i] === b[j] ? common[i + 1][j + 1] + 1 : Math.max(common[i + 1][j], common[i][j + 1]);
    }
  }
  const lines = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      i++;
      j++;
    } else if (i < a.length && (j === b.length || common[i + 1][j] >= common[i][j + 1])) {
      lines.push(`- ${a[i++]}`);
    } else {
      lines.push(`+ ${b[j++]}`);
    }
  }
  return lines;
}

/** Prints each of `next`'s attributes against `live`: "~" with the change, "=" when it stays. */
function report(label, live, next) {
  const same = [];
  for (const [key, value] of Object.entries(next)) {
    const before = live?.[key] ?? null;
    if (before === value) {
      same.push(key);
    } else if ([before, value].some((text) => typeof text === "string" && (text.includes("\n") || text.length > 60))) {
      console.log(`  ~ ${label} ${key}:`);
      for (const line of lineDiff(String(before ?? ""), String(value))) console.log(`      ${line}`);
    } else {
      console.log(`  ~ ${label} ${key}: ${JSON.stringify(before)} → ${JSON.stringify(value)}`);
    }
  }
  if (same.length) console.log(`  = ${label}: ${same.length > 6 ? `${same.length} answers` : same.join(", ")} unchanged`);
}

const relation = (type, id) => ({ data: { type, id } });
/** Prints what changes against `live`, then sends it. */
async function patch(type, id, live, attributes) {
  report(type, live, attributes);
  return api("PATCH", `/v1/${type}/${id}`, { data: { type, id, attributes } });
}

/** Creates an asset of `type` for `file` (a screenshot), sends its bytes and marks it uploaded. */
async function upload(type, file, relationships) {
  const asset = (await api("POST", `/v1/${type}`, {
    data: { type, attributes: { fileName: file.name, fileSize: file.data.length }, relationships },
  })).data;
  if (dryRun) return asset;
  for (const operation of asset.attributes.uploadOperations) {
    const response = await fetch(operation.url, {
      method: operation.method,
      headers: Object.fromEntries(operation.requestHeaders.map((header) => [header.name, header.value])),
      body: file.data.subarray(operation.offset, operation.offset + operation.length),
    });
    if (!response.ok) throw new Error(`Uploading ${file.name} → ${response.status}`);
  }
  await api("PATCH", `/v1/${type}/${asset.id}`, {
    data: { type, id: asset.id, attributes: { uploaded: true, sourceFileChecksum: file.checksum } },
  });
  return asset;
}

/** "1-home.png (1320×2868, md5 3f2a9c1e)" for an uploaded image. */
function describe(asset) {
  const { fileName, imageAsset, sourceFileChecksum } = asset.attributes;
  return `${fileName} (${imageAsset ? `${imageAsset.width}×${imageAsset.height}, ` : ""}md5 ${sourceFileChecksum?.slice(0, 8)})`;
}

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
console.log(`✔ ${app.attributes.name} (${app.id}), version ${VERSION} (${version.attributes.appStoreState})`
  + (dryRun ? ": dry run, nothing is sent" : ""));

// App Information: subtitle, privacy policy, categories, content rights.
await patch("appInfoLocalizations", infoText.id, infoText.attributes,
  { subtitle: listing.subtitle, privacyPolicyUrl: listing.privacyPolicyUrl });
const categories = (await api("GET", `/v1/appInfos/${info.id}?include=primaryCategory,secondaryCategory`)).data.relationships;
report("appInfos", {
  primaryCategory: categories?.primaryCategory?.data?.id ?? null,
  secondaryCategory: categories?.secondaryCategory?.data?.id ?? null,
}, { primaryCategory: "PRODUCTIVITY", secondaryCategory: "UTILITIES" });
await api("PATCH", `/v1/appInfos/${info.id}`, {
  data: {
    type: "appInfos", id: info.id,
    relationships: {
      primaryCategory: relation("appCategories", "PRODUCTIVITY"),
      secondaryCategory: relation("appCategories", "UTILITIES"),
    },
  },
});
await patch("apps", app.id, app.attributes, { contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" });
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
await patch("ageRatingDeclarations", ageRating.id, ageRating.attributes, {
  ...Object.fromEntries(NONE.map((key) => [key, "NONE"])),
  ...Object.fromEntries(NO.map((key) => [key, false])),
});
console.log("✔ age rating answers (no objectionable content)");

// Version 1.0: the listing and the copyright.
await patch("appStoreVersionLocalizations", versionText.id, versionText.attributes, {
  description: listing.description,
  keywords: listing.keywords,
  promotionalText: listing.promotionalText,
  supportUrl: listing.supportUrl,
  marketingUrl: listing.marketingUrl,
});
await patch("appStoreVersions", version.id, version.attributes, { copyright: listing.copyright });
console.log("✔ description, keywords, promotional text, support and marketing URLs, copyright");

// App Review notes. Sign in with Apple works for review, so no demo account.
const review = (await api("GET", `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)).data;
const reviewAttributes = { notes: listing.reviewNotes, demoAccountRequired: false };
if (review) {
  await patch("appStoreReviewDetails", review.id, review.attributes, reviewAttributes);
} else {
  report("appStoreReviewDetails", null, reviewAttributes);
  await api("POST", "/v1/appStoreReviewDetails", {
    data: {
      type: "appStoreReviewDetails", attributes: reviewAttributes,
      relationships: { appStoreVersion: relation("appStoreVersions", version.id) },
    },
  });
}
console.log("✔ App Review notes");

// The build App Review gets, when --build names one.
if (buildNumber) {
  const build = (await api("GET",
    `/v1/builds?filter[app]=${app.id}&filter[version]=${buildNumber}&filter[preReleaseVersion.version]=${VERSION}&limit=1`)).data[0];
  if (!build) throw new Error(`App Store Connect has no build ${buildNumber} of version ${VERSION}`);
  const { processingState, expired, uploadedDate, usesNonExemptEncryption } = build.attributes;
  if (processingState !== "VALID" || expired) throw new Error(`Build ${buildNumber} is ${expired ? "expired" : processingState}`);
  const attached = (await api("GET", `/v1/appStoreVersions/${version.id}/build`)).data;
  report("appStoreVersions", { build: attached?.attributes.version ?? null }, { build: buildNumber });
  console.log(`    ${buildNumber}: ${processingState}, uploaded ${uploadedDate}, usesNonExemptEncryption ${usesNonExemptEncryption}`);
  if (attached?.id !== build.id) {
    await api("PATCH", `/v1/appStoreVersions/${version.id}/relationships/build`, relation("builds", build.id));
  }
  console.log(`✔ build ${buildNumber}`);
}

// Screenshots: replaced only when the files differ from what's uploaded.
const readImage = (file) => {
  const data = fs.readFileSync(file);
  return { name: path.basename(file), data, checksum: crypto.createHash("md5").update(data).digest("hex") };
};
const files = fs.readdirSync(SCREENSHOTS).filter((name) => name.endsWith(".png")).sort()
  .map((name) => readImage(path.join(SCREENSHOTS, name)));
if (files.length === 0 || files.length > 10) throw new Error(`Expected 1–10 screenshots in ${SCREENSHOTS}`);
let set = (await api("GET", `/v1/appStoreVersionLocalizations/${versionText.id}/appScreenshotSets`)).data
  .find((item) => item.attributes.screenshotDisplayType === DISPLAY_TYPE);
const uploaded = set ? (await api("GET", `/v1/appScreenshotSets/${set.id}/appScreenshots`)).data : [];
const same = uploaded.length === files.length && uploaded.every((shot, index) =>
  shot.attributes.sourceFileChecksum === files[index].checksum && shot.attributes.assetDeliveryState?.state === "COMPLETE");
if (same) {
  console.log(`✔ ${files.length} screenshots already uploaded`);
} else {
  console.log(`  ~ ${DISPLAY_TYPE} screenshots, ${uploaded.length} → ${files.length}:`);
  for (let index = 0; index < Math.max(uploaded.length, files.length); index++) {
    const now = uploaded[index] ? describe(uploaded[index]) : "none";
    const next = files[index] ? `${files[index].name} (md5 ${files[index].checksum.slice(0, 8)})` : "none";
    console.log(`      ${index + 1}. ${now} → ${next}`);
  }
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
    await upload("appScreenshots", file, { appScreenshotSet: relation("appScreenshotSets", set.id) });
    if (!dryRun) console.log(`  uploaded ${file.name}`);
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
  console.log(`✔ ${files.length} screenshots${dryRun ? "" : ` uploaded (${DISPLAY_TYPE})`}`);
}

// Each subscription's review screenshot: the paywall.
if (!fs.existsSync(REVIEW_SHOT)) throw new Error(`No ${path.relative(root, REVIEW_SHOT)}; docs/APP_STORE.md says how to make it`);
const reviewShot = readImage(REVIEW_SHOT);
for (const group of (await api("GET", `/v1/apps/${app.id}/subscriptionGroups?limit=50`)).data) {
  for (const subscription of (await api("GET", `/v1/subscriptionGroups/${group.id}/subscriptions?limit=50`)).data) {
    const name = subscription.attributes.name;
    const current = (await api("GET", `/v1/subscriptions/${subscription.id}/appStoreReviewScreenshot`)).data;
    if (current?.attributes.sourceFileChecksum === reviewShot.checksum && current.attributes.assetDeliveryState?.state === "COMPLETE") {
      console.log(`✔ ${name}: review screenshot already uploaded`);
      continue;
    }
    console.log(`  ~ ${name} review screenshot: ${current ? describe(current) : "none"} → review/${reviewShot.name} (md5 ${reviewShot.checksum.slice(0, 8)})`);
    if (current) await api("DELETE", `/v1/subscriptionAppStoreReviewScreenshots/${current.id}`);
    const asset = await upload("subscriptionAppStoreReviewScreenshots", reviewShot,
      { subscription: relation("subscriptions", subscription.id) });
    for (let attempt = 0; attempt < 30 && !dryRun; attempt++) {
      const state = (await api("GET", `/v1/subscriptionAppStoreReviewScreenshots/${asset.id}`)).data.attributes.assetDeliveryState;
      if (state?.state === "FAILED") throw new Error(`${name}'s review screenshot rejected: ${JSON.stringify(state.errors)}`);
      if (state?.state === "COMPLETE") break;
      await new Promise((resolve) => setTimeout(resolve, 4000));
    }
    console.log(`✔ ${name}: review screenshot${dryRun ? "" : " uploaded"}`);
  }
}

if (dryRun) console.log("\nDry run: nothing was sent to App Store Connect.");
console.log("\nLeft in App Store Connect's web page: App Privacy, the App Review contact, and adding the");
console.log("two subscriptions to version 1.0 before submitting.");
