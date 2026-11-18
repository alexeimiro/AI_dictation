// App Store signed data (a JWS): its ES256 signature and its certificate chain up to Apple's
// pinned roots, checked the way Apple's app-store-server-library checks them offline
// (SignedDataVerifier with enableOnlineChecks false). That library can't run on Supabase's edge
// runtime: it needs node:crypto's X509Certificate (toString, verify, infoAccess), which the
// runtime doesn't implement, so it refused every purchase and every notification.
//
// Here the certificates are read by a small strict DER reader (below) and every signature is
// checked with WebCrypto. No general-purpose ASN.1 library sees the bytes: the x5c certificates
// arrive from anyone (the notification endpoint is public), and one such library (jsrsasign)
// loops forever on a 16-byte certificate.
//
// The chain, as Apple's library checks it:
// - the header's alg is ES256 and its x5c holds exactly three certificates (leaf, intermediate,
//   root); the third isn't trusted: the intermediate must be signed by one of the pinned roots,
//   whose subject is its issuer;
// - the leaf is signed by the intermediate, whose subject is its issuer;
// - the intermediate is a CA and carries Apple's WWDR marker (1.2.840.113635.100.6.2.1), the
//   leaf the App Store receipt-signing marker (1.2.840.113635.100.6.11.1);
// - all three are valid on the payload's signedDate (now when it has none), give or take a
//   minute;
// - the signature is made by the leaf's P-256 key.
// What the payload says (bundle, environment, app) is the caller's to check.
import { Buffer } from "node:buffer";
import { createPublicKey, verify as nodeVerify } from "node:crypto";

/** Why signed data was refused, for the logs: "VerificationError: chain_root". */
export class VerificationError extends Error {
  constructor(reason: string) {
    super(reason);
    this.name = "VerificationError";
  }
}

/** Apple's library allows a certificate's dates this much leeway either way. */
const MAX_SKEW = 60_000;
/** Apple's certificates are about 1 KB; nothing near this is a real one. */
const MAX_CERTIFICATE_BYTES = 8_192;

const OID = {
  leafMarker: oid("1.2.840.113635.100.6.11.1"),
  intermediateMarker: oid("1.2.840.113635.100.6.2.1"),
  basicConstraints: oid("2.5.29.19"),
  ecPublicKey: oid("1.2.840.10045.2.1"),
  p256: oid("1.2.840.10045.3.1.7"),
  p384: oid("1.3.132.0.34"),
  rsaEncryption: oid("1.2.840.113549.1.1.1"),
};

/**
 * The certificate signatures a pinned root or an Apple intermediate can make. Others (SHA-1,
 * SHA-512, RSASSA-PSS) are refused on purpose: Apple's G2/G3 hierarchy uses none of them.
 */
const SIGNATURES: Record<string, { family: "ec" | "rsa"; hash: "SHA-256" | "SHA-384" }> = {
  [oid("1.2.840.10045.4.3.2")]: { family: "ec", hash: "SHA-256" },
  [oid("1.2.840.10045.4.3.3")]: { family: "ec", hash: "SHA-384" },
  [oid("1.2.840.113549.1.1.11")]: { family: "rsa", hash: "SHA-256" },
  [oid("1.2.840.113549.1.1.12")]: { family: "rsa", hash: "SHA-384" },
};

/** What the checks need from a certificate. Names and OIDs are DER, as hex. */
interface Certificate {
  /** The signed part: the bytes the issuer's signature covers. */
  tbs: Uint8Array;
  signatureAlgorithm: string;
  signature: Uint8Array;
  issuer: string;
  subject: string;
  notBefore: number;
  notAfter: number;
  spki: Uint8Array;
  key: { family: "ec"; curve: "P-256" | "P-384" } | { family: "rsa" } | null;
  /** extnID → extnValue's contents. */
  extensions: Map<string, Uint8Array>;
}

/**
 * Checks App Store signed data against `roots` (DER certificates, base64) and returns its payload,
 * or throws `VerificationError`. `now` is for signed data that has no signedDate.
 */
export function appleJwsVerifier(
  roots: readonly string[],
  now: () => number = Date.now,
): (jws: string) => Promise<Record<string, unknown>> {
  const trusted = roots.map((root) => certificate(root, "root"));
  if (trusted.length === 0) throw new Error("no root certificates");
  return async (jws) => {
    if (typeof jws !== "string") throw new VerificationError("not_a_jws");
    const parts = jws.split(".");
    if (parts.length !== 3 || !parts.every((part) => /^[A-Za-z0-9_-]+$/.test(part))) {
      throw new VerificationError("not_a_jws");
    }
    const [encodedHeader, encodedPayload, encodedSignature] = parts;
    const header = object(encodedHeader, "header");
    if (header.alg !== "ES256") throw new VerificationError("algorithm");
    const x5c = header.x5c;
    if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((entry) => typeof entry === "string")) {
      throw new VerificationError("chain_length");
    }
    const leaf = certificate(x5c[0], "leaf");
    const intermediate = certificate(x5c[1], "intermediate");
    const payload = object(encodedPayload, "payload");

    let root: Certificate | undefined;
    for (const candidate of trusted) {
      if (intermediate.issuer === candidate.subject && await signs(candidate, intermediate)) {
        root = candidate;
        break;
      }
    }
    if (!root) throw new VerificationError("chain_root");
    if (leaf.issuer !== intermediate.subject || !await signs(intermediate, leaf)) {
      throw new VerificationError("chain_leaf");
    }
    if (!isCA(intermediate)) throw new VerificationError("chain_ca");
    if (!leaf.extensions.has(OID.leafMarker) || !intermediate.extensions.has(OID.intermediateMarker)) {
      throw new VerificationError("chain_marker");
    }
    const signedDate = payload.signedDate;
    const at = typeof signedDate === "number" && Number.isFinite(signedDate) ? signedDate : now();
    for (const each of [leaf, intermediate, root]) {
      if (each.notBefore > at + MAX_SKEW || each.notAfter < at - MAX_SKEW) {
        throw new VerificationError("certificate_dates");
      }
    }

    if (leaf.key?.family !== "ec" || leaf.key.curve !== "P-256") throw new VerificationError("leaf_key");
    let key: CryptoKey;
    try {
      key = await crypto.subtle.importKey("spki", buffer(leaf.spki), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    } catch {
      throw new VerificationError("leaf_key");
    }
    // Raw r‖s, as JWS has it: a DER-encoded signature is refused.
    const signature = base64UrlBytes(encodedSignature);
    const signed = new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`);
    if (signature.length !== 64 || !await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, signed)) {
      throw new VerificationError("signature");
    }
    return payload;
  };
}

/** Whether `issuer`'s key made `subject`'s signature over its signed part. */
async function signs(issuer: Certificate, subject: Certificate): Promise<boolean> {
  const scheme = SIGNATURES[subject.signatureAlgorithm];
  const key = issuer.key;
  if (!scheme || !key || scheme.family !== key.family) return false;
  try {
    if (key.family === "ec") {
      const raw = rawEcdsaSignature(subject.signature, key.curve === "P-256" ? 32 : 48);
      if (!raw) return false;
      if (scheme.hash !== (key.curve === "P-256" ? "SHA-256" : "SHA-384")) {
        // The edge runtime's WebCrypto (Deno 2.1) only pairs P-256 with SHA-256 and P-384 with SHA-384
        // ("Not implemented" otherwise), and Apple Root CA - G3 (P-384) has signed intermediates with
        // SHA-256: node:crypto checks those pairs (its verify works there; its X509Certificate doesn't).
        const publicKey = createPublicKey({ key: Buffer.from(issuer.spki), format: "der", type: "spki" });
        return nodeVerify(scheme.hash === "SHA-256" ? "sha256" : "sha384", subject.tbs, publicKey, subject.signature);
      }
      const imported = await crypto.subtle.importKey(
        "spki", buffer(issuer.spki), { name: "ECDSA", namedCurve: key.curve }, false, ["verify"]);
      return await crypto.subtle.verify({ name: "ECDSA", hash: scheme.hash }, imported, buffer(raw), buffer(subject.tbs));
    }
    const imported = await crypto.subtle.importKey(
      "spki", buffer(issuer.spki), { name: "RSASSA-PKCS1-v1_5", hash: scheme.hash }, false, ["verify"]);
    return await crypto.subtle.verify("RSASSA-PKCS1-v1_5", imported, buffer(subject.signature), buffer(subject.tbs));
  } catch {
    return false;
  }
}

/** basicConstraints says cA TRUE (any non-zero byte, as OpenSSL reads it; DER writes 0xff). */
function isCA(cert: Certificate): boolean {
  const value = cert.extensions.get(OID.basicConstraints);
  if (!value) return false;
  try {
    const constraints = whole(value);
    const first = constraints.children[0];
    return constraints.tag === 0x30 && first?.tag === 0x01 && first.content.length === 1 && first.content[0] !== 0;
  } catch {
    return false;
  }
}

/** A DER ECDSA signature (SEQUENCE of two INTEGERs) as raw r‖s of `size` bytes each; null if malformed. */
function rawEcdsaSignature(der: Uint8Array, size: number): Uint8Array | null {
  let node: Node;
  try {
    node = whole(der);
  } catch {
    return null;
  }
  if (node.tag !== 0x30 || node.children.length !== 2) return null;
  const raw = new Uint8Array(size * 2);
  for (const [index, integer] of node.children.entries()) {
    let bytes = integer.content;
    if (integer.tag !== 0x02 || bytes.length === 0 || bytes[0] & 0x80) return null;
    if (bytes[0] === 0 && bytes.length > 1) {
      if (!(bytes[1] & 0x80)) return null; // a leading zero DER wouldn't write
      bytes = bytes.subarray(1);
    }
    if (bytes.length > size) return null;
    raw.set(bytes, index * size + size - bytes.length);
  }
  return raw;
}

// MARK: - Reading a certificate

/** A certificate from base64 DER, or `VerificationError("<role>_certificate")`. */
function certificate(base64: string, role: string): Certificate {
  try {
    if (!/^[A-Za-z0-9+/]+={0,2}$/.test(base64) || base64.length > MAX_CERTIFICATE_BYTES * 4 / 3 + 4) {
      throw new Error("not base64");
    }
    const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    return readCertificate(bytes);
  } catch {
    throw new VerificationError(`${role}_certificate`);
  }
}

/** RFC 5280's Certificate, strictly: anything unexpected throws. */
function readCertificate(bytes: Uint8Array): Certificate {
  const cert = whole(bytes);
  expect(cert.tag === 0x30 && cert.children.length === 3);
  const [tbs, outerAlgorithm, signatureValue] = cert.children;
  expect(tbs.tag === 0x30 && outerAlgorithm.tag === 0x30 && signatureValue.tag === 0x03);

  const fields = tbs.children;
  let at = 0;
  if (fields[at]?.tag === 0xa0) at++; // version
  expect(fields[at++]?.tag === 0x02); // serialNumber
  const algorithm = fields[at++];
  const issuer = fields[at++];
  const validity = fields[at++];
  const subject = fields[at++];
  const spki = fields[at++];
  expect(algorithm?.tag === 0x30 && issuer?.tag === 0x30 && validity?.tag === 0x30 && subject?.tag === 0x30 &&
    spki?.tag === 0x30);
  // The algorithm inside the signed part decides; the unsigned copy outside must say the same.
  expect(hex(algorithm.der) === hex(outerAlgorithm.der));
  const algorithmId = algorithm.children[0];
  expect(algorithmId?.tag === 0x06);
  if (fields[at]?.tag === 0x81) at++; // issuerUniqueID
  if (fields[at]?.tag === 0x82) at++; // subjectUniqueID
  const extensions = new Map<string, Uint8Array>();
  if (fields[at]?.tag === 0xa3) {
    const list = fields[at++].children;
    expect(list.length === 1 && list[0].tag === 0x30);
    for (const extension of list[0].children) {
      const [id, ...rest] = extension.children;
      const value = rest[rest.length - 1];
      expect(extension.tag === 0x30 && id?.tag === 0x06 && value?.tag === 0x04 &&
        (rest.length === 1 || (rest.length === 2 && rest[0].tag === 0x01)));
      const key = hex(id.content);
      expect(!extensions.has(key));
      extensions.set(key, value.content);
    }
  }
  expect(at === fields.length);

  expect(validity.children.length === 2);
  const [notBefore, notAfter] = validity.children.map(time);
  // BIT STRING: a leading "unused bits" byte, which must be 0.
  expect(signatureValue.content.length > 1 && signatureValue.content[0] === 0);
  return {
    tbs: tbs.der,
    signatureAlgorithm: hex(algorithmId.content),
    signature: signatureValue.content.subarray(1),
    issuer: hex(issuer.der),
    subject: hex(subject.der),
    notBefore,
    notAfter,
    spki: spki.der,
    key: publicKey(spki),
    extensions,
  };
}

/** The key's kind from SubjectPublicKeyInfo; null for one no check here uses. */
function publicKey(spki: Node): Certificate["key"] {
  const [algorithm, bits] = spki.children;
  if (algorithm?.tag !== 0x30 || bits?.tag !== 0x03 || spki.children.length !== 2) return null;
  const [id, parameters] = algorithm.children;
  if (id?.tag !== 0x06) return null;
  const kind = hex(id.content);
  if (kind === OID.rsaEncryption) return { family: "rsa" };
  if (kind !== OID.ecPublicKey || parameters?.tag !== 0x06) return null;
  const curve = hex(parameters.content);
  if (curve === OID.p256) return { family: "ec", curve: "P-256" };
  if (curve === OID.p384) return { family: "ec", curve: "P-384" };
  return null;
}

/** UTCTime or GeneralizedTime, as RFC 5280 writes them (seconds, "Z"), in ms since 1970. */
function time(node: Node): number {
  const text = String.fromCharCode(...node.content);
  const match = node.tag === 0x17
    ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
    : node.tag === 0x18
    ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text)
    : null;
  expect(match !== null);
  const [year, month, day, hour, minute, second] = match!.slice(1).map(Number);
  const fullYear = node.tag === 0x17 ? (year >= 50 ? 1900 + year : 2000 + year) : year;
  const value = Date.UTC(fullYear, month - 1, day, hour, minute, second);
  const check = new Date(value);
  expect(check.getUTCMonth() === month - 1 && check.getUTCDate() === day && hour < 24 && minute < 60 && second < 60);
  return value;
}

// MARK: - A strict DER reader

/**
 * One DER element. It walks forward only: every length must be definite, minimally written and
 * inside its parent, a constructed element's children must fill it exactly, and nesting is
 * bounded, so no input can make it loop, go back or read past the end.
 */
interface Node {
  tag: number;
  /** The whole element, header included. */
  der: Uint8Array;
  content: Uint8Array;
  children: Node[];
}

const MAX_DEPTH = 16;

/** `bytes` as exactly one element, with nothing after it. */
function whole(bytes: Uint8Array): Node {
  const node = element(bytes, 0, bytes.length, 0);
  expect(node.der.length === bytes.length);
  return node;
}

function element(bytes: Uint8Array, start: number, limit: number, depth: number): Node {
  expect(depth <= MAX_DEPTH && start + 2 <= limit);
  const tag = bytes[start];
  expect((tag & 0x1f) !== 0x1f); // multi-byte tags don't occur in a certificate
  let length = bytes[start + 1];
  let offset = start + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    expect(count >= 1 && count <= 3 && offset + count <= limit && bytes[offset] !== 0);
    length = 0;
    for (let index = 0; index < count; index++) length = length * 256 + bytes[offset++];
    expect(length >= 0x80);
  }
  const end = offset + length;
  expect(end <= limit);
  const children: Node[] = [];
  if (tag & 0x20) {
    let next = offset;
    while (next < end) {
      const child = element(bytes, next, end, depth + 1);
      children.push(child);
      next += child.der.length;
    }
  }
  return { tag, der: bytes.subarray(start, end), content: bytes.subarray(offset, end), children };
}

function expect(condition: boolean): asserts condition {
  if (!condition) throw new Error("malformed");
}

// MARK: - Encodings

/** A dotted OID as the hex of its DER contents. */
function oid(dotted: string): string {
  const [first, second, ...rest] = dotted.split(".").map(Number);
  const bytes = [first * 40 + second];
  for (const arc of rest) {
    const groups = [arc & 0x7f];
    for (let value = Math.floor(arc / 128); value > 0; value = Math.floor(value / 128)) groups.unshift((value & 0x7f) | 0x80);
    bytes.push(...groups);
  }
  return hex(Uint8Array.from(bytes));
}

/** A JWS segment's JSON object; `part` names it in the error. */
function object(segment: string, part: string): Record<string, unknown> {
  try {
    const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(base64UrlBytes(segment)));
    if (value !== null && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
  } catch {
    // Falls through to the error below.
  }
  throw new VerificationError(`${part}_json`);
}

function base64UrlBytes(segment: string) {
  const base64 = segment.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(segment.length / 4) * 4, "=");
  try {
    return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
  } catch {
    throw new VerificationError("base64");
  }
}

/** A copy in its own ArrayBuffer, the type WebCrypto takes. */
function buffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.slice().buffer as ArrayBuffer;
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
