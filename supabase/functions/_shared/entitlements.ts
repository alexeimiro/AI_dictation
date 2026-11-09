// The `entitlements` writes behind App Store purchases (service role: clients can't write billing).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import type { EntitlementUpdate } from "./app_store.ts";

/** The account an App Store subscription (its original transaction) already belongs to. */
export async function subscriptionOwner(admin: SupabaseClient, originalTransactionId: string): Promise<string | null> {
  const { data, error } = await admin.from("entitlements").select("user_id")
    .eq("original_transaction_id", originalTransactionId).maybeSingle();
  if (error) throw error;
  return (data as { user_id?: string } | null)?.user_id ?? null;
}

/** Writes the subscription's state onto the account (its trial dates stay) and returns its quota. */
export async function applyEntitlement(
  admin: SupabaseClient, userId: string, update: EntitlementUpdate,
): Promise<Record<string, unknown>> {
  const { error } = await admin.from("entitlements").upsert({ user_id: userId, ...update }, { onConflict: "user_id" });
  if (error) throw error;
  const { data, error: quotaError } = await admin.rpc("quota_status", { p_user: userId });
  if (quotaError) throw quotaError;
  return (data as Record<string, unknown>[] | null)?.[0] ?? {};
}
