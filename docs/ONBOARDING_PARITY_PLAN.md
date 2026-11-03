# Onboarding parity plan

## Objective

Reproduce the captured Wispr Flow onboarding in Murmur with the same sequence, hierarchy,
interaction gates, permission timing, keyboard setup handoffs, practice exercises, and completion
behavior. The reference set is `artifacts/wispr-onboarding/01-intro.png` through
`42-flow-home.png`; `contact-sheet.png` is the visual index and
`wispr-onboarding-demo.mp4` is the timing reference.

“Parity” means the Murmur build should match the reference layout and behavior at the supported
iPhone size while using Murmur branding, original illustrations, and Murmur-specific copy where a
Wispr name, trademark, service claim, or proprietary asset appears. Native iOS Settings, keyboard
picker, microphone, and notification dialogs must be invoked rather than imitated.

## Acceptance target

- A fresh install can traverse all 41 onboarding states and arrive at the existing Home screen.
- Every reference state has a deterministic `-onboarding-step <id>` screenshot route.
- At 402 × 874 points, each app-owned screen passes overlay review against its reference with no
  unintended displacement greater than 4 points and no typography mismatch greater than 1 point.
- Back navigation, disabled buttons, selections, permission denial, app termination, and Settings
  round trips resume at the correct step.
- System-owned screens are reached with real APIs and remain outside the SwiftUI view hierarchy.
- Voice practice uses the production dictation pipeline; UI tests may inject a deterministic fake.
- Voice/text data choices are explicit, default-safe, and persisted separately from analytics.
- Onboarding completion is written only after the final offer acknowledgement, then the existing
  Home screen opens and remains the launch destination.

## Reference-to-Murmur screen map

| Reference | Murmur state | Required behavior |
|---|---|---|
| 01–03 | `welcome(page: 0...2)` | Three-page animated carousel, page dots, Get started |
| 04 | `useCases` | Multi-select cards; Next requires at least one selection |
| 05 | `personalizedExplainer` | Copy/visual selected from use-case answer |
| 06–08 | `signIn`, `signInOptions`, `emailSignIn` | Apple/Google and alternate methods; email validation |
| 09 | `setupIntro` | Starts the keyboard/setup phase |
| 10 | `keyboardInstructions` | Explains Settings steps and opens app Settings |
| 11–15 | `keyboardSettingsRoundTrip` | Real Settings UI; detect keyboard and Full Access on return |
| 16 | `practiceIntro` | Starts the three-part practice sequence |
| 17–18 | `microphonePrimer`, system prompt | Explain first, then request the real microphone permission |
| 19–23 | `basicPractice` | Keyboard picker guidance, live listening, text result, Next gate |
| 24–25 | `formattingPractice` | Prompted correction; require a non-empty production result |
| 26–29 | `whisperIntro`, `whisperPractice` | Intro media, listening state, formatted list result |
| 30 | `practiceComplete` | Completion/streak card; Continue commits practice completion |
| 31 | `wrapUpIntro` | Starts five-segment customization phase |
| 32 | `dataChoice` | Improve-model vs. do-not-share; no preselected unsafe consent |
| 33 | `languages` | Confirm detected keyboard languages; Edit opens language picker |
| 34 | `defaultStyle` | Formal, Casual, very casual, Excited; selection required |
| 35–36 | `notifications`, system prompt | Explain first, then request real notification authorization |
| 37 | `desktopOffer` | Email-link action and Another time path |
| 38–39 | `referralSource`, `referralDetail` | Conditional second question; selection required |
| 40 | `ready` | Final product explainer and Start Flowing |
| 41 | `trialOffer` | Server-backed entitlement copy and acknowledgement |
| 42 | existing Home | Onboarding no longer appears on normal launches |

The capture contains 42 images but 41 onboarding states: image 42 is the post-onboarding Home
destination.

## Architecture

### State model

Add `App/Sources/Onboarding/OnboardingState.swift`:

```swift
enum OnboardingStep: String, Codable, CaseIterable {
    case welcome1, welcome2, welcome3
    case useCases, personalizedExplainer
    case signIn, signInOptions, emailSignIn
    case setupIntro, keyboardInstructions
    case practiceIntro, microphonePrimer, basicPractice
    case formattingPractice, whisperIntro, whisperPractice, practiceComplete
    case wrapUpIntro, dataChoice, languages, defaultStyle, notifications
    case desktopOffer, referralSource, referralDetail, ready, trialOffer
    case complete
}
```

`OnboardingStore`, isolated to `@MainActor`, owns the current step, answers, permission snapshots,
and checkpoint version. Persist a compact `Codable` record in app-group defaults so a Settings
round trip or process termination cannot reset progress. Keep authentication session state in the
existing backend layer, not in this record.

Use explicit events (`next`, `back`, `permissionChanged`, `keyboardStatusChanged`,
`practiceCompleted`, `skipOptional`) and a pure reducer. Views must not set arbitrary next steps.
Reducer tests will cover every edge and make migrations possible when the flow changes.

### App routing

- `MurmurApp` chooses onboarding when `OnboardingStore.isComplete == false`.
- Present onboarding as a full-screen root, separate from the existing navigation stack.
- Extend `LaunchOptions` with `-onboarding-step <rawValue>`, `-onboarding-variant`, and
  `-permission-fixtures` for screenshots only.
- Deep links and keyboard session links continue to work. If setup is incomplete, a session link
  routes to the missing setup requirement rather than Home.
- Write `.complete` only after the trial-offer action succeeds or the server returns an explicit
  free-plan fallback.

### Files

```text
App/Sources/Onboarding/
  OnboardingRootView.swift
  OnboardingState.swift
  OnboardingStore.swift
  OnboardingReducer.swift
  Welcome/
  Auth/
  KeyboardSetup/
  Practice/
  Customize/
  Completion/
  Components/
App/Resources/Assets.xcassets/Onboarding/
Tests/MurmurTests/OnboardingReducerTests.swift
Tests/MurmurTests/OnboardingPersistenceTests.swift
Tests/MurmurUITests/OnboardingJourneyTests.swift
```

Shared visual primitives remain in `MurmurUI`: `SegmentedProgressHeader`, `SerifTitle`,
`PillButton`, `OptionCard`, and `PageDots`. Add components there only when at least two screens use
them; keep one-off compositions in the app target.

## Visual implementation

- Use the existing EB Garamond and Figtree font files and palette tokens.
- Establish a 402 × 874 reference canvas with safe-area-aware scaling; do not hard-code device
  pixels or status-bar content.
- Use a bottom action region with a stable 20-point horizontal inset and 54-point button height.
- Match progress segment counts by phase: intro dots, three practice segments, then five wrap-up
  segments.
- Recreate media panels with original SwiftUI illustrations/animations. Do not ship screenshots,
  Wispr logos, Slack artwork, or captured third-party app UI as production assets.
- Respect Reduce Motion by replacing looping media with its representative still frame.
- Add Dynamic Type guards through accessibility size XXXL; the pixel-parity baseline remains the
  default size used in the capture.

## Behavior details

### Authentication

Implement Apple and Google first because they are primary in the reference. “More options” may
show Microsoft, SSO, and email, but unavailable providers must be visibly marked rather than
silently failing. Authentication success advances to `setupIntro`; cancellation returns to the
same page without losing survey answers. Never store or screenshot authentication credentials.

### Keyboard setup

Use `SetupStatus` as the source of truth:

1. Show instructions and call `UIApplication.openSettingsURLString`.
2. On every active transition, refresh `keyboardAdded` and `fullAccessConfirmed`.
3. Display the real state when the user returns; do not render fake Settings pages in production.
4. Persist each confirmed requirement because enabling Full Access can terminate the process.
5. Block practice until the keyboard is added and Full Access is confirmed.

The screenshot harness may use annotated references for system screens, but automated functional
tests must assert the app’s before/after states rather than attempting to own Settings UI.

### Permissions

- Microphone: show the primer, call `SetupStatus.requestMicrophone()`, then branch on granted,
  denied, or restricted. Denied users get an Open Settings recovery action.
- Notifications: show the benefits page, request through `UNUserNotificationCenter`, and allow
  Maybe later. Denial must not block completion.
- Permission prompts are requested once, only after a direct user action.

### Practice exercises

- Basic: unlock Next after any committed text, whether typed or dictated.
- Formatting: seed the exact prompt and evaluate only completion/non-empty output, not a literal
  transcript, because recognition varies.
- Whisper: keep the same list prompt and visual proximity guidance; treat microphone volume as
  coaching, never as a hard biometric-like threshold.
- Reuse the production `DictationPipeline`. Add a protocol-backed `PracticeDictationClient` so UI
  tests can deterministically emit listening, partial, completed, and error states.
- Save exercise outputs to normal history only after onboarding completes, matching the resulting
  Home experience without creating duplicate entries during retries.

### Customization and consent

- Data sharing starts unselected. Record policy version, choice, and timestamp.
- Languages start from enabled iOS keyboard languages filtered through supported speech locales.
- Default style writes the existing `SharedSettings` value used by the keyboard.
- Referral answers are optional analytics metadata and must not affect product access.
- Desktop email action requires confirmation before sending and supports Another time.

### Trial offer

The offer must come from the backend entitlement response. Never promise two weeks when the
server did not grant it. Support three deterministic variants: granted trial, existing subscriber,
and free fallback. The captured two-week screen is the granted-trial visual baseline.

## Delivery phases

### Phase 1 — foundation and deterministic routing

- Add state, reducer, persistence, migration version, and root routing.
- Add screenshot launch arguments and fixture services.
- Add reducer and persistence tests.

Exit: every state can be opened deterministically and survives relaunch.

### Phase 2 — introduction and authentication (01–08)

- Build carousel, survey, personalized explainer, and auth pages.
- Integrate Apple/Google/email branches.
- Add visual snapshots and VoiceOver labels.

Exit: authenticated test user reaches setup intro with all prior answers preserved.

### Phase 3 — keyboard and permission setup (09–18)

- Integrate `SetupStatus`, Settings handoff, return-state UI, Full Access detection, microphone
  primer, prompt, and denial recovery.

Exit: physical-device test covers add keyboard → Full Access → microphone grant without manual
state repair.

### Phase 4 — practice sequence (19–30)

- Build keyboard coaching, three exercises, listening/results states, and completion page.
- Add fake dictation client tests and one production-pipeline device test.

Exit: exercises cannot advance early, recover from interruption, and produce the expected Home
history entries exactly once.

### Phase 5 — wrap-up and completion (31–42)

- Build consent, languages, style, notifications, desktop offer, referral survey, ready page,
  entitlement offer, and Home handoff.

Exit: fresh user completes the full journey; subsequent launches open Home.

### Phase 6 — visual parity and hardening

- Run the screenshot matrix at default text size on iPhone 16 Pro.
- Produce image overlays/diffs against all app-owned references.
- Exercise denial, cancellation, offline, server failure, termination, and migration cases.
- Test VoiceOver order, Reduce Motion, and large text.

Exit: all acceptance targets pass and the generated contact sheet has a one-to-one state match.

## Test matrix

### Unit

- Every reducer transition and illegal-transition rejection
- Resume checkpoints and version migration
- Required/optional selection gates
- Permission and keyboard-status branches
- Exactly-once completion and history seeding

### UI/screenshot

- One route per app-owned reference state
- Primary happy path from 01 to 42
- Back from every non-root screen
- Authentication cancellation
- Microphone denied then enabled in Settings
- Notification denied and Maybe later
- App termination at keyboard setup, each exercise, and the trial screen
- Granted-trial, subscriber, and free-plan offer variants

### Physical device

- Real Settings keyboard installation and Full Access toggle
- Real keyboard picker and Murmur keyboard activation
- Real microphone and notification prompts
- English and Russian practice dictation
- Background/foreground recovery and final Home launch

## Definition of done

- All states are implemented, localized, accessible, and reachable without debug-only shortcuts.
- Screenshot routes produce a numbered 01–42 parity set with no missing or duplicated states.
- No production screen embeds captured Wispr/third-party pixels or trademarks.
- The full physical-device journey passes twice: fresh install and interrupted/resumed install.
- Unit, UI, package, and app tests pass; the plan’s acceptance target is documented with a final
  overlay contact sheet.

## Implementation notes (2026-11-01)

Built in `App/Sources/Onboarding/` (state, reducer, store, persistence, services, fixtures, one folder
per phase), with the shared primitives in `MurmurUI` re-measured at 402 pt. Verified on the
simulator only (iPhone 16 Pro, iOS 26.5).

### Where it differs from the plan

- **One welcome step.** The carousel (01–03) is a single `welcome` step; the page is view state
  because the carousel autoplays. Routes: `-onboarding-step welcome -onboarding-variant
  dictionary|speed|languages` (references 01, 02 and 03, in capture order). Old checkpoints
  holding `welcome1`…`welcome3` migrate to `welcome`.
- **Full Access is confirmed in practice, not on return from Settings.** iOS only shows Full Access
  once the keyboard has run, so keyboard setup advances when the keyboard is detected (input-mode
  check, or a keyboard that has already reported Full Access). The practice screen checks Full
  Access once the Murmur keyboard is up and points to Settings if it never reports in.
- **A denied microphone can skip the exercises** (Open Settings, or "Skip the exercises" to the
  wrap-up), so onboarding can still finish.
- **Data choice starts unselected.** Reference 32 preselects sharing; the screenshot route uses
  `-onboarding-variant improve` to show the selected state.
- **Copy that would be untrue for Murmur was rewritten**: "Dozens of languages", the Full Access
  privacy note, "Improve Murmur for everyone", "Murmur is coming to your computer" (there is no
  desktop app: the action records an email for a link later), the streak card, and the free plan
  (1,000 words a week, from `quota_status`). Wispr, ChatGPT, Gmail and Slack artwork is replaced by
  original SwiftUI drawings; the Google and Microsoft buttons are text-only until the providers'
  official marks are added.
- **Email sign-in uses a six-digit code** (plus the emailed link) instead of password sign-up;
  `supabase/templates/sign_in_code.html` puts the code in the local emails.

### Parity results

`scripts/onboarding_parity.sh` shoots every state; `artifacts/onboarding-parity/contact-sheet.jpg`
is the 01–42 set and `compare-sheet.jpg` shows reference | Murmur | 50 % overlay for each.

- Text, buttons, cards and headers on the app-owned screens are within 3 pt vertically of the
  reference (measured row by row against the captures), and font sizes are within 1 pt.
- Larger deltas are not layout errors: the original illustrations on 35 and 41 have different
  shapes; 21, 23 and 27 compare against a reference that includes the text cursor; lines differ
  in width where "Murmur" or rewritten copy replaces the reference text.
- 07 was captured mid-animation, so only its settled positions (title, Google and Apple) are
  matched; 19 is a second capture of the microphone prompt and is shown as the keyboard-switch
  screen behind it; 11–15, 18 and 36 are iOS Settings and system prompts.
- At XXXL text, pages scroll above the buttons; larger accessibility sizes are capped at XXXL.

### Tests

- `OnboardingReducerTests` (every transition, gate, back and skip edge), `OnboardingPersistenceTests`
  (checkpoints, termination, migration, exactly-once completion and history seeding) and helper
  tests run in the Murmur scheme.
- `OnboardingJourney` scheme (`Tests/MurmurUITests`): fresh install to Home and relaunch, back with
  answers kept, unavailable providers and the email code, termination at keyboard setup, each
  exercise and the offer, and the trial, subscriber, free and offline offers.

### Still open

- **Sign in with Apple**: enable the capability for `com.antonmironenko.murmur` (ASC), regenerate
  the profiles (`scripts/provision_dev.mjs`), add `com.apple.developer.applesignin` to the app
  entitlements, and turn on `[auth.external.apple]` with the bundle ID as client ID in Supabase.
- **Google**: an OAuth client in the Supabase project (`[auth.external.google]`).
- **Legal links**: set `MURMUR_TERMS_URL` and `MURMUR_PRIVACY_URL` (`Config/Base.xcconfig`); until then
  the sign-in footnote shows them as plain text.
- **Physical device**: the plan's device matrix (Settings round trip with Full Access, the keyboard
  picker, real prompts, English and Russian practice, background recovery) hasn't been run.
- The keyboard itself doesn't show the reference's coaching captions ("Tap the mic to start
  speaking →", "Congrats 🎉") during practice, and Settings has no picture-in-picture guide.
