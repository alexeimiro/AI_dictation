import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import type { Caller } from "./http.ts";
import { dictationPreflight, readQuota, recordUsage } from "./preflight.ts";

const USER = "7c9e6679-7425-40de-944b-e07fc1f90ae7";
const DICTATION = "3f2504e0-4f89-41d3-9a0c-0305e82c3301";
const DEVICE = "0f8fad5b-d9cb-469f-a165-70867728950e";
const plain: Caller = { userId: USER, isAnonymous: false };
const onPhone: Caller = { ...plain, device: DEVICE };

/** A service-role client that records its RPCs and answers each with `answer`. */
function database(answer: { data?: unknown; error?: unknown } = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const reply = { data: null, error: null, ...answer };
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      // A PostgREST builder: awaited as it is, narrowed to one row, or given a signal first.
      const builder = Object.assign(Promise.resolve(reply), {
        single: () => Promise.resolve(reply),
        abortSignal: () => Promise.resolve(reply),
      });
      return builder;
    },
  } as unknown as SupabaseClient;
  return { admin, calls };
}

const allowed = { data: { allowed: true, reason: null, plan: "basic", remaining: 870, attempt: 1 } };

Deno.test("the checks and the count name the iPhone a request comes from", async () => {
  const { admin, calls } = database(allowed);
  assertEquals(await dictationPreflight(admin, onPhone, "dictate", DICTATION, 40), {
    allowed: true, reason: null, plan: "basic", remaining: 870, attempt: 1,
  });
  await readQuota(admin, onPhone, AbortSignal.timeout(1000));
  await recordUsage(admin, onPhone, DICTATION, 7);
  assertEquals(calls, [
    { name: "dictation_preflight", args: { p_user: USER, p_scope: "dictate", p_dictation: DICTATION, p_per_minute: 40, p_device: DEVICE } },
    { name: "quota_status", args: { p_user: USER, p_device: DEVICE } },
    { name: "record_usage", args: { p_user: USER, p_dictation: DICTATION, p_words: 7, p_device: DEVICE } },
  ]);
});

Deno.test("a build that sends no id makes the calls as they were before there were devices", async () => {
  const { admin, calls } = database(allowed);
  await dictationPreflight(admin, plain, "transcribe", null, 10);
  await readQuota(admin, { ...plain, device: null }, AbortSignal.timeout(1000));
  await recordUsage(admin, plain, DICTATION, 7);
  assertEquals(calls, [
    { name: "dictation_preflight", args: { p_user: USER, p_scope: "transcribe", p_dictation: null, p_per_minute: 10 } },
    { name: "quota_status", args: { p_user: USER } },
    { name: "record_usage", args: { p_user: USER, p_dictation: DICTATION, p_words: 7 } },
  ]);
});

Deno.test("a check or a count the database refuses is an error, so the caller fails closed", async () => {
  const { admin } = database({ error: { code: "PGRST202", message: "no such function" } });
  await assertRejects(() => dictationPreflight(admin, onPhone, "dictate", DICTATION, 40), Error, "dictation_preflight failed");
  await assertRejects(() => readQuota(admin, onPhone, AbortSignal.timeout(1000)), Error, "quota_status failed");
  await assertRejects(() => recordUsage(admin, onPhone, DICTATION, 7), Error, "record_usage failed");
});
