// Sign in with Apple's token revocation, which Apple requires when an account that signed in
// with Apple is deleted. The app gets a fresh authorization code from Apple as the user confirms
// the deletion; it's exchanged for a refresh token, which is then revoked. The client secret is a
// short-lived JWT signed with the Sign in with Apple key.
// Env: APPLE_SIGNIN_KEY_ID, APPLE_SIGNIN_PRIVATE_KEY (the .p8, PEM), APPLE_TEAM_ID (default the
// Murmur team) and APPLE_SIGNIN_CLIENT_ID (default the app's bundle ID). Without the key nothing
// is revoked.

export interface AppleSignInConfig {
  teamId: string;
  keyId: string;
  /** PKCS #8 PEM, as Apple's .p8 file. */
  privateKey: string;
  clientId: string;
}

export function appleSignInConfig(env: { get(name: string): string | undefined } = Deno.env): AppleSignInConfig | null {
  const keyId = env.get("APPLE_SIGNIN_KEY_ID");
  const privateKey = env.get("APPLE_SIGNIN_PRIVATE_KEY");
  if (!keyId || !privateKey) return null;
  return {
    keyId,
    privateKey,
    teamId: env.get("APPLE_TEAM_ID") ?? "DMC53DDZQV",
    clientId: env.get("APPLE_SIGNIN_CLIENT_ID") ?? "com.antonmironenko.murmur",
  };
}

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const text = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));

/** The ES256 client secret Apple's /auth endpoints take, valid for five minutes. */
export async function clientSecret(config: AppleSignInConfig, now = Date.now()): Promise<string> {
  const pem = config.privateKey.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (character) => character.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const issuedAt = Math.floor(now / 1000);
  const signingInput = `${text({ alg: "ES256", kid: config.keyId })}.${text({
    iss: config.teamId, iat: issuedAt, exp: issuedAt + 300, aud: "https://appleid.apple.com", sub: config.clientId,
  })}`;
  // WebCrypto signs ECDSA as r || s, which is what a JWS needs.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(signingInput));
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

export type Revocation = "revoked" | "exchange_failed" | "revoke_failed";

/** Exchanges `code` for a refresh token and revokes it. Never throws: deletion goes on regardless. */
export async function revokeWithCode(
  code: string, config: AppleSignInConfig, options: { fetcher?: typeof fetch; signal?: AbortSignal } = {},
): Promise<Revocation> {
  const fetcher = options.fetcher ?? fetch;
  try {
    const secret = await clientSecret(config);
    const exchange = await fetcher("https://appleid.apple.com/auth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: config.clientId, client_secret: secret, code, grant_type: "authorization_code",
      }),
      signal: options.signal,
    });
    const tokens = await exchange.json().catch(() => null) as { refresh_token?: string } | null;
    if (!exchange.ok || !tokens?.refresh_token) return "exchange_failed";
    const revoke = await fetcher("https://appleid.apple.com/auth/revoke", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: config.clientId, client_secret: secret, token: tokens.refresh_token,
        token_type_hint: "refresh_token",
      }),
      signal: options.signal,
    });
    return revoke.ok ? "revoked" : "revoke_failed";
  } catch {
    return "exchange_failed";
  }
}
