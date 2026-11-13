import { assertEquals } from "jsr:@std/assert@1";
import { background, drainBackground } from "./http.ts";

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
