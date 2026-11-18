// Tests only: made-up certificate chains shaped like the App Store's (a root, a WWDR-like
// intermediate with Apple's marker, a signing leaf with the receipt-signing marker), and JWS
// signed with them, so every check in apple_jws.ts can be driven offline, on Deno and on the edge
// runtime. Nothing here is Apple's: a test root is trusted only where a test passes it in. Keys
// are made fresh on each run and never leave memory.
import jsrsasign from "npm:jsrsasign@11.1.0";

// deno-lint-ignore no-explicit-any
const J = jsrsasign as any;

const LEAF_MARKER = "1.2.840.113635.100.6.11.1";
const INTERMEDIATE_MARKER = "1.2.840.113635.100.6.2.1";
/** UTCTime, as certificates carry it. */
const FROM = "250101000000Z";
const UNTIL = "391231000000Z";

/** A root: what a verifier trusts (`certificate`, base64 DER) and what signs intermediates. */
export interface TestAuthority {
  certificate: string;
  subject: string;
  // deno-lint-ignore no-explicit-any
  key: any;
  /** How it signs: ECDSA P-384 like Apple Root CA - G3, or RSA like G2. */
  sigalg: string;
}

let serial = 1;

// deno-lint-ignore no-explicit-any
function issue(options: { issuer: string; subject: string; publicKey: any; signer: any; ca: boolean; marker?: string;
  from?: string; until?: string; sigalg?: string }): string {
  // deno-lint-ignore no-explicit-any
  const ext: any[] = [];
  if (options.ca) ext.push({ extname: "basicConstraints", critical: true, cA: true });
  if (options.marker) ext.push({ extname: options.marker, extn: "0500" });
  const certificate = new J.KJUR.asn1.x509.Certificate({
    version: 3,
    serial: { int: serial++ },
    issuer: { str: options.issuer },
    subject: { str: options.subject },
    notbefore: options.from ?? FROM,
    notafter: options.until ?? UNTIL,
    sbjpubkey: options.publicKey,
    ext,
    sigalg: options.sigalg ?? "SHA384withECDSA",
    cakey: options.signer,
  });
  return hexBase64(certificate.getEncodedHex());
}

/** A self-signed P-384 root named `subject`. */
export function testAuthority(subject = "/CN=Test Root CA - G3/O=Test Inc./C=US"): TestAuthority {
  const pair = J.KEYUTIL.generateKeypair("EC", "secp384r1");
  return {
    certificate: issue({ issuer: subject, subject, publicKey: pair.pubKeyObj, signer: pair.prvKeyObj, ca: true }),
    subject,
    key: pair.prvKeyObj,
    sigalg: "SHA384withECDSA",
  };
}

/** A self-signed RSA root, as Apple Root CA - G2 is (the key is made by WebCrypto: much faster). */
export async function testRsaAuthority(subject = "/CN=Test Root CA - G2/O=Test Inc./C=US"): Promise<TestAuthority> {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-384" },
    true, ["sign", "verify"]);
  const pem = (label: string, der: ArrayBuffer) =>
    `-----BEGIN ${label}-----\n${btoa(String.fromCharCode(...new Uint8Array(der)))}\n-----END ${label}-----`;
  const key = J.KEYUTIL.getKey(pem("PRIVATE KEY", await crypto.subtle.exportKey("pkcs8", pair.privateKey)));
  const publicKey = J.KEYUTIL.getKey(pem("PUBLIC KEY", await crypto.subtle.exportKey("spki", pair.publicKey)));
  return {
    certificate: issue({ issuer: subject, subject, publicKey, signer: key, ca: true, sigalg: "SHA384withRSA" }),
    subject,
    key,
    sigalg: "SHA384withRSA",
  };
}

/** What can be made wrong in a chain, each one thing a real App Store chain never is. */
export interface ChainFaults {
  /** The intermediate lacks Apple's WWDR marker. */
  intermediateUnmarked?: boolean;
  /** The leaf lacks the receipt-signing marker. */
  leafUnmarked?: boolean;
  /** The intermediate isn't a CA. */
  intermediateNotCA?: boolean;
  /** The intermediate names another issuer than the root, though the root signs it. */
  intermediateIssuer?: string;
  /** The leaf is signed by the root, not by the intermediate it names. */
  leafSignedByRoot?: boolean;
  /** The leaf's key is on P-384, which ES256 doesn't use. */
  leafOnP384?: boolean;
  /** The leaf's validity, as UTCTime. */
  leafFrom?: string;
  leafUntil?: string;
  /** How the root signs the intermediate, and the intermediate the leaf (jsrsasign names). */
  intermediateSigalg?: string;
  leafSigalg?: string;
  /** Replaces the intermediate's or the leaf's signature value with these bytes (hex). */
  intermediateSignature?: string;
  leafSignature?: string;
}

export interface TestChain {
  /** leaf, intermediate, root: what goes in the header's x5c. */
  x5c: string[];
  /** A JWS of `payload` with this chain, signed by the leaf (`header` adds to or replaces fields). */
  sign(payload: unknown, header?: Record<string, unknown>): string;
  /** The same, signed by another key than the leaf's. */
  signWithStrangerKey(payload: unknown): string;
}

/** A chain under `root`, with `faults` if any. */
export function testChain(root: TestAuthority, faults: ChainFaults = {}): TestChain {
  const intermediatePair = J.KEYUTIL.generateKeypair("EC", "secp384r1");
  const intermediateSubject = "/CN=Test Worldwide Developer Relations CA/OU=G6/O=Test Inc./C=US";
  const intermediate = issue({
    issuer: faults.intermediateIssuer ?? root.subject,
    subject: intermediateSubject,
    publicKey: intermediatePair.pubKeyObj,
    signer: root.key,
    ca: !faults.intermediateNotCA,
    marker: faults.intermediateUnmarked ? undefined : INTERMEDIATE_MARKER,
    sigalg: faults.intermediateSigalg ?? root.sigalg,
  });
  const leafPair = J.KEYUTIL.generateKeypair("EC", faults.leafOnP384 ? "secp384r1" : "secp256r1");
  const leaf = issue({
    issuer: intermediateSubject,
    subject: "/CN=Test Store Receipt Signing/O=Test Inc./C=US",
    publicKey: leafPair.pubKeyObj,
    signer: faults.leafSignedByRoot ? root.key : intermediatePair.prvKeyObj,
    ca: false,
    marker: faults.leafUnmarked ? undefined : LEAF_MARKER,
    from: faults.leafFrom,
    until: faults.leafUntil,
    sigalg: faults.leafSigalg,
  });
  const x5c = [
    faults.leafSignature === undefined ? leaf : withSignature(leaf, faults.leafSignature),
    faults.intermediateSignature === undefined ? intermediate : withSignature(intermediate, faults.intermediateSignature),
    root.certificate,
  ];
  // deno-lint-ignore no-explicit-any
  const jws = (payload: unknown, header: Record<string, unknown>, key: any) =>
    J.KJUR.jws.JWS.sign("ES256", JSON.stringify({ alg: "ES256", x5c, ...header }), JSON.stringify(payload), key);
  const stranger = J.KEYUTIL.generateKeypair("EC", "secp256r1").prvKeyObj;
  return {
    x5c,
    sign: (payload, header = {}) => jws(payload, header, leafPair.prvKeyObj),
    signWithStrangerKey: (payload) => jws(payload, {}, stranger),
  };
}

/** `certificate` with its signature value replaced by `signature` (hex). */
function withSignature(certificate: string, signature: string): string {
  const der = Array.from(atob(certificate), (char) => char.charCodeAt(0).toString(16).padStart(2, "0")).join("");
  const [tbs, algorithm] = J.ASN1HEX.getChildIdx(der, 0).slice(0, 2).map((index: number) => J.ASN1HEX.getTLV(der, index));
  return hexBase64(tlv("30", tbs + algorithm + tlv("03", "00" + signature)));
}

/** A DER element: tag, definite length, contents (all hex). */
export function tlv(tag: string, content: string): string {
  const length = content.length / 2;
  const hex = (value: number) => value.toString(16).padStart(2, "0");
  const encoded = length < 0x80
    ? hex(length)
    : length < 0x100
    ? `81${hex(length)}`
    : `82${hex(length >> 8)}${hex(length & 0xff)}`;
  return tag + encoded + content;
}

export function hexBase64(hex: string): string {
  return btoa(String.fromCharCode(...(hex.match(/../g) ?? []).map((pair) => parseInt(pair, 16))));
}
