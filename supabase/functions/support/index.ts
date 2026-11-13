// POST /functions/v1/support (authenticated)
// Body: { message, diagnostics }, from the app's Report an issue and Leave feedback.
// Saves the message to issue_reports, then emails it to the support inbox through Resend
// (_shared/support.ts). Ten messages an hour per account.
//   200 { saved: true } · 400 bad_request · 401 unauthorized · 429 rate_limited · 503 unavailable
// Env: RESEND_API_KEY, SUPPORT_EMAIL_TO, SUPPORT_EMAIL_FROM. Without them messages are only saved.
import { adminClient, authenticate } from "../_shared/http.ts";
import { createSupportHandler, mailConfig, sendWithResend } from "../_shared/support.ts";

const admin = adminClient();
const config = mailConfig();

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
