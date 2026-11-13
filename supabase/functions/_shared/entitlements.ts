// The `entitlements` writes behind App Store purchases (service role: clients can't write billing).
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.117.3";
import type { AccountKind, EntitlementUpdate } from "./app_store.ts";

/** The account an App Store subscription (its original transaction) already belongs to. */
export async function subscriptionOwner(admin: SupabaseClient, originalTransactionId: string): Promise<string | null> {
  const { data, error } = await admin.from("entitlements").select("user_id")
    .eq("original_transaction_id", originalTransactionId).maybeSingle();
  if (error) throw error;
  return (data as { user_id?: string } | null)?.user_id ?? null;
}

/**
 * Whether an account can still be signed in to: a member's can; a guest's (an anonymous sign-in)
 * can't once it's signed out or its app is deleted; a deleted one is gone.
 */
export async function accountKind(admin: SupabaseClient, userId: string): Promise<AccountKind> {
  const { data, error } = await admin.auth.admin.getUserById(userId);
  if (error) {
    if (error.status === 404) return "gone";
    throw error;
  }
  if (!data.user) return "gone";
  return data.user.is_anonymous ? "guest" : "member";
}

/** Takes a subscription off an account, which is Basic again (its trial dates stay). */
export async function releaseSubscription(
  admin: SupabaseClient, userId: string, originalTransactionId: string,
): Promise<void> {
  const { error } = await admin.from("entitlements")
    .update({
      plan: "basic", source: "trial", expires_at: null, original_transaction_id: null, product_id: null,
      environment: null, revoked_at: null,
    })
    .eq("user_id", userId).eq("original_transaction_id", originalTransactionId);
  if (error) throw error;
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
