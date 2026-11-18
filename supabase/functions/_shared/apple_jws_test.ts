// deno test --allow-env --allow-read supabase/functions/_shared/apple_jws_test.ts
// With APPLE_NOTIFICATION_FIXTURE=<file> (a JSON array of real App Store notifications, as
// signedPayload strings or { signedPayload } objects, kept out of git: they carry an account
// token), Apple's own signed data goes through the real roots too.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { appleJwsVerifier, VerificationError } from "./apple_jws.ts";
import { APP_STORE, appleVerifier, createNotificationHandler, createPurchaseHandler, type EntitlementUpdate } from "./app_store.ts";
import { hexBase64, testAuthority, testChain, testRsaAuthority, tlv } from "./apple_test_chain.ts";

const SIGNED = Date.UTC(2026, 10, 18, 12);
const DAY = 86_400_000;
const root = testAuthority();
const chain = testChain(root);
const verify = appleJwsVerifier([root.certificate]);

const transaction = {
  transactionId: "2000001000000002",
  originalTransactionId: "2000001000000001",
  bundleId: APP_STORE.bundleId,
  productId: APP_STORE.products[0],
  purchaseDate: SIGNED,
  expiresDate: SIGNED + 30 * DAY,
  type: "Auto-Renewable Subscription",
  appAccountToken: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
  environment: "Production",
  signedDate: SIGNED,
  storefront: "RUS",
  price: 899000,
  currency: "RUB",
};

async function refusal(jws: string, check = verify): Promise<string> {
  const error = await assertRejects(() => check(jws), VerificationError);
  return error.message;
}

/** `jws` with one character of its `part` (0 header, 1 payload, 2 signature) changed. */
function tampered(jws: string, part: number): string {
  const parts = jws.split(".");
  const at = Math.floor(parts[part].length / 2);
  parts[part] = parts[part].slice(0, at) + (parts[part][at] === "A" ? "B" : "A") + parts[part].slice(at + 1);
  return parts.join(".");
}

Deno.test("a JWS signed by a leaf that chains to a pinned root is read", async () => {
  const payload = { ...transaction, note: "UTF-8 survives: ₽ ✓" };
  assertEquals(await verify(chain.sign(payload)), payload);
});

Deno.test("any change to the header, payload or signature is refused", async () => {
  const jws = chain.sign(transaction);
  for (const part of [0, 1, 2]) {
    const reason = await refusal(tampered(jws, part)).catch(() => "threw something else");
    assert(reason !== "threw something else", `part ${part}`);
  }
  // A payload swapped whole, with the original signature, is refused by the signature check.
  const [header, , signature] = jws.split(".");
  const other = chain.sign({ ...transaction, expiresDate: SIGNED + 3650 * DAY }).split(".")[1];
  assertEquals(await refusal(`${header}.${other}.${signature}`), "signature");
});

Deno.test("only ES256 with exactly three certificates", async () => {
  const [, payload, signature] = chain.sign(transaction).split(".");
  for (const alg of ["none", "HS256", "ES384", "RS256", undefined]) {
    const header = base64Url(JSON.stringify({ alg, x5c: chain.x5c }));
    assertEquals(await refusal(`${header}.${payload}.${signature}`), "algorithm", String(alg));
  }
  assertEquals(await refusal(chain.sign(transaction, { x5c: chain.x5c.slice(0, 2) })), "chain_length");
  assertEquals(await refusal(chain.sign(transaction, { x5c: [...chain.x5c, chain.x5c[2]] })), "chain_length");
  assertEquals(await refusal(chain.sign(transaction, { x5c: "not a list" })), "chain_length");
  assertEquals(await refusal(chain.sign(transaction, { x5c: ["!!", chain.x5c[1], chain.x5c[2]] })), "leaf_certificate");
  assertEquals(await refusal(chain.sign(transaction, { x5c: [chain.x5c[0], "AAAA", chain.x5c[2]] })), "intermediate_certificate");
});

Deno.test("a chain to a root that isn't pinned is refused, even one with the same name", async () => {
  const impostor = testAuthority(root.subject);
  assertEquals(await refusal(testChain(impostor).sign(transaction)), "chain_root");
  // The third certificate in x5c is never trusted: the pinned root's own key must sign the intermediate.
  const swapped = testChain(impostor);
  assertEquals(await refusal(swapped.sign(transaction, { x5c: [swapped.x5c[0], swapped.x5c[1], root.certificate] })),
    "chain_root");
});

Deno.test("each link must sign the next, under the name it gives", async () => {
  assertEquals(await refusal(testChain(root, { leafSignedByRoot: true }).sign(transaction)), "chain_leaf");
  assertEquals(await refusal(testChain(root, { intermediateIssuer: "/CN=Someone Else/O=Test Inc./C=US" })
    .sign(transaction)), "chain_root");
  // A leaf from another chain under the same root doesn't belong to this intermediate.
  const other = testChain(root);
  assertEquals(await refusal(other.sign(transaction, { x5c: [other.x5c[0], chain.x5c[1], root.certificate] })),
    "chain_leaf");
  // The right chain, but signed by a key that isn't the leaf's.
  assertEquals(await refusal(chain.signWithStrangerKey(transaction)), "signature");
});

Deno.test("the intermediate must be a CA with Apple's marker, the leaf must carry its own", async () => {
  assertEquals(await refusal(testChain(root, { intermediateNotCA: true }).sign(transaction)), "chain_ca");
  assertEquals(await refusal(testChain(root, { intermediateUnmarked: true }).sign(transaction)), "chain_marker");
  assertEquals(await refusal(testChain(root, { leafUnmarked: true }).sign(transaction)), "chain_marker");
});

Deno.test("certificates must be valid on the signed date", async () => {
  const expired = testChain(root, { leafFrom: "250101000000Z", leafUntil: "260101000000Z" });
  assertEquals(await refusal(expired.sign(transaction)), "certificate_dates");
  // Signed while the leaf was valid: still good once it has expired, as with Apple's library offline.
  const earlier = { ...transaction, signedDate: Date.UTC(2025, 5, 1) };
  assertEquals((await verify(expired.sign(earlier))).signedDate, earlier.signedDate);
  const notYet = testChain(root, { leafFrom: "270101000000Z", leafUntil: "300101000000Z" });
  assertEquals(await refusal(notYet.sign(transaction)), "certificate_dates");
  // Without a signedDate the clock decides.
  const { signedDate: _, ...undated } = transaction;
  assertEquals(await refusal(expired.sign(undated), appleJwsVerifier([root.certificate], () => SIGNED)),
    "certificate_dates");
});

Deno.test("the leaf's key must be P-256 and the signature raw r‖s", async () => {
  const p384 = testChain(root, { leafOnP384: true });
  const reason = await refusal(p384.sign(transaction)).catch(() => "threw something else");
  assert(reason === "leaf_key" || reason === "signature", reason);
  // The same signature DER-encoded, as some libraries make it, isn't a JWS signature.
  const jws = chain.sign(transaction);
  const [header, payload, signature] = jws.split(".");
  const raw = Uint8Array.from(atob(signature.replace(/-/g, "+").replace(/_/g, "/")), (char) => char.charCodeAt(0));
  const der = derSignature(raw.slice(0, 32), raw.slice(32));
  const encoded = btoa(String.fromCharCode(...der)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  assertEquals(await refusal(`${header}.${payload}.${encoded}`), "signature");
});

Deno.test("what isn't a JWS is refused as such", async () => {
  for (const jws of ["", "a.b", "a.b.c.d", "a..c", "ab$.cd.ef", `${chain.sign(transaction)}.`]) {
    assertEquals(await refusal(jws), "not_a_jws", jws);
  }
  const [header, , signature] = chain.sign(transaction).split(".");
  assertEquals(await refusal(`${header}.${base64Url("[1,2]")}.${signature}`), "payload_json");
  assertEquals(await refusal(`${header}.${base64Url("not json")}.${signature}`), "payload_json");
  assertEquals(await refusal(`${base64Url("null")}.${base64Url("{}")}.${signature}`), "header_json");
  assertEquals(await refusal(42 as unknown as string), "not_a_jws");
});

Deno.test("every JWS is checked in full, also after the same chain passed", async () => {
  const fresh = appleJwsVerifier([root.certificate]);
  const short = testChain(root, { leafFrom: "250101000000Z", leafUntil: "270101000000Z" });
  assertEquals((await fresh(short.sign(transaction))).signedDate, SIGNED);
  assertEquals(await refusal(short.signWithStrangerKey(transaction), fresh), "signature");
  assertEquals(await refusal(tampered(short.sign(transaction), 2), fresh), "signature");
  assertEquals(await refusal(short.sign({ ...transaction, signedDate: Date.UTC(2028, 0, 1) }), fresh), "certificate_dates");
  // The remembered leaf under another intermediate is checked afresh.
  const other = testChain(root);
  assertEquals(await refusal(short.sign(transaction, { x5c: [short.x5c[0], other.x5c[1], root.certificate] }), fresh),
    "chain_leaf");
  // A chain that failed is never taken as good later.
  const unmarked = testChain(root, { leafUnmarked: true });
  for (let attempt = 0; attempt < 2; attempt++) assertEquals(await refusal(unmarked.sign(transaction), fresh), "chain_marker");
  // Many chains in a row: each is still checked properly.
  for (let count = 0; count < 18; count++) {
    const next = testChain(root);
    assertEquals((await fresh(next.sign(transaction))).signedDate, SIGNED);
    assertEquals(await refusal(next.signWithStrangerKey(transaction), fresh), "signature");
  }
});

/** Bytes that send a general ASN.1 walker (jsrsasign's) into an endless loop, from the review. */
const LOOP = "300a30080400048a00000000";

Deno.test("malformed certificates are refused at once, before any signature is checked", async () => {
  const [, payload, signature] = chain.sign(transaction).split(".");
  const withX5c = (x5c: string[]) => `${base64Url(JSON.stringify({ alg: "ES256", x5c }))}.${payload}.${signature}`;
  const started = Date.now();
  assertEquals(await refusal(withX5c([hexBase64(LOOP), chain.x5c[1], chain.x5c[2]])), "leaf_certificate");
  assertEquals(await refusal(withX5c([chain.x5c[0], hexBase64(LOOP), chain.x5c[2]])), "intermediate_certificate");
  const leafHex = Array.from(atob(chain.x5c[0]), (char) => char.charCodeAt(0).toString(16).padStart(2, "0")).join("");
  let nested = "0500";
  for (let depth = 0; depth < 20; depth++) nested = tlv("30", nested);
  const malformed: Record<string, string> = {
    "indefinite length": "308004000000",
    "four length bytes": "3084000000020400",
    "a short length written long": "3081020400",
    "a long length with a leading zero": "308200020400",
    "longer than the bytes": "30050400",
    "a child longer than its parent": "30020405",
    "bytes after the certificate": leafHex + "00",
    "a multi-byte tag": "1f810100",
    "nesting 20 deep": nested,
    "an empty sequence": "3000",
    "just a tag": "30",
  };
  for (const [name, hex] of Object.entries(malformed)) {
    assertEquals(await refusal(withX5c([hexBase64(hex), chain.x5c[1], chain.x5c[2]])), "leaf_certificate", name);
  }
  assertEquals(await refusal(withX5c([btoa("\0".repeat(9_000)), chain.x5c[1], chain.x5c[2]])), "leaf_certificate");
  assertEquals(await refusal(withX5c(["", chain.x5c[1], chain.x5c[2]])), "leaf_certificate");
  // Well-formed certificates whose signature value is those bytes: refused by the signature check.
  assertEquals(await refusal(testChain(root, { intermediateSignature: LOOP }).sign(transaction)), "chain_root");
  assertEquals(await refusal(testChain(root, { leafSignature: LOOP }).sign(transaction)), "chain_leaf");
  assertEquals(await refusal(testChain(root, { leafSignature: "" }).sign(transaction)), "leaf_certificate");
  assertEquals(await refusal(testChain(root, { leafSignature: "3006020100020100" }).sign(transaction)), "chain_leaf");
  assert(Date.now() - started < 5_000, `took ${Date.now() - started} ms`);
});

Deno.test("a chain under an RSA root, as Apple Root CA - G2 is, verifies; a forged link doesn't", async () => {
  const rsaRoot = await testRsaAuthority();
  const check = appleJwsVerifier([rsaRoot.certificate]);
  assertEquals((await check(testChain(rsaRoot).sign(transaction))).signedDate, SIGNED);
  assertEquals(await refusal(testChain(rsaRoot, { intermediateSignature: "00".repeat(256) }).sign(transaction), check),
    "chain_root");
  // An EC root with the RSA root's name doesn't vouch for it, nor the RSA root for an EC root's chain.
  assertEquals(await refusal(testChain(rsaRoot).sign(transaction), appleJwsVerifier([testAuthority(rsaRoot.subject).certificate])),
    "chain_root");
  assertEquals(await refusal(testChain(testAuthority(rsaRoot.subject)).sign(transaction), check), "chain_root");
});

Deno.test("P-384 keys signing with SHA-256, as Apple Root CA - G3 has, verify; changed ones don't", async () => {
  // The edge runtime's WebCrypto can't check these pairs: they go through node:crypto. Run this file in
  // the edge-runtime image (or Deno 2.1) as well, where that matters.
  for (const faults of [{ leafSigalg: "SHA256withECDSA" }, { intermediateSigalg: "SHA256withECDSA" },
    { leafSigalg: "SHA256withECDSA", intermediateSigalg: "SHA256withECDSA" }]) {
    const mixed = testChain(root, faults);
    assertEquals((await verify(mixed.sign(transaction))).signedDate, SIGNED, JSON.stringify(faults));
    const forged = faults.leafSigalg
      ? testChain(root, { ...faults, leafSignature: "3006020101020101" })
      : testChain(root, { ...faults, intermediateSignature: "3006020101020101" });
    assertEquals(await refusal(forged.sign(transaction)), faults.leafSigalg ? "chain_leaf" : "chain_root");
  }
  // A signature made with SHA-384 but labelled SHA-256 (and the other way) doesn't verify.
  const relabelled = testChain(root, { leafSigalg: "SHA256withECDSA" });
  const other = testChain(root);
  assertEquals(await refusal(relabelled.sign(transaction, { x5c: [relabelled.x5c[0], other.x5c[1], root.certificate] })),
    "chain_leaf");
});

Deno.test("Apple's two pinned roots (G3, ECDSA; G2, RSA) both load", () => {
  appleVerifier({ allowSandbox: false });
});

Deno.test("no roots, no verifier", () => {
  let threw = false;
  try {
    appleJwsVerifier([]);
  } catch {
    threw = true;
  }
  assert(threw);
});

// MARK: - What appleVerifier checks on top

const verifier = appleVerifier({ allowSandbox: true, roots: [root.certificate] });

Deno.test("a transaction for this app in Production or Sandbox is read", async () => {
  assertEquals(await verifier.transaction(chain.sign(transaction)), {
    originalTransactionId: transaction.originalTransactionId,
    transactionId: transaction.transactionId,
    productId: transaction.productId,
    bundleId: transaction.bundleId,
    expiresDate: transaction.expiresDate,
    revocationDate: undefined,
    appAccountToken: transaction.appAccountToken,
    environment: "Production",
  });
  assertEquals((await verifier.transaction(chain.sign({ ...transaction, environment: "Sandbox" }))).environment, "Sandbox");
});

Deno.test("another app's, an Xcode one or a Sandbox one where Sandbox is off is refused", async () => {
  const refused = async (jws: string, check = verifier) =>
    (await assertRejects(() => check.transaction(jws), VerificationError)).message;
  assertEquals(await refused(chain.sign({ ...transaction, bundleId: "com.other.app" })), "bundle_id");
  assertEquals(await refused(chain.sign({ ...transaction, bundleId: undefined })), "bundle_id");
  assertEquals(await refused(chain.sign({ ...transaction, environment: "Xcode" })), "environment");
  assertEquals(await refused(chain.sign({ ...transaction, environment: "LocalTesting" })), "environment");
  assertEquals(await refused(chain.sign({ ...transaction, environment: undefined })), "environment");
  const productionOnly = appleVerifier({ allowSandbox: false, roots: [root.certificate] });
  assertEquals(await refused(chain.sign({ ...transaction, environment: "Sandbox" }), productionOnly),
    "sandbox purchases are not accepted");
  assertEquals((await productionOnly.transaction(chain.sign(transaction))).environment, "Production");
  // Apple's real roots don't trust a test chain.
  const real = appleVerifier({ allowSandbox: true });
  assertEquals(await refused(chain.sign(transaction), real), "chain_root");
});

Deno.test("fields of the wrong type are left out, not passed on", async () => {
  const odd = { ...transaction, expiresDate: "2099-01-01", appAccountToken: 7, revocationDate: null };
  const read = await verifier.transaction(chain.sign(odd));
  assertEquals([read.expiresDate, read.appAccountToken, read.revocationDate], [undefined, undefined, undefined]);
});

Deno.test("a renewal's grace period is read; its environment is checked", async () => {
  const renewal = { environment: "Production", gracePeriodExpiresDate: SIGNED + 3 * DAY, signedDate: SIGNED,
    autoRenewProductId: APP_STORE.products[0], originalTransactionId: transaction.originalTransactionId };
  assertEquals(await verifier.renewal(chain.sign(renewal)), {
    environment: "Production", gracePeriodExpiresDate: SIGNED + 3 * DAY,
  });
  await assertRejects(() => verifier.renewal(chain.sign({ ...renewal, environment: "Xcode" })), VerificationError,
    "environment");
});

function notification(app: Record<string, unknown>, where: "data" | "summary" = "data") {
  return { notificationType: "DID_RENEW", notificationUUID: "0c6c3ab0-6b0a-4d2a-9e5a-2f1d8d7a1e11", version: "2.0",
    signedDate: SIGNED, [where]: app };
}
const production = { appAppleId: APP_STORE.appAppleId, bundleId: APP_STORE.bundleId, environment: "Production" };

Deno.test("a notification about this app is read: Production needs its Apple ID, Sandbox doesn't", async () => {
  assertEquals((await verifier.notification(chain.sign(notification(production)))).notificationType, "DID_RENEW");
  const sandbox = { bundleId: APP_STORE.bundleId, environment: "Sandbox" };
  assertEquals((await verifier.notification(chain.sign(notification(sandbox)))).data?.environment, "Sandbox");
  assertEquals((await verifier.notification(chain.sign(notification(production, "summary")))).summary?.bundleId,
    APP_STORE.bundleId);
});

Deno.test("a notification about another app, or without one, is refused", async () => {
  const refused = async (payload: unknown) =>
    (await assertRejects(() => verifier.notification(chain.sign(payload)), VerificationError)).message;
  assertEquals(await refused(notification({ ...production, appAppleId: 1 })), "app_apple_id");
  assertEquals(await refused(notification({ ...production, appAppleId: String(APP_STORE.appAppleId) })), "app_apple_id");
  assertEquals(await refused(notification({ ...production, appAppleId: undefined })), "app_apple_id");
  assertEquals(await refused(notification({ ...production, bundleId: "com.other.app" })), "bundle_id");
  assertEquals(await refused(notification({ ...production, environment: "Xcode" })), "environment");
  assertEquals(await refused({ notificationType: "TEST", signedDate: SIGNED }), "environment");
});

Deno.test("RESCIND_CONSENT (appData) and external purchase tokens are read where Apple's library reads them", async () => {
  const rescind = { notificationType: "RESCIND_CONSENT", signedDate: SIGNED, appData: production };
  assertEquals((await verifier.notification(chain.sign(rescind))).notificationType, "RESCIND_CONSENT");
  await assertRejects(() => verifier.notification(chain.sign({ ...rescind, appData: { ...production, bundleId: "x" } })),
    VerificationError, "bundle_id");
  await assertRejects(() => verifier.notification(chain.sign({ ...rescind, appData: { ...production, appAppleId: 1 } })),
    VerificationError, "app_apple_id");
  const external = (externalPurchaseId: string, appAppleId?: number) => ({
    notificationType: "EXTERNAL_PURCHASE_TOKEN", signedDate: SIGNED,
    externalPurchaseToken: { bundleId: APP_STORE.bundleId, appAppleId, externalPurchaseId },
  });
  assertEquals((await verifier.notification(chain.sign(external("SANDBOX_0001")))).notificationType, "EXTERNAL_PURCHASE_TOKEN");
  await verifier.notification(chain.sign(external("0001", APP_STORE.appAppleId)));
  await assertRejects(() => verifier.notification(chain.sign(external("0001"))), VerificationError, "app_apple_id");
  const productionOnly = appleVerifier({ allowSandbox: false, roots: [root.certificate] });
  await assertRejects(() => productionOnly.notification(chain.sign(external("SANDBOX_0001"))), VerificationError, "sandbox");
  // The handler has nothing to apply for either, and says so with a 200, so Apple doesn't retry.
  const handler = createNotificationHandler({ verifier, ownerOf: () => Promise.resolve(null), apply: () => Promise.reject(new Error("no")) });
  for (const payload of [rescind, external("SANDBOX_0001")]) {
    const response = await handler(new Request("http://local/n", { method: "POST", body: JSON.stringify({ signedPayload: chain.sign(payload) }) }));
    assertEquals(response.status, 200);
  }
});

Deno.test("bodies far larger than Apple's are refused without being read whole", async () => {
  const notify = createNotificationHandler({ verifier, ownerOf: () => Promise.resolve(null), apply: () => Promise.resolve() });
  const post = (body: BodyInit) => notify(new Request("http://local/n", { method: "POST", body, duplex: "half" } as RequestInit));
  assertEquals((await post(JSON.stringify({ signedPayload: "a".repeat(300 * 1024) }))).status, 400);
  let pulled = 0;
  const endless = new ReadableStream<Uint8Array>({
    pull(controller) {
      pulled++;
      controller.enqueue(new Uint8Array(64 * 1024).fill(0x20));
    },
  });
  assertEquals((await post(endless)).status, 400);
  assert(pulled < 10, `read ${pulled} chunks`);
  // A real-sized notification still goes through.
  assertEquals((await post(JSON.stringify({ signedPayload: chain.sign(notification(production)) }))).status, 200);
  const purchase = createPurchaseHandler({
    authenticate: () => Promise.resolve({ userId: transaction.appAccountToken, isAnonymous: false }),
    verifier, ownerOf: () => Promise.resolve(null), accountKind: () => Promise.resolve("member"),
    release: () => Promise.resolve(), apply: (_userId, update) => Promise.resolve({ plan: update.plan }), now: () => SIGNED,
  });
  const buy = (body: string) => purchase(new Request("http://local/p", { method: "POST", body }));
  assertEquals((await buy(JSON.stringify({ transaction: "a".repeat(70 * 1024) }))).status, 400);
  assertEquals((await buy(JSON.stringify({ transaction: chain.sign(transaction) }))).status, 200);
});

Deno.test("a signed purchase reaches the entitlement through the real verifier", async () => {
  const applied: [string, EntitlementUpdate][] = [];
  const handler = createPurchaseHandler({
    authenticate: () => Promise.resolve({ userId: transaction.appAccountToken, isAnonymous: false }),
    verifier,
    ownerOf: () => Promise.resolve(null),
    accountKind: () => Promise.resolve("member"),
    release: () => Promise.resolve(),
    apply: (userId, update) => {
      applied.push([userId, update]);
      return Promise.resolve({ plan: update.plan });
    },
    now: () => SIGNED,
  });
  const post = (jws: string) =>
    handler(new Request("http://local/verify-purchase", { method: "POST", body: JSON.stringify({ transaction: jws }) }));
  const response = await post(chain.sign(transaction));
  assertEquals(response.status, 200);
  assertEquals(applied[0][1].plan, "pro");
  assertEquals(applied[0][1].environment, "Production");
  assertEquals((await post(tampered(chain.sign(transaction), 1))).status, 400);
  assertEquals((await post(testChain(testAuthority()).sign(transaction))).status, 400);
  assertEquals(applied.length, 1);
});

// MARK: - Apple's own signed data, when a real notification is provided

const fixture = (() => {
  try {
    return Deno.env.get("APPLE_NOTIFICATION_FIXTURE");
  } catch {
    return undefined;
  }
})();

Deno.test({
  name: "a real App Store notification verifies against Apple's roots, and a changed copy doesn't",
  ignore: !fixture,
  async fn() {
    const entries = JSON.parse(await Deno.readTextFile(fixture!)) as unknown[];
    const payloads = entries.map((entry) =>
      typeof entry === "string" ? entry : (entry as { signedPayload: string }).signedPayload
    );
    assert(payloads.length > 0);
    const real = appleVerifier({ allowSandbox: false });
    for (const signedPayload of payloads) {
      const decoded = await real.notification(signedPayload);
      assertEquals(decoded.data?.bundleId, APP_STORE.bundleId);
      const signedTransaction = decoded.data?.signedTransactionInfo;
      if (signedTransaction) {
        const read = await real.transaction(signedTransaction);
        assert(APP_STORE.products.includes(read.productId ?? ""));
        assert(read.originalTransactionId);
        await assertRejects(() => real.transaction(tampered(signedTransaction, 1)), VerificationError);
      }
      if (decoded.data?.signedRenewalInfo) await real.renewal(decoded.data.signedRenewalInfo);
      await assertRejects(() => real.notification(tampered(signedPayload, 1)), VerificationError);
      // The whole notification handler, with a stand-in database.
      const applied: EntitlementUpdate[] = [];
      const handler = createNotificationHandler({
        verifier: real,
        ownerOf: () => Promise.resolve(null),
        apply: (_userId, update) => {
          applied.push(update);
          return Promise.resolve();
        },
      });
      const response = await handler(new Request("http://local/app-store-notifications", {
        method: "POST", body: JSON.stringify({ signedPayload }),
      }));
      assertEquals(response.status, 200);
      if (signedTransaction) assertEquals(applied.length, 1);
    }
  },
});

function base64Url(text: string): string {
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** r and s as an ASN.1 SEQUENCE of two INTEGERs. */
function derSignature(r: Uint8Array, s: Uint8Array): Uint8Array {
  const integer = (bytes: Uint8Array) => {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start++;
    const trimmed = bytes.slice(start);
    const body = trimmed[0] & 0x80 ? [0, ...trimmed] : [...trimmed];
    return [0x02, body.length, ...body];
  };
  const content = [...integer(r), ...integer(s)];
  return Uint8Array.from([0x30, content.length, ...content]);
}
