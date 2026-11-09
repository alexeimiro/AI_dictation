#!/usr/bin/env node
// Creates Murmur Pro's subscriptions in App Store Connect through the API (key in Config/asc.env):
// the "Murmur Pro" group, Monthly at $9.99 and Annual at $79.99 with their names, prices in every
// territory (Apple's equalized prices for the US price), availability everywhere, and the App
// Store Server Notifications V2 URL (production and sandbox) of the app-store-notifications
// function. Running it again reuses what exists and fills in what's missing.
//
// Still the account holder's, in App Store Connect: the Paid Apps agreement, and a review
// screenshot of the paywall for each subscription before the first review.
//
// Usage: node scripts/create_subscriptions.mjs
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

const BUNDLE_ID = "com.antonmironenko.murmur";
const GROUP = "Murmur Pro";
const NOTIFICATIONS_URL = "https://aljjzxfzqbbmyfmardaj.supabase.co/functions/v1/app-store-notifications";
const PLANS = [
  {
    productId: "com.antonmironenko.murmur.pro.monthly", name: "Murmur Pro Monthly", period: "ONE_MONTH",
    usd: "9.99", description: "Unlimited words, every week",
  },
  {
    productId: "com.antonmironenko.murmur.pro.annual", name: "Murmur Pro Annual", period: "ONE_YEAR",
    usd: "79.99", description: "Unlimited words, billed yearly",
  },
];

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

/** Every page of a list. */
async function all(route) {
  const items = [];
  const included = [];
  let next = route;
  while (next) {
    const page = await api("GET", next);
    items.push(...page.data);
    included.push(...(page.included ?? []));
    next = page.links?.next;
  }
  return { items, included };
}

const relation = (type, id) => ({ data: { type, id } });

// 1. The app.
const apps = await api("GET", `/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.data.find((item) => item.attributes.bundleId === BUNDLE_ID);
if (!app) throw new Error(`No app with bundle ID ${BUNDLE_ID}`);
console.log(`✔ app ${app.attributes.name} (${app.id})`);

// 2. The group and its name on the App Store.
let group = (await all(`/v1/apps/${app.id}/subscriptionGroups?limit=50`)).items
  .find((item) => item.attributes.referenceName === GROUP);
if (!group) {
  group = (await api("POST", "/v1/subscriptionGroups", {
    data: { type: "subscriptionGroups", attributes: { referenceName: GROUP }, relationships: { app: relation("apps", app.id) } },
  })).data;
  console.log(`✔ created group ${GROUP} (${group.id})`);
} else {
  console.log(`✔ group ${GROUP} (${group.id})`);
}
const groupNames = await all(`/v1/subscriptionGroups/${group.id}/subscriptionGroupLocalizations`);
if (!groupNames.items.some((item) => item.attributes.locale === "en-US")) {
  await api("POST", "/v1/subscriptionGroupLocalizations", {
    data: {
      type: "subscriptionGroupLocalizations", attributes: { locale: "en-US", name: GROUP },
      relationships: { subscriptionGroup: relation("subscriptionGroups", group.id) },
    },
  });
  console.log("✔ group name (en-US)");
}

const territories = (await all("/v1/territories?limit=200")).items.map((item) => item.id);
console.log(`✔ ${territories.length} territories`);

for (const plan of PLANS) {
  // 3. The subscription.
  let subscription = (await all(`/v1/subscriptionGroups/${group.id}/subscriptions?limit=50`)).items
    .find((item) => item.attributes.productId === plan.productId);
  if (!subscription) {
    subscription = (await api("POST", "/v1/subscriptions", {
      data: {
        type: "subscriptions",
        attributes: { name: plan.name, productId: plan.productId, subscriptionPeriod: plan.period,
                      familySharable: false, groupLevel: 1 },
        relationships: { group: relation("subscriptionGroups", group.id) },
      },
    })).data;
    console.log(`✔ created ${plan.productId} (${subscription.id})`);
  } else {
    console.log(`✔ ${plan.productId} (${subscription.id}), ${subscription.attributes.state}`);
  }

  // 4. Its name and description on the App Store.
  const names = await all(`/v1/subscriptions/${subscription.id}/subscriptionLocalizations`);
  if (!names.items.some((item) => item.attributes.locale === "en-US")) {
    await api("POST", "/v1/subscriptionLocalizations", {
      data: {
        type: "subscriptionLocalizations",
        attributes: { locale: "en-US", name: plan.name, description: plan.description },
        relationships: { subscription: relation("subscriptions", subscription.id) },
      },
    });
    console.log(`  ✔ name and description`);
  }

  // 5. Sold in every territory, and in new ones as they come.
  try {
    await api("POST", "/v1/subscriptionAvailabilities", {
      data: {
        type: "subscriptionAvailabilities", attributes: { availableInNewTerritories: true },
        relationships: {
          subscription: relation("subscriptions", subscription.id),
          availableTerritories: { data: territories.map((id) => ({ type: "territories", id })) },
        },
      },
    });
    console.log(`  ✔ available in ${territories.length} territories`);
  } catch (error) {
    console.log(`  · availability: ${error.message}`);
  }

  // 6. The US price, and Apple's equalized prices everywhere else.
  const existing = await api("GET", `/v1/subscriptions/${subscription.id}/prices?limit=1`);
  if (existing.data.length > 0) {
    console.log("  ✔ prices already set");
    continue;
  }
  const usPoints = await all(`/v1/subscriptions/${subscription.id}/pricePoints?filter[territory]=USA&limit=200`);
  const usPoint = usPoints.items.find((point) => point.attributes.customerPrice === plan.usd);
  if (!usPoint) throw new Error(`No US price point at $${plan.usd}`);
  const equalized = await all(`/v1/subscriptionPricePoints/${usPoint.id}/equalizations?include=territory&limit=200`);
  const points = [{ id: usPoint.id, territory: "USA" }, ...equalized.items.map((point) => ({
    id: point.id, territory: point.relationships?.territory?.data?.id,
  }))].filter((point) => point.territory);
  let created = 0;
  for (let index = 0; index < points.length; index += 8) {
    await Promise.all(points.slice(index, index + 8).map(async (point) => {
      await api("POST", "/v1/subscriptionPrices", {
        data: {
          type: "subscriptionPrices", attributes: { preserveCurrentPrice: false },
          relationships: {
            subscription: relation("subscriptions", subscription.id),
            subscriptionPricePoint: relation("subscriptionPricePoints", point.id),
            territory: relation("territories", point.territory),
          },
        },
      });
      created += 1;
    }));
  }
  console.log(`  ✔ $${plan.usd} in the US and ${created - 1} equalized prices`);
}

// 7. Apple's server notifications (V2) to the function that updates the account.
await api("PATCH", `/v1/apps/${app.id}`, {
  data: {
    type: "apps", id: app.id,
    attributes: {
      subscriptionStatusUrl: NOTIFICATIONS_URL, subscriptionStatusUrlVersion: "V2",
      subscriptionStatusUrlForSandbox: NOTIFICATIONS_URL, subscriptionStatusUrlVersionForSandbox: "V2",
    },
  },
});
console.log(`✔ server notifications → ${NOTIFICATIONS_URL}`);
console.log("Next, in App Store Connect: the Paid Apps agreement, and a review screenshot per subscription.");
