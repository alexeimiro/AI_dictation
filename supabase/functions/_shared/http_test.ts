import { assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { authenticate, background, corsHeaders, deviceArg, deviceOf, drainBackground } from "./http.ts";

const DEVICE = "0f8fad5b-d9cb-469f-a165-70867728950e";

function requestWith(headers: Record<string, string>): Request {
  return new Request("http://localhost/functions/v1/dictate", { method: "POST", headers });
}

Deno.test("the device is the id the app sends, and nothing else", () => {
  assertEquals(deviceOf(requestWith({ "x-murmur-device": DEVICE })), DEVICE);
  assertEquals(deviceOf(requestWith({ "x-murmur-device": ` ${DEVICE.toUpperCase()} ` })), DEVICE, "as the server keeps it");
  for (const junk of ["", "my-iphone", `${DEVICE}0`, DEVICE.replaceAll("-", ""), `${DEVICE}, ${DEVICE}`]) {
    assertEquals(deviceOf(requestWith({ "x-murmur-device": junk })), null, junk);
  }
  assertEquals(deviceOf(requestWith({})), null);
  assertEquals(corsHeaders["Access-Control-Allow-Headers"].includes("x-murmur-device"), true);
});

Deno.test("a call that names no device is the call it always was", () => {
  assertEquals(deviceArg({ userId: "u", isAnonymous: false }), {});
  assertEquals(deviceArg({ userId: "u", isAnonymous: false, device: null }), {});
  assertEquals(deviceArg({ userId: "u", isAnonymous: false, device: DEVICE }), { p_device: DEVICE });
});

Deno.test("the caller is the token's user, with the device the request names", async () => {
  const claims = (value: unknown) =>
    ({ auth: { getClaims: () => Promise.resolve({ data: value ? { claims: value } : null, error: null }) } }) as unknown as SupabaseClient;
  const signedIn = claims({ sub: "user-1", is_anonymous: false });
  assertEquals(
    await authenticate(requestWith({ Authorization: "Bearer jwt", "x-murmur-device": DEVICE }), signedIn),
    { userId: "user-1", isAnonymous: false, device: DEVICE },
  );
  assertEquals(await authenticate(requestWith({ Authorization: "Bearer jwt" }), signedIn), {
    userId: "user-1", isAnonymous: false, device: null,
  });
  assertEquals((await authenticate(requestWith({ Authorization: "Bearer jwt" }), claims({ sub: "guest-1", is_anonymous: true })))?.isAnonymous, true);
  // No token, or one that names nobody: no caller, whatever device is named.
  assertEquals(await authenticate(requestWith({ "x-murmur-device": DEVICE }), signedIn), null);
  assertEquals(await authenticate(requestWith({ Authorization: "Bearer jwt", "x-murmur-device": DEVICE }), claims(null)), null);
});

/** Runs `work` with console.error silenced: a failed task logs on purpose. */
async function quietly<T>(work: () => Promise<T>): Promise<T> {
  const original = console.error;
  console.error = () => {};
  try {
    return await work();
  } finally {
    console.error = original;
  }
}

Deno.test("with nothing in the background, a drain is over at once", async () => {
  assertEquals(await drainBackground(1000), 0);
});

Deno.test("a drain waits for the work handed to background, failed work included", async () => {
  const slow = Promise.withResolvers<void>();
  const failing = Promise.withResolvers<void>();
  let finished = 0;
  background(slow.promise.then(() => void finished++));
  background(failing.promise);
  // A lazy PostgREST builder: it only starts once something awaits it.
  background({ then: (resolve: (value: unknown) => void) => (finished++, resolve(null)) } as PromiseLike<unknown>);

  const drained = drainBackground(5000);
  slow.resolve();
  failing.reject(new Error("database down"));
  assertEquals(await quietly(() => drained), 0);
  assertEquals(finished, 2);
});

Deno.test("work that hands over more work is waited for too", async () => {
  const first = Promise.withResolvers<void>();
  const second = Promise.withResolvers<void>();
  let finished = false;
  background(first.promise.then(() => background(second.promise.then(() => void (finished = true)))));
  const drained = drainBackground(5000);
  first.resolve();
  await Promise.resolve();
  second.resolve();
  assertEquals(await drained, 0);
  assertEquals(finished, true);
});

Deno.test("a drain gives up at its deadline and says how much is unfinished", async () => {
  const stuck = Promise.withResolvers<void>();
  background(stuck.promise);
  assertEquals(await drainBackground(20), 1);
  // Let it finish, so nothing is left for the next test.
  stuck.resolve();
  assertEquals(await drainBackground(1000), 0);
});
