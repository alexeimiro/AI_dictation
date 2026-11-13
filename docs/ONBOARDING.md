# Onboarding

A fresh install opens onboarding (`App/Sources/Onboarding/`) instead of Home. It signs the user in,
gets the keyboard and the microphone set up, lets them try three dictations, records a few choices
and shows the plan the server granted. This document describes how it behaves and how it is built
and tested.

## The journey

The bar at the top of a page counts four parts: what the user wants help with, the keyboard, a try,
and their choices. The steps are the cases of `OnboardingStep`, in this order:

| Step | Page | Moves on when |
|---|---|---|
| `welcome` | Three pages that turn by themselves or with a swipe; the page is view state | "Get started" |
| `useCases` | "What do you want help with?" Any number of answers | At least one answer |
| `personalizedExplainer` | What Murmur does for the first answer | "Next" |
| `signIn`, `signInOptions`, `emailSignIn` | Apple, Google; "More options" adds email with a six-digit code | A sign-in succeeds |
| `setupIntro` | Opens the second part | "Set up" |
| `keyboardInstructions` | What to turn on in Settings, and the way there | The keyboard is detected on return |
| `practiceIntro` | Opens the third part | "Try Murmur" |
| `microphonePrimer` | Why the microphone, before the system asks; its button first asks "Before Murmur listens" | Access is granted |
| `basicPractice` | Say anything; first shows how to switch keyboards | Any text in the box, typed or dictated |
| `formattingPractice` | Dictate an email and change it halfway | A dictation |
| `whisperIntro`, `whisperPractice` | Whisper a note | A dictation |
| `practiceComplete` | A tick for each exercise done | "Continue" |
| `wrapUpIntro` | Opens the last part | "Next" |
| `dataChoice` | What Murmur may do with voice and text; nothing preselected | A choice |
| `languages` | The iPhone's own languages, to confirm or edit | At least one language |
| `defaultStyle` | Word for word or Improve my grammar | A style (Word for word is preselected) |
| `notifications` | What they are for, then the system prompt | Allowed, denied or "Not now" |
| `desktopOffer` | A link by email when Murmur for Mac and PC exists | Requested or "No thanks" |
| `referralSource`, `referralDetail` | "How did you find Murmur?" and, for a search engine, which | An answer |
| `ready` | "You're set." | "Start dictating" |
| `trialOffer` | The plan the server granted: a trial, Pro or Basic | "Get started", once the plan has loaded |
| `complete` | Home | |

Skip sits in the bar on the exercises and the style page. Back goes to the previous page, except
on the pages that open a part, `ready` and `trialOffer`, which have none.

## Rules worth knowing

- **Sign-in.** A session kept in the Keychain from an earlier install skips the page. A build
  without a backend offers "Continue without an account". Cancelling a sign-in keeps the survey's
  answers.
- **Keyboard setup.** `SetupStatus` is the source of truth. The page opens the app's Settings, and
  on every return to the foreground the app checks again. Each confirmed requirement is saved,
  because turning on Full Access can terminate the app.
- **Full Access is confirmed in practice, not on return from Settings.** iOS only shows it once the
  keyboard has run. Setup moves on when the keyboard is detected; the first exercise checks Full
  Access once the Murmur keyboard is up and points to Settings if the keyboard never reports in.
- **Microphone.** The page explains first and asks once, after a tap. If access is denied or
  restricted it offers Settings, or "Skip the exercises", which goes to the last part.
- **The AI question.** That tap first shows "Before Murmur listens" (`AIConsentView`): a recording
  goes to OpenAI and its text to Anthropic, with Allow and Not now. It isn't a step of the journey:
  the session asks the same question before it turns the microphone on, wherever that happens, so
  someone who skips the exercises is asked at their first dictation. "Not now" stays on the page.
- **Exercises.** The box is a real text view, so a dictation runs through the real keyboard and
  session. The takes are held until onboarding completes and then copied into history once, one
  entry per exercise.
- **Data choice.** The decision is saved with the policy version and the time. Bump
  `DataChoiceDecision.currentPolicyVersion` when the two options' wording changes meaning.
- **Languages.** They start from the iPhone's preferred languages that dictation supports (not
  from its keyboards: what the list of keyboards says may not leave the iPhone). The first becomes
  the primary language and the second the keyboard's switch.
- **Desktop link.** The page asks for confirmation before it records the email address.
- **Plan.** The last page shows what the server answered, never a promise of its own. If the
  account was signed out meanwhile, it offers the sign-in sheet instead of a retry that can't work.
- **Completion** is written only when the plan page is acknowledged. After that the app opens on
  Home. Installs that already have history or a keyboard that has run skip onboarding; in a Debug
  build, Settings › Debug › Replay onboarding starts it again.
- **A keyboard link during onboarding** (the keyboard asking the app to listen) goes to whichever
  of the keyboard and the microphone is still missing.

## How it is built

- `OnboardingState.swift`: the steps, the answers, the permission snapshot and the events.
- `OnboardingReducer.swift`: a pure state machine. Pages send events; only the reducer decides the
  next step, and it returns nil for an event the current step doesn't allow.
- `OnboardingStore.swift`: applies events and saves the checkpoint before observers see it.
- `OnboardingPersistence.swift`: the checkpoint in the App Group's defaults, read leniently so a
  checkpoint written by another build never strands anyone.
- `OnboardingServices.swift`: sign-in, the plan, languages, notifications and the profile, each
  behind a protocol with a fake for tests and screenshots.
- `OnboardingCopy.swift`: every line onboarding shows. The UI tests compile it too.
- `Components/`: the page layout (`OnboardingPage`, `OnboardingTitle`, `IntroPage`) and the
  pictures (`OnboardingScenes.swift`). The pictures are drawn from the app's own parts; what moves
  in them stands still under Reduce Motion.
- One folder per part of the journey holds its pages: `Welcome/`, `Auth/`, `KeyboardSetup/`,
  `Practice/`, `Customize/`, `Completion/`.

Text grows up to the XXXL size; the accessibility sizes beyond it are capped. A page's content
scrolls under its buttons when it doesn't fit.

## Screenshots and fixtures

- `-onboarding-step <step>` opens that page with fixture data and fake services; nothing persists
  and nothing prompts. `-onboarding-variant <name>` picks one of its states:
  - `welcome`: `talk`, `languages`, `dictionary`
  - `keyboardInstructions`: `partial` (the keyboard already added)
  - `microphonePrimer`: `denied`
  - the exercises: `guide`, `listening`, `result`
  - `dataChoice`: `improve`, `doNotShare`
  - `trialOffer`: `trial`, `subscriber`, `free`, `offline`
- `-permission-fixtures keyboard,fullAccess,mic=granted,notifications=denied` fixes the setup state.
- `-onboarding-fixtures` runs the whole journey on fake services with its own checkpoint, and
  `-onboarding-reset` starts it over.
- A run on fake services is allowed to listen without being asked. `-ai-consent` has it ask
  "Before Murmur listens" where a real run would, and `-ai-consent show` puts the question over
  the launch (for a screenshot).

```sh
SIM="iPhone 17 Pro (Redesign)" DD=build/RedesignDD scripts/screenshots.sh \
  "welcome=-onboarding-step welcome" \
  "trial=-onboarding-step trialOffer -onboarding-variant trial"
```

## Tests

- `OnboardingReducerTests`: every transition, gate, back and skip.
- `OnboardingPersistenceTests`: checkpoints, termination, migration, and completion and history
  seeding exactly once.
- The `OnboardingJourney` scheme (`Tests/MurmurUITests/OnboardingJourneyTests.swift`), on fake
  services: a fresh install to Home and the next launch; back with answers kept; the welcome's
  pages; the email code; termination at keyboard setup, each exercise and the plan; the trial, Pro,
  Basic and offline plans; and a sign-out before the plan.

## What the tests don't cover

- Only an iPhone can check the Settings round trip with Full Access, the keyboard picker, the real
  prompts, and practice through the real keyboard in English and Russian.
- The Google button has no Google mark: it needs the provider's official asset.
