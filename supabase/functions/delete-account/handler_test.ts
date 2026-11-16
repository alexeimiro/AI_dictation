import { assertEquals } from "jsr:@std/assert@1";
import type { Revocation } from "../_shared/apple_signin.ts";
import { createDeleteAccountHandler, type DeleteAccountDeps } from "../_shared/delete_account.ts";
import type { Caller } from "../_shared/http.ts";

const USER = "7c9e6679-7425-40de-944b-e07fc1f90ae7";

interface World {
  deps: DeleteAccountDeps;
  /** What was done, in order: "revoke <code>", "retire <user>", "delete <user>". */
  steps: string[];
  logs: Record<string, unknown>[];
}

function world(options: {
  caller?: Caller | null;
  apple?: Revocation | null;
  retire?: string | Error;
  deleteFails?: boolean;
} = {}): World {
  const steps: string[] = [];
  const logs: Record<string, unknown>[] = [];
  const apple = options.apple === undefined ? "revoked" : options.apple;
  const deps: DeleteAccountDeps = {
    authenticate: () => Promise.resolve(options.caller === undefined ? { userId: USER, isAnonymous: false } : options.caller),
    revokeApple: apple && ((code) => {
      steps.push(`revoke ${code}`);
      return Promise.resolve(apple);
    }),
    retire: (userId) => {
      steps.push(`retire ${userId}`);
      const answer = options.retire ?? "kept";
      return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
    },
    deleteUser: (userId) => {
      steps.push(`delete ${userId}`);
      return options.deleteFails ? Promise.reject(new Error("auth is down")) : Promise.resolve();
    },
    log: (line) => void logs.push(JSON.parse(line)),
  };
  return { deps, steps, logs };
}

async function send(w: World, body: unknown = {}, method = "POST") {
  const response = await createDeleteAccountHandler(w.deps)(new Request("http://localhost/delete-account", {
    method,
    headers: { Authorization: "Bearer jwt", "Content-Type": "application/json" },
    body: method === "POST" ? (typeof body === "string" ? body : JSON.stringify(body)) : undefined,
  }));
  return { status: response.status, body: await response.json().catch(() => null) };
}

/** Runs `work` with console.error silenced: the failure paths log on purpose. */
async function quietly<T>(work: () => Promise<T>): Promise<T> {
  const original = console.error;
  console.error = () => {};
  try {
    return await work();
  } finally {
    console.error = original;
  }
}

Deno.test("only a signed-in POST deletes anything", async () => {
  const stranger = world({ caller: null });
  assertEquals((await send(stranger)).status, 401);
  const reader = world();
  assertEquals((await send(reader, undefined, "GET")).status, 405);
  assertEquals([...stranger.steps, ...reader.steps], []);
});

Deno.test("the account is remembered just before it is deleted, after Apple's revocation", async () => {
  const w = world();
  const reply = await send(w, { appleAuthorizationCode: "fresh-code" });
  assertEquals(reply, { status: 200, body: { deleted: true, apple: "revoked", kept: "kept" } });
  assertEquals(w.steps, ["revoke fresh-code", `retire ${USER}`, `delete ${USER}`]);
  assertEquals(w.logs, [{ event: "account_deleted", anonymous: false, apple: "revoked", kept: "kept" }]);
});

Deno.test("without a code, or without Apple's key, nothing is revoked and the rest goes on", async () => {
  const noCode = world();
  assertEquals((await send(noCode)).body, { deleted: true, apple: "skipped", kept: "kept" });
  assertEquals(noCode.steps, [`retire ${USER}`, `delete ${USER}`]);

  const noKey = world({ apple: null });
  assertEquals((await send(noKey, { appleAuthorizationCode: "fresh-code" })).body.apple, "skipped");

  // A code that can't be one, and a body that isn't JSON, are no code at all.
  const junk = world();
  assertEquals((await send(junk, { appleAuthorizationCode: "x".repeat(1001) })).body.apple, "skipped");
  assertEquals((await send(junk, "not json")).body.apple, "skipped");
  assertEquals(junk.steps.filter((step) => step.startsWith("revoke")), []);
});

Deno.test("a failed revocation doesn't stop the deletion", async () => {
  const w = world({ apple: "exchange_failed" });
  assertEquals((await send(w, { appleAuthorizationCode: "stale" })).body, { deleted: true, apple: "exchange_failed", kept: "kept" });
});

Deno.test("a guest leaves nothing to remember", async () => {
  const w = world({ caller: { userId: USER, isAnonymous: true }, retire: "none" });
  assertEquals((await send(w)).body, { deleted: true, apple: "skipped", kept: "none" });
  assertEquals(w.logs[0].anonymous, true);
});

Deno.test("an account that can't be remembered is deleted all the same", async () => {
  const w = world({ retire: new Error("42883 function public.retire_account(uuid) does not exist") });
  const reply = await quietly(() => send(w));
  assertEquals(reply, { status: 200, body: { deleted: true, apple: "skipped", kept: "failed" } });
  assertEquals(w.steps, [`retire ${USER}`, `delete ${USER}`]);
});

Deno.test("a deletion that fails says so, and can be asked for again", async () => {
  const w = world({ deleteFails: true });
  const reply = await quietly(() => send(w));
  assertEquals(reply, { status: 503, body: { error: "unavailable" } });
  assertEquals(w.logs, [], "nothing was deleted, so nothing says it was");
});
