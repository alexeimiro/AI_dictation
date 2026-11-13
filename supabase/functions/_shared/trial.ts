// The free trial, one per iPhone: claim-trial's handler. An account gets no trial at sign-up
// (migration 20261113000000); the app claims it right after signing in, with a DeviceCheck token.
// Apple's bit 0 says whether this iPhone has had a Murmur trial (_shared/devicecheck.ts):
// - not yet: 14 days of Pro, then bit 0 is set;
// - already: the account stays on Basic (device_used);
// - Apple can't answer, or the server has no DeviceCheck key: the trial is granted unchecked, so
//   nobody loses a trial to our key or to Apple's outage;
// - no token, or one Apple refuses: nothing is decided, and the app asks again later.
// The first decision stands; later claims return it.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { deviceToken, type TrialBit } from "./devicecheck.ts";
import { background, type Caller, corsHeaders, json } from "./http.ts";

export type TrialOutcome = "granted" | "device_used" | "unchecked" | "legacy";
export type TrialDecision = Exclude<TrialOutcome, "legacy">;

export interface TrialState {
  /** Null until decided. */
  outcome: TrialOutcome | null;
  trialEndsAt: string | null;
}

export interface TrialDeps {
  authenticate(request: Request): Promise<Caller | null>;
  /** Rejects when the account has no entitlement row or the database can't be read. */
  current(userId: string): Promise<TrialState>;
  /** Records `outcome` unless the account is decided already, and returns what stands. */
  decide(userId: string, outcome: TrialDecision): Promise<TrialState>;
  /** Null without the DeviceCheck key: every trial is granted unchecked, as before this check. */
  deviceCheck: {
    query(token: string): Promise<TrialBit>;
    /** False when Apple didn't take it. */
    mark(token: string): Promise<boolean>;
  } | null;
  /** Work after the response (marking the iPhone); `background` from http.ts by default. */
  later?(task: Promise<unknown>): void;
}

export function createTrialHandler(deps: TrialDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    const caller = await deps.authenticate(request);
    if (!caller) return json({ error: "unauthorized" }, 401);
    const body = await request.json().catch(() => null) as { deviceToken?: unknown } | null;
    const sent = body?.deviceToken;
    const token = deviceToken(sent);

    let state: TrialState;
    try {
      state = await deps.current(caller.userId);
    } catch (error) {
      console.error("trial read failed", error);
      return json({ error: "unavailable" }, 503);
    }
    if (state.outcome) return json({ trial: state.outcome, trialEndsAt: state.trialEndsAt });

    let decision: TrialDecision;
    if (!deps.deviceCheck) {
      decision = "unchecked";
    } else if (!token) {
      return json({ error: sent === undefined || sent === null ? "device_token_required" : "bad_device_token" }, 400);
    } else {
      const bit = await deps.deviceCheck.query(token);
      if (bit.kind === "bad_token") {
        console.log(JSON.stringify({ event: "trial_bad_device_token", anonymous: caller.isAnonymous }));
        return json({ error: "bad_device_token" }, 400);
      }
      if (bit.kind === "unavailable") {
        console.error(JSON.stringify({ event: "device_check_unavailable", status: bit.status, detail: bit.detail }));
      }
      decision = bit.kind === "set" ? "device_used" : bit.kind === "clear" ? "granted" : "unchecked";
    }

    let decided: TrialState;
    try {
      decided = await deps.decide(caller.userId, decision);
    } catch (error) {
      console.error("trial decision failed", error);
      return json({ error: "unavailable" }, 503);
    }
    if (decision === "granted" && decided.outcome === "granted" && token && deps.deviceCheck) {
      // After the grant, not before: if marking fails, this iPhone may get one more trial later,
      // rather than this account losing its own.
      const mark = deps.deviceCheck.mark(token).then((marked) => {
        if (!marked) console.error(JSON.stringify({ event: "device_check_mark_failed" }));
      });
      (deps.later ?? background)(mark);
    }
    console.log(JSON.stringify({ event: "trial_decided", outcome: decided.outcome, anonymous: caller.isAnonymous }));
    return json({ trial: decided.outcome, trialEndsAt: decided.trialEndsAt });
  };
}

const OUTCOMES: readonly string[] = ["granted", "device_used", "unchecked", "legacy"];
const outcomeOf = (value: unknown): TrialOutcome | null =>
  typeof value === "string" && OUTCOMES.includes(value) ? value as TrialOutcome : null;

export async function currentTrial(admin: SupabaseClient, userId: string): Promise<TrialState> {
  const { data, error } = await admin.from("entitlements").select("trial_check, trial_ends_at")
    .eq("user_id", userId).maybeSingle();
  if (error) throw error;
  if (!data) throw new Error("no entitlement row");
  return { outcome: outcomeOf(data.trial_check), trialEndsAt: data.trial_ends_at ?? null };
}

export async function decideTrial(admin: SupabaseClient, userId: string, outcome: TrialDecision): Promise<TrialState> {
  const { data, error } = await admin.rpc("decide_trial", { p_user: userId, p_outcome: outcome });
  if (error) throw error;
  const row = (Array.isArray(data) ? data[0] : data) as { outcome?: unknown; ends_at?: string | null } | undefined;
  const decided = outcomeOf(row?.outcome);
  if (!decided) throw new Error("decide_trial returned no decision");
  return { outcome: decided, trialEndsAt: row?.ends_at ?? null };
}
