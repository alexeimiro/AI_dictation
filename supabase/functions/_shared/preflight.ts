// The database calls around a dictation: the merged preflight before any OpenAI call, the
// read-only quota a warm-up makes, and the usage after the reply. Service role only.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import { type Caller, deviceArg } from "./http.ts";

/** One row of `dictation_preflight`. */
export interface Preflight {
  allowed: boolean;
  /** Null when the call is allowed. */
  reason: "too_many_attempts" | "rate_limited" | "limit_reached" | null;
  plan: string;
  /** Words left this week; null on Pro and during the trial. */
  remaining: number | null;
  /** This call's number within its dictation (1 for the first); null without a dictation id or when refused. */
  attempt: number | null;
}

/**
 * Attempt count, per-minute bucket and quota in one round trip, for the account and, when the
 * request names one, the iPhone it comes from (`Caller.device`). With a dictation id, only the
 * dictation's first call in the scope takes from the scope's minute bucket (keyed `scope:user`, so
 * scope "transcribe" shares `transcribe`'s keys) and its seventh is refused; 10 minutes after the
 * first, its next call starts over. Throws when the RPC fails, so the caller fails closed.
 */
export async function dictationPreflight(
  admin: SupabaseClient,
  caller: Caller,
  scope: string,
  dictationId: string | null,
  perMinute: number,
): Promise<Preflight> {
  const { data, error } = await admin
    .rpc("dictation_preflight", {
      p_user: caller.userId,
      p_scope: scope,
      p_dictation: dictationId,
      p_per_minute: perMinute,
      ...deviceArg(caller),
    })
    .single<Preflight>();
  if (error || !data) throw new Error(`dictation_preflight failed: ${error?.code ?? "no row"} ${error?.message ?? ""}`);
  return {
    allowed: data.allowed === true,
    reason: data.reason ?? null,
    plan: data.plan,
    remaining: data.remaining ?? null,
    attempt: data.attempt ?? null,
  };
}

/**
 * `quota_status`: a warm-up opens the isolate's connection to the database with it. It writes only
 * for an account that hasn't been checked against the deleted ones yet (`restore_account`).
 */
export async function readQuota(admin: SupabaseClient, caller: Caller, signal: AbortSignal): Promise<void> {
  const { error } = await admin.rpc("quota_status", { p_user: caller.userId, ...deviceArg(caller) }).abortSignal(signal);
  if (error) throw new Error(`quota_status failed: ${error.code ?? "unknown"}`);
}

/**
 * `record_usage`: one row per dictation, which keeps the greatest word count it was sent; what a
 * call adds also counts for the iPhone, while the account is on the free plan.
 */
export async function recordUsage(
  admin: SupabaseClient,
  caller: Caller,
  dictationId: string,
  words: number,
): Promise<void> {
  const { error } = await admin.rpc("record_usage", {
    p_user: caller.userId,
    p_dictation: dictationId,
    p_words: words,
    ...deviceArg(caller),
  });
  if (error) throw new Error(`record_usage failed: ${error.code ?? "unknown"}`);
}
