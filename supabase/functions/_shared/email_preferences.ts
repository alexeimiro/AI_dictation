// What the links in lifecycle emails do, without signing in: each link carries the account's random
// email_settings token.
// - The List-Unsubscribe header's one-click POST (RFC 8058) unsubscribes at once.
// - A GET of that link (a mail app that opens it instead) goes to simplymurmur.com/unsubscribe/,
//   which asks first: link scanners open links, and must not unsubscribe anyone.
// - That page, and the 1–10 page (simplymurmur.com/score/), POST JSON here.
import { corsHeaders, json } from "./http.ts";

export interface PreferencesDeps {
  /** The account the token belongs to, or null. */
  findUser(token: string): Promise<string | null>;
  setSubscribed(userId: string, subscribed: boolean): Promise<void>;
  /** Saves the score, and the comment when one is given (null keeps the one saved). */
  saveScore(userId: string, score: number, comment: string | null): Promise<void>;
  /** False when the caller has made too many requests lately. */
  withinLimit(request: Request): Promise<boolean>;
  site: string;
}

const TOKEN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const validToken = (value: unknown): string | null =>
  typeof value === "string" && TOKEN.test(value.trim().toLowerCase()) ? value.trim().toLowerCase() : null;

// GET  ?t=…&a=unsubscribe                       → 302 to the site's unsubscribe page
// POST ?t=…&a=unsubscribe (List-Unsubscribe=One-Click) → 200 { done: true }
// POST { token, action: "unsubscribe" | "resubscribe" }        → 200 { done: true, subscribed }
// POST { token, action: "score", score: 1–10, comment? }        → 200 { done: true }
//   400 bad_request · 404 not_found · 429 rate_limited · 503 unavailable
export function createPreferencesHandler(deps: PreferencesDeps): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
    const url = new URL(request.url);
    const linkToken = validToken(url.searchParams.get("t"));
    const linkAction = url.searchParams.get("a");

    if (request.method === "GET") {
      if (!linkToken || linkAction !== "unsubscribe") return json({ error: "bad_request" }, 400);
      return new Response(null, {
        status: 302,
        headers: { Location: `${deps.site}/unsubscribe/?t=${linkToken}` },
      });
    }
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    if (!await deps.withinLimit(request)) return json({ error: "rate_limited" }, 429);

    let token: string | null;
    let action: unknown;
    let body: Record<string, unknown> = {};
    if (linkToken && linkAction === "unsubscribe") {
      // The one-click POST: its body is the form field List-Unsubscribe=One-Click.
      token = linkToken;
      action = "unsubscribe";
    } else {
      body = await request.json().catch(() => null) ?? {};
      token = validToken(body.token);
      action = body.action;
    }
    if (!token) return json({ error: "bad_request" }, 400);

    try {
      const userId = await deps.findUser(token);
      if (!userId) return json({ error: "not_found" }, 404);
      if (action === "unsubscribe" || action === "resubscribe") {
        const subscribed = action === "resubscribe";
        await deps.setSubscribed(userId, subscribed);
        console.log(JSON.stringify({ event: "email_preferences", action }));
        return json({ done: true, subscribed });
      }
      if (action === "score") {
        const score = body.score;
        if (typeof score !== "number" || !Number.isInteger(score) || score < 1 || score > 10) {
          return json({ error: "bad_request" }, 400);
        }
        const comment = typeof body.comment === "string" && body.comment.trim()
          ? body.comment.trim().slice(0, 2000)
          : null;
        await deps.saveScore(userId, score, comment);
        console.log(JSON.stringify({ event: "email_score", score, comment: comment !== null }));
        return json({ done: true });
      }
      return json({ error: "bad_request" }, 400);
    } catch (error) {
      console.error("email preferences failed", error);
      return json({ error: "unavailable" }, 503);
    }
  };
}
