# Murmur

A Wispr Flow–style voice keyboard for iOS. You dictate in any app, OpenAI transcribes the
speech, and an OpenAI model cleans up the text before the keyboard inserts it. "Murmur" is a
working name: it is set in `Config/Base.xcconfig` and `Brand.swift`.

The product plan, decisions and phases are in [docs/PLAN.md](docs/PLAN.md). The implementation
plan for matching the complete 42-screen reference onboarding is in
[docs/ONBOARDING_PARITY_PLAN.md](docs/ONBOARDING_PARITY_PLAN.md).

## How it works

A custom keyboard can't use the microphone, so the app does the recording. The first dictation
opens the app briefly. It starts a background audio session and shows a Live Activity. You then
swipe back to your app, and later dictations reuse that session until it times out
("Disable after").

```
Keyboard ext ──command file + Darwin notify──► App session (hot mic) ──► transcribe fn (OpenAI)
     ▲ libnotify state (status, mic level)                                    │   └► cleanup fn (OpenAI)
     └────────────── result file {requestId, documentIdentifier, text} ◄─────┘
```

## Layout

| Path | What it is |
|---|---|
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, not committed. |
| `App/` | The app: session controller, dictation pipeline (OpenAI transcription and cleanup, on-device fallback), SwiftData history, onboarding, Home / Settings / Debug screens |
| `Keyboard/` | The keyboard extension: UIKit key grid, SwiftUI toolbar and listening panel |
| `Widgets/` | The Live Activity UI |
| `Shared/Activity/` | Live Activity attributes and intents, compiled into the app and the widget extension |
| `Packages/MurmurKit/` | `MurmurCore` (IPC, keyboard session client, text utilities) and `MurmurUI` (design tokens, components) |
| `supabase/` | Backend: migrations, the `cleanup` Edge Function (English and Russian language packs), tests |

## Setup

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen generate
open Murmur.xcodeproj
```

## Tests

```sh
# Fast logic tests on the Mac (IPC, keyboard state machine, English and Russian text rules, history logic)
swift test --package-path Packages/MurmurKit

# Everything on the simulator (adds the deep-link, history store and re-cleanup tests)
xcodebuild -project Murmur.xcodeproj -scheme Murmur \
  -destination 'platform=iOS Simulator,name=iPhone 16 (Murmur)' test

# Screenshots of every screen with seeded history (scripts/out/*.png)
scripts/screenshots.sh

# The onboarding journey on fake services: sign-in, Settings, prompts and dictation are simulated
xcodebuild -project Murmur.xcodeproj -scheme OnboardingJourney \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro (Onboarding)' test

# Every onboarding state next to its reference (build/onboarding-parity/*-compare.png)
scripts/onboarding_parity.sh
```

## Onboarding

A fresh install opens onboarding (`App/Sources/Onboarding/`) instead of Home: the 42-screen
journey in [docs/ONBOARDING_PARITY_PLAN.md](docs/ONBOARDING_PARITY_PLAN.md), with Murmur's own
copy and artwork. Each screen sends events to `OnboardingReducer`, a pure state machine; the
checkpoint is saved in the App Group after every step, so going to Settings, a permission change or
a termination resumes on the same screen. Completion is written only after the plan offer is
acknowledged, and the practice dictations then land in history once.

- Installs that already have history or a keyboard that has run skip it; Settings › Debug ›
  Replay onboarding starts it again.
- Screenshot routes: `-onboarding-step <step>` with `-onboarding-variant <name>` and
  `-permission-fixtures keyboard,fullAccess,mic=granted` (fixture data, nothing persisted).
  `-onboarding-fixtures` runs the whole journey on fake services; `-onboarding-reset` restarts it.
- Sign-in uses Supabase: Apple (native, needs the Sign in with Apple capability), Google (OAuth;
  needs a Google client in the Supabase project) and email (a six-digit code; locally the email
  arrives in the mail catcher at http://127.0.0.1:54324). A build without a backend offers
  "Continue without an account".

## Languages

Each dictation is transcribed in one language, chosen per dictation; there is no automatic
language detection. By default the app records the dictation, compresses it to AAC and sends it to
the `transcribe` function, which passes it to OpenAI (`gpt-transcribe`) with the language and the
personal dictionary as keyword hints; the audio isn't stored. If OpenAI can't be reached, a
language whose on-device model is already installed is recognized on the iPhone instead. Without
a backend, or with Settings › Debug › Recognizer set to On-device, recognition is on-device only. The **primary** language is the explicit choice in Settings › Languages, else the
first of the iPhone's preferred languages that an engine supports, else US English. A
**secondary** language adds a switch (RU / EN) to the keyboard toolbar.

On the device, for each language the app tries `SpeechTranscriber` first and `DictationTranscriber` second: it
downloads the model, runs half a second of silence through it as a validation (Apple's locale
list has misreported support before) and remembers the engine that passed, per OS version.
Settings › Languages › Verify re-runs that check; Speech diagnostics lists what the device
reports. The cleanup prompt gets the dictation's BCP-47 tag and applies the matching language
pack (Russian fillers, self-corrections, «ёлочки», 24-hour times, «25 000 ₽», loanwords stay in
Cyrillic, brands in Latin).

## Backend (Supabase)

Requires Docker, the Supabase CLI and Deno (`brew install supabase/tap/supabase deno`).

```sh
supabase start                       # local Postgres, Auth, Edge Runtime; applies supabase/migrations
supabase test db                     # pgTAP: RLS, quota, rate limits (supabase/tests)
deno test --allow-env supabase/functions/          # offline cleanup tests: prompt blocks, guards, validation (English + Russian)
supabase functions serve             # serve functions locally; loads supabase/functions/.env (put OPENAI_API_KEY there)
scripts/smoke_functions.sh           # HTTP checks: auth, 401/400/402, an English and a Russian cleanup, auth helpers, delete-account

# Live model checks (cost money): English and Russian goldens plus a Russian latency / token-size probe.
RUN_GOLDEN=1 OPENAI_API_KEY=... deno test --allow-env --allow-net supabase/functions/cleanup/golden_test.ts
```

The `cleanup` function sends OpenAI's Responses API one system prompt in three parts — the shared
rules, a language pack (English or Russian, picked from the request's `language` tag) and the
per-user context last — so every user of a language shares the cached prefix (`prompt_cache_key`
per language). Requests are sent with `store: false`. Environment knobs (`supabase/functions/.env` locally,
`supabase secrets set NAME=value` for a hosted project):

| Variable | Default | What it does |
|---|---|---|
| `OPENAI_API_KEY` | — | Required by `cleanup` and `transcribe`. Without it cleanup answers 503 and the app inserts its locally formatted text, and transcription answers 503 and the app falls back to on-device recognition where a model is installed. |
| `CLEANUP_MODEL` | `gpt-6-astra` | The cleanup model (`gpt-6.1-sol` costs less; `gpt-6.1-terra` is faster). |
| `CLEANUP_EFFORT` | `low` | Reasoning effort (`none` works on Terra and Luna only). |
| `CLEANUP_DEADLINE_MS` | `9000` | Hard bound on the whole call; keep it below the app's 11 s request timeout. |
| `CLEANUP_DISABLED` | unset | `1` answers 503 before any database or model call (kill switch). |
| `TRANSCRIBE_MODEL` | `gpt-transcribe` | OpenAI's transcription model. Older models (`gpt-4o-transcribe`, shut down 2027-02-26) get the language and terms as `language` / `prompt`. |
| `TRANSCRIBE_DEADLINE_MS` | `20000` | Bound on the OpenAI call; keep it below the app's 25 s request timeout. |
| `TRANSCRIBE_DISABLED` | unset | `1` answers 503 before any database or model call (kill switch). |

Anonymous (trial) users are limited to 10 cleanups and 10 transcriptions per minute and 6 000-character
transcripts. On the free plan, once the week's words are used up, `transcribe` answers 402 too.
To use the backend from the app, set `SUPABASE_HOST` and `SUPABASE_ANON_KEY` in
`Config/Local.xcconfig` (the example file documents the `host:port` form for the local stack).

## Trying it on an iPhone

1. `scripts/device_build.sh` (builds, signs with the App Store Connect API key and installs).
2. In Settings › Murmur › Keyboards, turn on **Murmur** and **Allow Full Access**.
3. In Murmur › Settings › Languages pick the primary language (Russian downloads its model the
   first time) and, optionally, a secondary one for the keyboard's language switch.
4. Open Notes, switch to the Murmur keyboard (globe key) and tap the mic.
5. Murmur opens once. Swipe right along the bottom edge to go back, then speak and tap ✓.
6. Home lists every dictation by day: tap to copy, swipe for Retry / Regenerate / Delete, open a
   row for the raw transcript and timings. Settings › Debug shows median / p95 latencies and the
   engine in use; the keyboard toolbar shows the extension's remaining memory in Debug builds.
