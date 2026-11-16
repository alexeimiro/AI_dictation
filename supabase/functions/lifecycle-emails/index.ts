// POST /functions/v1/lifecycle-emails (no JWT: pg_cron's call carries Vault's secret)
// Sends the lifecycle emails that are due: the welcome, the first two weeks' tips and the day
// before the Pro trial ends (_shared/lifecycle.ts has the schedule and the settings).
//   { action: "run" }                       x-murmur-cron (pg_cron, every 15 minutes) or x-murmur-admin
//   { action: "run", dryRun: true }         x-murmur-admin: what a run would do, nothing sent
//   { action: "preview", to, kinds?, variant?, name? }   x-murmur-admin: sample emails to a test address
// Nothing is sent while LIFECYCLE_EMAILS is off (the default).
import { adminClient } from "../_shared/http.ts";
import { type Candidate, createLifecycleHandler, lifecycleConfig, sendThroughResend } from "../_shared/lifecycle.ts";
import { KINDS } from "../_shared/lifecycle_emails.ts";

const admin = adminClient();
const config = lifecycleConfig();

interface CandidateRow {
  user_id: string;
  email: string;
  full_name: string | null;
  created_at: string;
  paid: boolean;
  trial_check: string | null;
  trial_ends_at: string | null;
  token: string | null;
  dictations: number;
  words: number;
  days_used: number;
  longest_streak: number;
  sent: string[] | null;
  last_sent_at: string | null;
}

const time = (value: string | null) => value === null ? null : Date.parse(value);

Deno.serve(createLifecycleHandler({
  config,
  cronSecretOk: async (secret) => {
    const { data, error } = await admin.rpc("lifecycle_cron_ok", { p_secret: secret });
    if (error) console.error("lifecycle cron check failed", error);
    return !error && data === true;
  },
  candidates: async (since) => {
    const { data, error } = await admin.rpc("lifecycle_candidates", {
      p_since: new Date(since).toISOString(), p_kinds: KINDS.length,
    });
    if (error) throw error;
    return ((data ?? []) as CandidateRow[]).map((row): Candidate => ({
      userId: row.user_id,
      email: row.email,
      fullName: row.full_name,
      createdAt: Date.parse(row.created_at),
      paid: row.paid,
      trialCheck: row.trial_check,
      trialEndsAt: time(row.trial_ends_at),
      token: row.token,
      dictations: row.dictations,
      words: row.words,
      daysUsed: row.days_used,
      longestStreak: row.longest_streak,
      handled: new Set(row.sent ?? []),
      lastSentAt: time(row.last_sent_at),
    }));
  },
  token: async (userId) => {
    const { data, error } = await admin.rpc("email_token", { p_user: userId });
    if (error || typeof data !== "string") throw error ?? new Error("email_token gave no token");
    return data;
  },
  claim: async (userId, kind, status, detail) => {
    const { data, error } = await admin.from("email_sends")
      .upsert({ user_id: userId, kind, status, detail }, { onConflict: "user_id,kind", ignoreDuplicates: true })
      .select("kind");
    if (error) throw error;
    return (data ?? []).length > 0;
  },
  finish: async (userId, kind, status, detail) => {
    const { error } = await admin.from("email_sends")
      .update({ status, detail: detail.slice(0, 300) })
      .eq("user_id", userId).eq("kind", kind);
    if (error) throw error;
  },
  release: async (userId, kind) => {
    const { error } = await admin.from("email_sends")
      .delete().eq("user_id", userId).eq("kind", kind).eq("status", "sending");
    if (error) throw error;
  },
  sentSince: async (since) => {
    const { count, error } = await admin.from("email_sends")
      .select("kind", { count: "exact", head: true })
      .eq("status", "sent").gte("updated_at", new Date(since).toISOString());
    if (error) throw error;
    return count ?? 0;
  },
  send: (email, idempotencyKey) =>
    sendThroughResend(email, config.apiKey ?? "", idempotencyKey, { signal: AbortSignal.timeout(10000) }),
}));
