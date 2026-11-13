import { assertEquals } from "jsr:@std/assert@1";
import type { TrialBit } from "../_shared/devicecheck.ts";
import type { Caller } from "../_shared/http.ts";
import { createTrialHandler, type TrialDecision, type TrialDeps, type TrialState } from "../_shared/trial.ts";

const USER = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const TOKEN = "AgAAAH4dSnA0aZx8Fv1oNlWb8w2s0vEXAMPLEdevicetokenbase64==";
const ENDS = "2026-11-27T08:00:00.000Z";

interface World {
  deps: TrialDeps;
  decided: TrialDecision[];
  queried: string[];
  marked: string[];
  later: Promise<unknown>[];
}

/** The handler over an account that is `state`, with Apple answering `bit` (no key when undefined). */
function world(options: {
  state?: TrialState | Error;
  bit?: TrialBit;
  markOK?: boolean;
  decideFails?: boolean;
  caller?: Caller | null;
} = {}): World {
  const decided: TrialDecision[] = [];
  const queried: string[] = [];
  const marked: string[] = [];
  const later: Promise<unknown>[] = [];
  let state: TrialState | Error = options.state ?? { outcome: null, trialEndsAt: null };
  const deps: TrialDeps = {
    authenticate: () => Promise.resolve(options.caller === undefined ? { userId: USER, isAnonymous: false } : options.caller),
    current: () => state instanceof Error ? Promise.reject(state) : Promise.resolve(state),
    decide: (_userId, outcome) => {
      if (options.decideFails) return Promise.reject(new Error("database down"));
      decided.push(outcome);
      // The first decision stands, as decide_trial keeps it.
      if (!(state instanceof Error) && !state.outcome) {
        state = { outcome, trialEndsAt: outcome === "device_used" ? null : ENDS };
      }
      return Promise.resolve(state as TrialState);
    },
    deviceCheck: options.bit
      ? {
        query: (token) => {
          queried.push(token);
          return Promise.resolve(options.bit!);
        },
        mark: (token) => {
          marked.push(token);
          return Promise.resolve(options.markOK ?? true);
        },
      }
      : null,
    later: (task) => later.push(task),
  };
  return { deps, decided, queried, marked, later };
}

async function claim(w: World, body: unknown = { deviceToken: TOKEN }, method = "POST") {
  const response = await createTrialHandler(w.deps)(new Request("http://localhost/claim-trial", {
    method,
    headers: { Authorization: "Bearer jwt", "Content-Type": "application/json" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  }));
  await Promise.all(w.later);
  return { status: response.status, body: await response.json().catch(() => null) };
}

Deno.test("only a signed-in POST is answered", async () => {
  assertEquals((await claim(world({ caller: null }))).status, 401);
  assertEquals((await claim(world(), undefined, "GET")).status, 405);
});

Deno.test("an iPhone's first account gets the trial, and the iPhone is marked after", async () => {
  const w = world({ bit: { kind: "clear" } });
  assertEquals(await claim(w), { status: 200, body: { trial: "granted", trialEndsAt: ENDS } });
  assertEquals(w.queried, [TOKEN]);
  assertEquals(w.decided, ["granted"]);
  assertEquals(w.marked, [TOKEN]);
});

Deno.test("an iPhone that had its trial: the account stays on Basic, nothing more is marked", async () => {
  const w = world({ bit: { kind: "set", lastUpdate: "2026-11" } });
  assertEquals(await claim(w), { status: 200, body: { trial: "device_used", trialEndsAt: null } });
  assertEquals(w.decided, ["device_used"]);
  assertEquals(w.marked, []);
});

Deno.test("a decided account gets its decision back, without asking Apple again", async () => {
  for (const outcome of ["granted", "device_used", "unchecked", "legacy"] as const) {
    const w = world({ state: { outcome, trialEndsAt: ENDS }, bit: { kind: "clear" } });
    assertEquals(await claim(w), { status: 200, body: { trial: outcome, trialEndsAt: ENDS } }, outcome);
    assertEquals(w.queried, []);
    assertEquals(w.decided, []);
    assertEquals(w.marked, []);
  }
});

Deno.test("without the DeviceCheck key every trial is granted unchecked, token or not", async () => {
  for (const body of [{ deviceToken: TOKEN }, {}, null]) {
    const w = world();
    assertEquals(await claim(w, body), { status: 200, body: { trial: "unchecked", trialEndsAt: ENDS } });
    assertEquals(w.decided, ["unchecked"]);
  }
});

Deno.test("with the key, no token or a malformed one decides nothing", async () => {
  for (const [body, error] of [[{}, "device_token_required"], [{ deviceToken: null }, "device_token_required"],
    [{ deviceToken: "not base64!" }, "bad_device_token"], [{ deviceToken: 7 }, "bad_device_token"]] as const) {
    const w = world({ bit: { kind: "clear" } });
    assertEquals(await claim(w, body), { status: 400, body: { error } }, JSON.stringify(body));
    assertEquals(w.queried, []);
    assertEquals(w.decided, []);
  }
});

Deno.test("a token Apple refuses decides nothing either", async () => {
  const w = world({ bit: { kind: "bad_token" } });
  assertEquals(await claim(w), { status: 400, body: { error: "bad_device_token" } });
  assertEquals(w.decided, []);
  assertEquals(w.marked, []);
});

Deno.test("when Apple can't answer, the trial is granted unchecked and the iPhone isn't marked", async () => {
  const w = world({ bit: { kind: "unavailable", status: 503, detail: "Service Unavailable" } });
  assertEquals(await claim(w), { status: 200, body: { trial: "unchecked", trialEndsAt: ENDS } });
  assertEquals(w.decided, ["unchecked"]);
  assertEquals(w.marked, []);
});

Deno.test("a failed mark keeps the account's trial", async () => {
  const w = world({ bit: { kind: "clear" }, markOK: false });
  assertEquals(await claim(w), { status: 200, body: { trial: "granted", trialEndsAt: ENDS } });
  assertEquals(w.marked, [TOKEN]);
});

Deno.test("a database that can't be read or written is 503, and nothing is marked", async () => {
  assertEquals((await claim(world({ state: new Error("no entitlement row"), bit: { kind: "clear" } }))).status, 503);
  const w = world({ bit: { kind: "clear" }, decideFails: true });
  assertEquals(await claim(w), { status: 503, body: { error: "unavailable" } });
  assertEquals(w.marked, []);
});

Deno.test("a claim that loses the race returns the decision that stands, and doesn't mark", async () => {
  const w = world({ bit: { kind: "clear" } });
  // Another claim for the same account decided first, between the read and the write.
  const decide = w.deps.decide;
  w.deps.decide = async (userId) => {
    await decide(userId, "unchecked");
    return decide(userId, "granted");
  };
  assertEquals(await claim(w), { status: 200, body: { trial: "unchecked", trialEndsAt: ENDS } });
  assertEquals(w.marked, []);
});
