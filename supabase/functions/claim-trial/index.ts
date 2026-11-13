// POST /functions/v1/claim-trial (authenticated)
// Body: { deviceToken?: string }, DCDevice's token in base64.
// Decides the caller's 14-day trial once, one per iPhone: Apple's DeviceCheck keeps bit 0 for "this
// iPhone has had its trial" (_shared/trial.ts, _shared/devicecheck.ts). The app claims right after
// sign-in and again at launch until it has a 200.
//   200 { trial: "granted" | "device_used" | "unchecked" | "legacy", trialEndsAt: string | null }
//   400 device_token_required | bad_device_token: nothing decided; ask again with a token
//   401 unauthorized · 503 unavailable
// Env: DEVICECHECK_KEY_ID, DEVICECHECK_PRIVATE_KEY, APPLE_TEAM_ID, DEVICECHECK_HOST. Without the key
// every trial is granted unchecked, as before this check.
import { deviceCheckConfig, markTrialUsed, queryTrialBit } from "../_shared/devicecheck.ts";
import { adminClient, authenticate } from "../_shared/http.ts";
import { createTrialHandler, currentTrial, decideTrial } from "../_shared/trial.ts";

const admin = adminClient();
const config = deviceCheckConfig();

Deno.serve(createTrialHandler({
  authenticate: (request) => authenticate(request, admin),
  current: (userId) => currentTrial(admin, userId),
  decide: (userId, outcome) => decideTrial(admin, userId, outcome),
  deviceCheck: config && {
    query: (token) => queryTrialBit(token, config, { signal: AbortSignal.timeout(6000) }),
    mark: (token) => markTrialUsed(token, config, { signal: AbortSignal.timeout(6000) }),
  },
}));
