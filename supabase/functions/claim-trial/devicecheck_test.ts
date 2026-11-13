import { assert, assertEquals } from "jsr:@std/assert@1";
import {
  authToken,
  DEVICECHECK_DEVELOPMENT,
  DEVICECHECK_PRODUCTION,
  deviceCheckConfig,
  type DeviceCheckConfig,
  deviceToken,
  markTrialUsed,
  queryTrialBit,
} from "../_shared/devicecheck.ts";

/** A throwaway P-256 key as Apple's .p8 is: PKCS #8 in PEM. */
async function testKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}

const decode = (part: string) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
const unbase64url = (part: string) =>
  Uint8Array.from(atob(part.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - part.length % 4) % 4)),
    (character) => character.charCodeAt(0));

const TOKEN = "AgAAAH4dSnA0aZx8Fv1oNlWb8w2s0vEXAMPLEdevicetokenbase64==";
const NOW = Date.UTC(2026, 10, 13, 8);

async function config(): Promise<DeviceCheckConfig> {
  const { pem } = await testKey();
  return { teamId: "TEAM", keyId: "KEY", privateKey: pem, host: DEVICECHECK_PRODUCTION };
}

/** Answers every request with `status` and `body`, and keeps what was sent. */
function apple(status: number, body: string | (() => never)) {
  const sent: { url: string; init: RequestInit }[] = [];
  const fetcher = ((url: string | URL | Request, init?: RequestInit) => {
    sent.push({ url: String(url), init: init ?? {} });
    if (typeof body === "function") body();
    return Promise.resolve(new Response(body as string, { status }));
  }) as typeof fetch;
  return { fetcher, sent };
}

Deno.test("no key, no check; Apple's two hosts only", () => {
  assertEquals(deviceCheckConfig(new Map()), null);
  assertEquals(deviceCheckConfig(new Map([["DEVICECHECK_KEY_ID", "K"]])), null);
  const env = new Map([["DEVICECHECK_KEY_ID", "K"], ["DEVICECHECK_PRIVATE_KEY", "pem"]]);
  assertEquals(deviceCheckConfig(env), { keyId: "K", privateKey: "pem", teamId: "DMC53DDZQV", host: DEVICECHECK_PRODUCTION });
  env.set("DEVICECHECK_HOST", DEVICECHECK_DEVELOPMENT);
  assertEquals(deviceCheckConfig(env)?.host, DEVICECHECK_DEVELOPMENT);
  env.set("DEVICECHECK_HOST", "https://example.com");
  assertEquals(deviceCheckConfig(env)?.host, DEVICECHECK_PRODUCTION);
});

Deno.test("a token is base64 on one line, or nothing", () => {
  assertEquals(deviceToken(TOKEN), TOKEN);
  assertEquals(deviceToken(undefined), null);
  assertEquals(deviceToken(42), null);
  assertEquals(deviceToken("short"), null);
  assertEquals(deviceToken(TOKEN.slice(0, 20) + "\n" + TOKEN.slice(20)), null);
  assertEquals(deviceToken(TOKEN + " "), null);
  assertEquals(deviceToken("A".repeat(16_385)), null);
});

Deno.test("the auth token is an ES256 JWT with the key, the team and the time", async () => {
  const { pem, publicKey } = await testKey();
  const jwt = await authToken({ teamId: "TEAM", keyId: "KEY", privateKey: pem, host: DEVICECHECK_PRODUCTION }, NOW);
  const [header, payload, signature] = jwt.split(".");
  assertEquals(decode(header), { alg: "ES256", kid: "KEY" });
  assertEquals(decode(payload), { iss: "TEAM", iat: NOW / 1000 });
  assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, unbase64url(signature),
    new TextEncoder().encode(`${header}.${payload}`)));
});

Deno.test("a query sends the token, a transaction id and the time, with the auth token", async () => {
  const { fetcher, sent } = apple(200, `{"bit0":false,"bit1":false,"last_update_time":"2026-11"}`);
  assertEquals(await queryTrialBit(TOKEN, await config(), { fetcher, now: NOW }), { kind: "clear" });
  assertEquals(sent.length, 1);
  assertEquals(sent[0].url, `${DEVICECHECK_PRODUCTION}/v1/query_two_bits`);
  assertEquals(sent[0].init.method, "POST");
  const headers = new Headers(sent[0].init.headers);
  assert(headers.get("Authorization")?.startsWith("Bearer ey"));
  const body = JSON.parse(String(sent[0].init.body));
  assertEquals(body.device_token, TOKEN);
  assertEquals(body.timestamp, NOW);
  assert(/^[0-9a-f-]{36}$/.test(body.transaction_id));
});

Deno.test("bit 0 set: the iPhone has had its trial", async () => {
  const { fetcher } = apple(200, `{"bit0":true,"bit1":false,"last_update_time":"2026-10"}`);
  assertEquals(await queryTrialBit(TOKEN, await config(), { fetcher }), { kind: "set", lastUpdate: "2026-10" });
});

Deno.test("bits never set: 200 with text instead of JSON, in either wording", async () => {
  for (const text of ["Bit State Not Found", "Failed to find bit state"]) {
    const { fetcher } = apple(200, text);
    assertEquals(await queryTrialBit(TOKEN, await config(), { fetcher }), { kind: "clear" }, text);
  }
});

Deno.test("only a bad device token is the caller's fault", async () => {
  const bad = apple(400, "Missing or incorrectly formatted device token payload");
  assertEquals(await queryTrialBit(TOKEN, await config(), { fetcher: bad.fetcher }), { kind: "bad_token" });
  const badToken = apple(400, "Bad Device Token");
  assertEquals(await queryTrialBit(TOKEN, await config(), { fetcher: badToken.fetcher }), { kind: "bad_token" });
  for (const [status, text] of [[400, "Bad Timestamp"], [401, "Unable to verify authorization token"],
    [403, "Forbidden"], [429, "Too Many Requests"], [500, "Server Error"], [503, "Service Unavailable"],
    [200, "something new"]] as const) {
    const { fetcher } = apple(status, text);
    const answer = await queryTrialBit(TOKEN, await config(), { fetcher });
    assertEquals(answer.kind, "unavailable", `${status} ${text}`);
    assert(answer.kind === "unavailable" && answer.status === status);
  }
});

Deno.test("no network is no answer, never a throw", async () => {
  const { fetcher } = apple(0, () => { throw new TypeError("network down"); });
  const answer = await queryTrialBit(TOKEN, await config(), { fetcher });
  assertEquals(answer.kind, "unavailable");
  assert(answer.kind === "unavailable" && answer.status === null && answer.detail.includes("network down"));
});

Deno.test("marking sets bit 0 only, and says whether Apple took it", async () => {
  const ok = apple(200, "");
  assertEquals(await markTrialUsed(TOKEN, await config(), { fetcher: ok.fetcher, now: NOW }), true);
  assertEquals(ok.sent[0].url, `${DEVICECHECK_PRODUCTION}/v1/update_two_bits`);
  const body = JSON.parse(String(ok.sent[0].init.body));
  assertEquals(body.device_token, TOKEN);
  assertEquals(body.bit0, true);
  assertEquals("bit1" in body, false);
  assertEquals(body.timestamp, NOW);

  assertEquals(await markTrialUsed(TOKEN, await config(), { fetcher: apple(500, "Server Error").fetcher }), false);
  assertEquals(await markTrialUsed(TOKEN, await config(),
    { fetcher: apple(0, () => { throw new TypeError("offline"); }).fetcher }), false);
});

Deno.test("the development host is used when configured", async () => {
  const { fetcher, sent } = apple(200, "Bit State Not Found");
  await queryTrialBit(TOKEN, { ...(await config()), host: DEVICECHECK_DEVELOPMENT }, { fetcher });
  assertEquals(sent[0].url, `${DEVICECHECK_DEVELOPMENT}/v1/query_two_bits`);
});
