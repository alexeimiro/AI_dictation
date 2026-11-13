// Apple's DeviceCheck: two bits that Apple keeps per iPhone for this developer team, which only our
// server can read and write. Murmur uses bit 0 for "this iPhone has had its free trial"
// (claim-trial, _shared/trial.ts). The app sends an ephemeral token from DCDevice; Apple tells us
// nothing else about the device, and the token isn't kept.
// Env: DEVICECHECK_KEY_ID and DEVICECHECK_PRIVATE_KEY (a key with DeviceCheck ticked; the .p8 as
// PEM), APPLE_TEAM_ID (default the Murmur team), DEVICECHECK_HOST (default production; Apple's
// development host keeps bits only for a while and is for tests).

export const DEVICECHECK_PRODUCTION = "https://api.devicecheck.apple.com";
export const DEVICECHECK_DEVELOPMENT = "https://api.development.devicecheck.apple.com";

export interface DeviceCheckConfig {
  teamId: string;
  keyId: string;
  /** PKCS #8 PEM, as Apple's .p8 file. */
  privateKey: string;
  host: string;
}

export function deviceCheckConfig(env: { get(name: string): string | undefined } = Deno.env): DeviceCheckConfig | null {
  const keyId = env.get("DEVICECHECK_KEY_ID");
  const privateKey = env.get("DEVICECHECK_PRIVATE_KEY");
  if (!keyId || !privateKey) return null;
  return {
    keyId,
    privateKey,
    teamId: env.get("APPLE_TEAM_ID") ?? "DMC53DDZQV",
    // Only Apple's two hosts: a token never goes anywhere else.
    host: env.get("DEVICECHECK_HOST") === DEVICECHECK_DEVELOPMENT ? DEVICECHECK_DEVELOPMENT : DEVICECHECK_PRODUCTION,
  };
}

/** A token as DCDevice makes it: base64 on one line. Anything else is refused before Apple sees it. */
export function deviceToken(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return value.length >= 16 && value.length <= 16_384 && /^[A-Za-z0-9+/]+={0,2}$/.test(value) ? value : null;
}

const base64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const encoded = (value: unknown) => base64url(new TextEncoder().encode(JSON.stringify(value)));

/** The ES256 JWT DeviceCheck takes, made as for APNs (kid, iss, iat). Apple accepts it for an hour. */
export async function authToken(config: DeviceCheckConfig, now = Date.now()): Promise<string> {
  const pem = config.privateKey.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (character) => character.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signingInput = `${encoded({ alg: "ES256", kid: config.keyId })}.${encoded({
    iss: config.teamId, iat: Math.floor(now / 1000),
  })}`;
  // WebCrypto signs ECDSA as r || s, which is what a JWS needs.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(signingInput));
  return `${signingInput}.${base64url(new Uint8Array(signature))}`;
}

/** What Apple's bit 0 says about the iPhone that made the token. */
export type TrialBit =
  /** It has had a Murmur trial. */
  | { kind: "set"; lastUpdate: string | null }
  /** Never set (or set back): its first trial is still to come. */
  | { kind: "clear" }
  /** Apple refused the token: it isn't from an iPhone running Murmur, or it was mangled on the way. */
  | { kind: "bad_token" }
  /** No answer to go by: our key, Apple or the network. */
  | { kind: "unavailable"; status: number | null; detail: string };

export interface DeviceCheckOptions {
  fetcher?: typeof fetch;
  signal?: AbortSignal;
  now?: number;
}

async function post(path: string, body: Record<string, unknown>, config: DeviceCheckConfig,
  options: DeviceCheckOptions): Promise<{ status: number; text: string }> {
  const now = options.now ?? Date.now();
  const response = await (options.fetcher ?? fetch)(`${config.host}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${await authToken(config, now)}`, "Content-Type": "application/json" },
    body: JSON.stringify({ ...body, transaction_id: crypto.randomUUID(), timestamp: now }),
    signal: options.signal,
  });
  return { status: response.status, text: await response.text() };
}

/** Apple answers 400 for several mistakes; only a bad device token is the caller's. */
const isBadToken = (text: string) => /device token/i.test(text);

/** Asks Apple for the iPhone's bit 0. Never throws. */
export async function queryTrialBit(token: string, config: DeviceCheckConfig,
  options: DeviceCheckOptions = {}): Promise<TrialBit> {
  try {
    const { status, text } = await post("/v1/query_two_bits", { device_token: token }, config, options);
    if (status === 200) {
      const bits = parseBits(text);
      if (bits) return bits.bit0 ? { kind: "set", lastUpdate: bits.lastUpdate } : { kind: "clear" };
      // A device whose bits were never set: 200 with this text instead of JSON.
      if (/bit state not found|failed to find bit state/i.test(text)) return { kind: "clear" };
      return { kind: "unavailable", status, detail: text.slice(0, 120) };
    }
    if (status === 400 && isBadToken(text)) return { kind: "bad_token" };
    return { kind: "unavailable", status, detail: text.slice(0, 120) };
  } catch (error) {
    return { kind: "unavailable", status: null, detail: String(error).slice(0, 120) };
  }
}

/** Sets bit 0: this iPhone has had its trial. Bit 1 isn't sent, so Apple keeps it as it is. Never throws. */
export async function markTrialUsed(token: string, config: DeviceCheckConfig,
  options: DeviceCheckOptions = {}): Promise<boolean> {
  try {
    const { status } = await post("/v1/update_two_bits", { device_token: token, bit0: true }, config, options);
    return status === 200;
  } catch {
    return false;
  }
}

function parseBits(text: string): { bit0: boolean; lastUpdate: string | null } | null {
  try {
    const value = JSON.parse(text) as { bit0?: unknown; last_update_time?: unknown } | null;
    if (typeof value?.bit0 !== "boolean") return null;
    return { bit0: value.bit0, lastUpdate: typeof value.last_update_time === "string" ? value.last_update_time : null };
  } catch {
    return null;
  }
}
