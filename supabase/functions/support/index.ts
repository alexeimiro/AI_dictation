// POST /functions/v1/support (authenticated)
// Body: { message, diagnostics }, from the app's Report an issue and Leave feedback.
// Saves the message to issue_reports, then emails a signed-in account's message to the support
// inbox through Resend, at most SUPPORT_EMAIL_DAILY_LIMIT (20) in any 24 hours (_shared/support.ts).
// Ten messages an hour per account.
//   200 { saved: true } · 400 bad_request · 401 unauthorized · 429 rate_limited · 503 unavailable
// Env: RESEND_API_KEY, SUPPORT_EMAIL_TO, SUPPORT_EMAIL_FROM, SUPPORT_EMAIL_DAILY_LIMIT. Without the
// first two messages are only saved.
import { adminClient, authenticate } from "../_shared/http.ts";
import { ACCOUNT_KEY, type AccountKind, createSupportHandler, mailConfig, sendWithResend } from "../_shared/support.ts";

const admin = adminClient();
const config = mailConfig();
const signedIn: AccountKind = "signed_in";

Deno.serve(createSupportHandler({
  authenticate: (request) => authenticate(request, admin),
  withinLimit: async (userId) => {
    const { data, error } = await admin.rpc("consume_bucket", {
      p_key: `support:${userId}`, p_limit: 10, p_window_seconds: 3600,
    });
    if (error) console.error("support rate limit check failed", error);
    return error ? true : data === true;
  },
  save: async (userId, message) => {
    const { error } = await admin.from("issue_reports")
      .insert({ user_id: userId, message: message.message, diagnostics: message.diagnostics });
    if (error) throw error;
  },
  // From the saved messages themselves: consume_bucket's windows can't be a day long, since it
  // clears every window that started over an hour ago.
  countSignedIn: async (since) => {
    const { count, error } = await admin.from("issue_reports")
      .select("id", { count: "exact", head: true })
      .gte("created_at", since)
      .eq(`diagnostics->>${ACCOUNT_KEY}`, signedIn);
    if (error) throw error;
    if (count === null) throw new Error("issue_reports gave no count");
    return count;
  },
  accountEmail: async (userId) => {
    const { data, error } = await admin.auth.admin.getUserById(userId);
    if (error) throw error;
    return data.user?.email || null;
  },
  mail: config && {
    config,
    send: (email) => sendWithResend(email, config.apiKey, { signal: AbortSignal.timeout(8000) }),
  },
}));
