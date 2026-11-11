# Murmur

A voice keyboard for iOS. You dictate in any app, OpenAI transcribes the speech, and an OpenAI
model cleans up the text before the keyboard inserts it. "Murmur" is a working name: it is set in
`Config/Base.xcconfig` and `Brand.swift`.

The product plan, decisions, design system and phases are in [docs/PLAN.md](docs/PLAN.md).
Onboarding is described in [docs/ONBOARDING.md](docs/ONBOARDING.md).

## How it works

A custom keyboard can't use the microphone, so the app does the recording. The first dictation
opens the app briefly: it starts a background audio session, shows a Live Activity, starts
recording, and sends you back to the app you were typing in (or, for apps it can't reopen, asks
you to swipe back). Later dictations reuse that session until it times out ("Turn off after"),
which only counts while the keyboard is off screen.

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
| `Keyboard/` | The keyboard extension: the voice keyboard, UIKit key grid, SwiftUI toolbar, overlays and listening panel |
| `Widgets/` | The Live Activity UI |
| `Shared/Activity/` | Live Activity attributes and intents, compiled into the app and the widget extension |
| `Packages/MurmurKit/` | `MurmurCore` (IPC, keyboard session client, text utilities), `MurmurBrand` (color tokens, the mark, the echo rings) and `MurmurUI` (type roles, components) |
| `Tools/BrandKit/` | Draws the app icon and launch assets from the mark (`scripts/build_brand.sh`) |
| `site/` | The website's pages and stylesheet (`scripts/build_site.mjs`, `scripts/publish_site.sh`) |
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

# UI tests: the onboarding journey on fake services (sign-in, Settings, prompts and dictation are
# simulated), and every screen through the menu
xcodebuild -project Murmur.xcodeproj -scheme OnboardingJourney \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro (Onboarding)' test

# The app icon, launch logo and asset colors are drawn from code; --check fails if they drifted
scripts/build_brand.sh --check

# No leftover mention of the apps Murmur was once modelled on
scripts/check_no_wispr.sh
```

## Onboarding

A fresh install opens onboarding (`App/Sources/Onboarding/`) instead of Home; its steps and rules
are in [docs/ONBOARDING.md](docs/ONBOARDING.md). Each screen sends events to `OnboardingReducer`,
a pure state machine; the checkpoint is saved in the App Group after every step, so going to
Settings, a permission change or a termination resumes on the same screen. Completion is written
only after the plan offer is acknowledged, and the practice dictations then land in history once.

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

The keyboard listens for any language by default (Speak › Auto-detect): OpenAI hears which one it
is, and the dictation is formatted, cleaned up and filed in it. Pinning a language in the Speak
menu sends it to OpenAI instead. The app records the dictation, compresses it to AAC and sends it
to the `transcribe` function (or `dictate`, below), which passes it to OpenAI (`gpt-transcribe`)
with the language, if any, and the personal dictionary as keyword hints; the audio isn't stored.
If OpenAI can't be reached, a language whose on-device model is already installed is recognized on
the iPhone instead; under Auto-detect that is the language of the last dictation, else the
iPhone's. Without a backend, or with Settings › Debug › Recognizer set to On-device, recognition
is on-device only, in the primary language. Until they are picked, the letters and the
translation target follow the iPhone's language (ЙЦУКЕН on a Russian iPhone).

## Modes

Two, in the keyboard's style chip and the menu's Style:
- **Word for word** (the default): your words as spoken, punctuated. The AI runs only when the
  transcript has no punctuation, a spoken command ("comma", "new line") or a spelled-out address.
- **Improve my grammar**: the same words and tone, made grammatically correct; fillers and false
  starts go. Sent in the request that transcribes (`dictate`), so it costs no extra round trip.

Builds from before November 2026 still send the old styles; the functions read them as Improve my
grammar. The **primary** language is the explicit choice in Settings › Languages, else the
first of the iPhone's preferred languages that an engine supports, else US English. A
**secondary** language adds a switch (RU / EN) to the keyboard toolbar.

On the device, for each language the app tries `SpeechTranscriber` first and `DictationTranscriber` second: it
downloads the model, runs half a second of silence through it as a validation (Apple's locale
list has misreported support before) and remembers the engine that passed, per OS version.
Settings › Languages › Verify re-runs that check; Speech diagnostics lists what the device
reports. The cleanup prompt gets the dictation's BCP-47 tag and applies the matching language
pack (Russian fillers, self-corrections, «ёлочки», 24-hour times, «25 000 ₽», loanwords stay in
Cyrillic, brands in Latin).

## Keyboard

The default is the voice keyboard:
- a bar with the menu, outlined chips for translation and the style, and Delete;
- a big ink talk button with a ring around it, which turns red with ✓ and echo rings that follow
  the voice while it listens (nothing else on the keyboard is red);
- space and return.

It is 278 pt tall (272 in landscape). It can't dictate without Allow Full Access, so until that is
on the keyboard shows Numbers first, where typing works. Settings › Keyboard › Layout also offers
Numbers first and QWERTY, with the same chips and a listening panel. The menu button opens the
keyboard's own page: translation, Add to dictionary, haptics, the ready vibration, start and stop
sounds, and Light / Dark / Auto, with ABC and a link to Murmur's Settings.

Debug builds can pin any keyboard state for screenshots: launch the app with
`-keyboard-demo <state>[@voice|@numbers|@qwerty]` (e.g. `listening@numbers`; the states are in
`KeyboardDemo`), or pick one in Settings › Debug › Keyboard demo. A demo ends after 15 minutes or at
the app's next launch.

## Backend (Supabase)

Requires Docker, the Supabase CLI and Deno (`brew install supabase/tap/supabase deno`).

```sh
supabase start                       # local Postgres, Auth, Edge Runtime; applies supabase/migrations
supabase test db                     # pgTAP: RLS, quota, rate limits (supabase/tests)
deno test --allow-env supabase/functions/          # offline cleanup tests: prompt blocks, guards, validation (English, Russian, translation)
supabase functions serve             # serve functions locally; loads supabase/functions/.env (put OPENAI_API_KEY there)
scripts/smoke_functions.sh           # HTTP checks: auth, 401/400/402, an English and a Russian cleanup, auth helpers, delete-account

# Live model checks (cost money): English, Russian and translation goldens plus a Russian latency / token-size probe.
RUN_GOLDEN=1 OPENAI_API_KEY=... deno test --allow-env --allow-net supabase/functions/cleanup/golden_test.ts

# Model comparison (cost money; OPENAI_API_KEY and ANTHROPIC_API_KEY in supabase/functions/.env).
# Text step: OpenAI and Claude models on Word for word, Improve my grammar and translation cases,
# graded blind by gpt-6-astra and claude-opus-5-5. --dry-run shows the plan.
deno run --allow-env --allow-net --allow-read --allow-write --env-file=supabase/functions/.env \
  scripts/bench/text_bench.ts --out <dir>
# Speech: gpt-transcribe with Auto-detect vs a chosen language, on clips the Mac speaks in ten languages.
deno run --allow-env --allow-net --allow-read --allow-write --allow-run --env-file=supabase/functions/.env \
  scripts/bench/transcribe_bench.ts --out <dir>
```

The `cleanup` function sends OpenAI's Responses API one system prompt in three parts — the shared
rules, a language pack (English, Russian, or one named after any other language; with no tag, one
that keeps whatever language the transcript is in) and the
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

**Translation.** With the keyboard's *Translate as you speak* on, the request carries a
`targetLanguage` and `cleanup` translates instead: its own system prompt (translation rules with
cross-language examples, then the language pair, style, dictionary and snippets; cache key
`murmur-translate`), never the cleanup rules and language packs, which all say to keep the spoken
language. A reply still in the spoken language comes back `raw` with `reason: "untranslated"`, and
every reply echoes `targetLanguage`. The app inserts a translation only when that echo is there, so a
`cleanup` function deployed before translation, which ignores the target and cleans up in the
spoken language, shows "Translation isn't available right now" instead of inserting the wrong
language. Redeploy the function together with an app build that translates:
`supabase functions deploy cleanup`.

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
5. Murmur opens once and takes you back to Notes (in an app it can't reopen, swipe right along
   the bottom edge). It's already listening: speak and tap the red stop button.
6. Home lists every dictation by day: tap to copy, swipe for Copy, Retry / Regenerate and Delete,
   hold a row for its details (the raw transcript and timings). Settings › Debug shows median / p95 latencies and the
   engine in use; the keyboard toolbar shows the extension's remaining memory in Debug builds.
