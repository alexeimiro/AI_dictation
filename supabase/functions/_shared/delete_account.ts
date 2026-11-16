// delete-account's handler; the contract is in delete-account/index.ts. What it talks to is
// injected (`DeleteAccountDeps`), so the tests drive it offline.
//
// Before the account goes, the database remembers it for 30 days (`retire_account`, migration
// 20261117000000): a fingerprint of its sign-in with the words it used this week, its trial and its
// invite. Without that, deleting an account and signing up again would start the free plan afresh.
import type { Revocation } from "./apple_signin.ts";
import { type Caller, corsHeaders, json } from "./http.ts";

/** What became of the account's record of use. */
export type Kept =
  /** Remembered for 30 days. */
  | "kept"
  /** Nothing to recognise it by: a guest. */
  | "none"
  /** The database couldn't say; the account was deleted all the same. */
  | "failed";

export interface DeleteAccountDeps {
  authenticate(request: Request): Promise<Caller | null>;
  /** Revokes Sign in with Apple with the fresh code; never rejects. Null without the Apple key. */
  revokeApple: ((code: string) => Promise<Revocation>) | null;
  /** `retire_account`: "kept" or "none". Rejects when it can't run. */
  retire(userId: string): Promise<string>;
  /** Deletes the user, and with it every row of theirs. Rejects when it fails. */
  deleteUser(userId: string): Promise<void>;
  /** Where the one JSON log line goes (console.log). */
  log?: (line: string) => void;
}

export function createDeleteAccountHandler(deps: DeleteAccountDeps): (request: Request) => Promise<Response> {
  const log = deps.log ?? ((line: string) => console.log(line));
  return async (request) => {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

    const caller = await deps.authenticate(request);
    if (!caller) return json({ error: "unauthorized" }, 401);

    const body = await request.json().catch(() => ({})) as { appleAuthorizationCode?: unknown } | null;
    const sent = body?.appleAuthorizationCode;
    const code = typeof sent === "string" && sent.length <= 1000 ? sent : null;
    const apple = code && deps.revokeApple ? await deps.revokeApple(code) : "skipped";

    // Last thing before the deletion, so the record holds the account as it ends. It never blocks
    // the deletion: a person who asks for their account to go gets that, whatever else fails.
    let kept: Kept;
    try {
      kept = await deps.retire(caller.userId) === "kept" ? "kept" : "none";
    } catch (error) {
      console.error("retire_account failed", error instanceof Error ? error.message : String(error));
      kept = "failed";
    }

    try {
      await deps.deleteUser(caller.userId);
    } catch (error) {
      console.error("delete user failed", error);
      return json({ error: "unavailable" }, 503);
    }
    log(JSON.stringify({ event: "account_deleted", anonymous: caller.isAnonymous, apple, kept }));
    return json({ deleted: true, apple, kept });
  };
}
