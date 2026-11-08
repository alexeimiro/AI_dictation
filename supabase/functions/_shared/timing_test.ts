import { assert, assertEquals, assertRejects, assertStrictEquals } from "jsr:@std/assert@1";
import { beginRequest, Phases, type RequestStart } from "./timing.ts";

const EXECUTION_ID = "4b6f7a1e-2c3d-4e5f-8a9b-0c1d2e3f4a5b";
/** The two variables a hosted worker gets; locally neither is set. */
const hostedEnv = new Map([["SB_REGION", "eu-central-1"], ["SB_EXECUTION_ID", EXECUTION_ID]]);
const hosted = { get: (name: string) => hostedEnv.get(name) };
const local = { get: (_name: string) => undefined };

// Runs first: `cold` is this module's state, true only for the first request the worker begins.
Deno.test("a worker's first request is cold and the ones after it are warm", () => {
  const first = beginRequest(local);
  const second = beginRequest(local);
  assertEquals([first.cold, second.cold], [true, false]);
  assert(Number.isInteger(first.workerAgeMs) && first.workerAgeMs >= 0);
  assert(second.workerAgeMs >= first.workerAgeMs, "the worker only gets older");
});

Deno.test("the region and execution id come from the hosted env and are null locally", () => {
  const { region, executionId } = beginRequest(hosted);
  assertEquals({ region, executionId }, { region: "eu-central-1", executionId: EXECUTION_ID });
  const offline = beginRequest(local);
  assertEquals([offline.region, offline.executionId], [null, null]);
});

const worker: RequestStart = { cold: false, workerAgeMs: 41210, region: "eu-central-1", executionId: EXECUTION_ID };

/**
 * A clock the test moves by hand. It starts away from 0, so an absolute reading would show, and
 * steps in quarter milliseconds, which add up exactly in floating point.
 */
function fakeClock() {
  let now = 1000;
  /** Work that moves the clock on by `ms` before it settles; an Error value rejects. */
  const takes = <T>(ms: number, value: T): Promise<T> =>
    Promise.resolve().then(() => {
      now += ms;
      if (value instanceof Error) throw value;
      return value;
    });
  return {
    now: () => now,
    advance(ms: number) {
      now += ms;
    },
    takes,
    /** Like a PostgREST builder, which sends nothing until it is awaited. */
    lazily: <T>(ms: number, value: T): PromiseLike<T> => ({
      then: (onFulfilled, onRejected) => takes(ms, value).then(onFulfilled, onRejected),
    }),
  };
}

Deno.test("phases are timed in whole milliseconds; readyMs and totalMs run from the handler start", async () => {
  const clock = fakeClock();
  const phases = new Phases(worker, clock.now);
  assertEquals(await phases.mark("authMs", clock.takes(2.25, "caller")), "caller");
  clock.advance(0.5); // work between phases belongs to none of them
  await phases.mark("bodyMs", clock.takes(30.75, {}));
  assertEquals(await phases.mark("preflightMs", clock.lazily(7.25, true)), true);
  await phases.mark("preflightMs", clock.lazily(4.5, { remaining: 100 })); // a second RPC adds up
  phases.ready();
  await phases.mark("modelMs", clock.takes(689.75, "outcome"));
  clock.advance(1.25);
  assertEquals(phases.toJSON(), {
    region: "eu-central-1",
    cold: false,
    workerAgeMs: 41210,
    executionId: EXECUTION_ID,
    authMs: 2,
    bodyMs: 31,
    preflightMs: 12,
    readyMs: 45,
    modelMs: 690,
    totalMs: 736,
  });
});

Deno.test("a phase that didn't run is left out, and the rest keep their order", async () => {
  const clock = fakeClock();
  const phases = new Phases(worker, clock.now);
  assertEquals(phases.toJSON(), {
    region: "eu-central-1",
    cold: false,
    workerAgeMs: 41210,
    executionId: EXECUTION_ID,
    totalMs: 0,
  });
  await phases.mark("bodyMs", clock.takes(30.25, {}));
  await phases.mark("authMs", clock.takes(2.25, "caller"));
  const keys = Object.keys(phases.toJSON());
  assertEquals(keys, ["region", "cold", "workerAgeMs", "executionId", "authMs", "bodyMs", "totalMs"]);
});

Deno.test("a phase that throws still records its time and rethrows", async () => {
  const clock = fakeClock();
  const phases = new Phases(worker, clock.now);
  const deadline = new DOMException("deadline", "TimeoutError");
  const error = await assertRejects(() => phases.mark("modelMs", clock.takes(9000.25, deadline)));
  assertStrictEquals(error, deadline);
  assertEquals(phases.toJSON().modelMs, 9000);
});
