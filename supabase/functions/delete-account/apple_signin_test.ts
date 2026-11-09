import { assert, assertEquals } from "jsr:@std/assert@1";
import { appleSignInConfig, clientSecret, revokeWithCode } from "../_shared/apple_signin.ts";

/** A throwaway P-256 key as Apple's .p8 is: PKCS #8 in PEM. */
async function testKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: pair.publicKey };
}

const decode = (part: string) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));

Deno.test("no key, no revocation", () => {
  assertEquals(appleSignInConfig(new Map()), null);
  const config = appleSignInConfig(new Map([["APPLE_SIGNIN_KEY_ID", "ABC123"], ["APPLE_SIGNIN_PRIVATE_KEY", "pem"]]));
  assertEquals(config?.teamId, "DMC53DDZQV");
  assertEquals(config?.clientId, "com.antonmironenko.murmur");
});

Deno.test("the client secret is an ES256 JWT for Apple, signed with the key", async () => {
  const { pem, publicKey } = await testKey();
  const config = { teamId: "TEAM", keyId: "KEY", privateKey: pem, clientId: "com.example.app" };
  const now = Date.UTC(2026, 10, 10);
  const jwt = await clientSecret(config, now);
  const [header, payload, signature] = jwt.split(".");
  assertEquals(decode(header), { alg: "ES256", kid: "KEY" });
  assertEquals(decode(payload), {
    iss: "TEAM", iat: now / 1000, exp: now / 1000 + 300, aud: "https://appleid.apple.com", sub: "com.example.app",
  });
  const raw = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/").padEnd(88, "=")), (c) => c.charCodeAt(0));
  assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, raw,
    new TextEncoder().encode(`${header}.${payload}`)));
});

Deno.test("the code is exchanged, then its refresh token revoked", async () => {
  const { pem } = await testKey();
  const config = { teamId: "TEAM", keyId: "KEY", privateKey: pem, clientId: "com.example.app" };
  const calls: [string, URLSearchParams][] = [];
  const fetcher = ((url: string, init: RequestInit) => {
    calls.push([url, init.body as URLSearchParams]);
    return Promise.resolve(url.endsWith("/token")
      ? Response.json({ access_token: "a", refresh_token: "r-123" })
      : new Response(null, { status: 200 }));
  }) as unknown as typeof fetch;
  assertEquals(await revokeWithCode("code-1", config, { fetcher }), "revoked");
  assertEquals(calls.map(([url]) => url), ["https://appleid.apple.com/auth/token", "https://appleid.apple.com/auth/revoke"]);
  assertEquals(calls[0][1].get("code"), "code-1");
  assertEquals(calls[1][1].get("token"), "r-123");
  assertEquals(calls[1][1].get("token_type_hint"), "refresh_token");
});

Deno.test("a code Apple refuses is reported, never thrown", async () => {
  const { pem } = await testKey();
  const config = { teamId: "TEAM", keyId: "KEY", privateKey: pem, clientId: "com.example.app" };
  const refused = (() => Promise.resolve(Response.json({ error: "invalid_grant" }, { status: 400 }))) as unknown as typeof fetch;
  assertEquals(await revokeWithCode("old", config, { fetcher: refused }), "exchange_failed");
  const offline = (() => Promise.reject(new TypeError("offline"))) as unknown as typeof fetch;
  assertEquals(await revokeWithCode("old", config, { fetcher: offline }), "exchange_failed");
});
