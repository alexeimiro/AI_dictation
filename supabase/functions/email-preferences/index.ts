// /functions/v1/email-preferences (no JWT: the lifecycle emails' links carry a token instead)
// Unsubscribe (one-click or from simplymurmur.com/unsubscribe/), subscribe again, and the answer
// to "How likely are you to recommend Murmur?" from simplymurmur.com/score/
// (_shared/email_preferences.ts). Sixty requests an hour per IP address.
import { createPreferencesHandler } from "../_shared/email_preferences.ts";
import { adminClient, clientIP } from "../_shared/http.ts";

const admin = adminClient();

Deno.serve(createPreferencesHandler({
  site: "https://simplymurmur.com",
  findUser: async (token) => {
    const { data, error } = await admin.from("email_settings").select("user_id").eq("token", token).maybeSingle();
    if (error) throw error;
    return data?.user_id ?? null;
  },
  setSubscribed: async (userId, subscribed) => {
    const { error } = await admin.from("email_settings").update({ subscribed }).eq("user_id", userId);
    if (error) throw error;
  },
  saveScore: async (userId, score, comment) => {
    // Without a comment, the upsert leaves the saved one as it is.
    const row: Record<string, unknown> = { user_id: userId, score };
    if (comment !== null) row.comment = comment;
    const { error } = await admin.from("email_scores").upsert(row, { onConflict: "user_id" });
    if (error) throw error;
  },
  withinLimit: async (request) => {
    const { data, error } = await admin.rpc("consume_bucket", {
      p_key: `email-preferences:${clientIP(request)}`, p_limit: 60, p_window_seconds: 3600,
    });
    if (error) console.error("email preferences rate limit check failed", error);
    return error ? true : data === true;
  },
}));
