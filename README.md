# Murmur

A Wispr Flow–style voice keyboard for iOS. You dictate in any app, the iPhone transcribes the
speech on-device, and Claude cleans up the text before the keyboard inserts it. "Murmur" is a
working name: it is set in `Config/Base.xcconfig` and `Brand.swift`.

The plan, decisions and phases are in [docs/PLAN.md](docs/PLAN.md).

## How it works

A custom keyboard can't use the microphone, so the app does the recording. The first dictation
opens the app briefly. It starts a background audio session and shows a Live Activity. You then
swipe back to your app, and later dictations reuse that session until it times out
("Disable after").

```
Keyboard ext ──command file + Darwin notify──► App session (hot mic) ──► SpeechAnalyzer
     ▲ libnotify state (status, mic level)                                    │
     └────────────── result file {requestId, documentIdentifier, text} ◄─────┘
```

## Layout

| Path | What it is |
|---|---|
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, not committed. |
| `App/` | The app: session controller, dictation pipeline (per-language engine selection, Claude cleanup), SwiftData history, Home / Settings / Debug screens |
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
```

## Languages

Recognition runs on the device in one language per dictation; there is no automatic language
detection. The **primary** language is the explicit choice in Settings › Languages, else the
first of the iPhone's preferred languages that an engine supports, else US English. A
**secondary** language adds a switch (RU / EN) to the keyboard toolbar.

For each language the app tries `SpeechTranscriber` first and `DictationTranscriber` second: it
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
supabase functions serve             # serve functions locally; loads supabase/functions/.env (put ANTHROPIC_API_KEY there)
scripts/smoke_functions.sh           # HTTP checks: auth, 401/400/402, an English and a Russian cleanup, auth helpers, delete-account

# Live model checks (cost money): English and Russian goldens plus a Russian latency / token-size probe.
RUN_GOLDEN=1 ANTHROPIC_API_KEY=... deno test --allow-env --allow-net supabase/functions/cleanup/golden_test.ts
```

The `cleanup` function sends Claude three cached system blocks — the shared rules, a language pack
(English or Russian, picked from the request's `language` tag) and the per-user context — so every
user of a language shares one cache entry. Environment knobs (`supabase/functions/.env` locally,
`supabase secrets set NAME=value` for a hosted project):

| Variable | Default | What it does |
|---|---|---|
| `ANTHROPIC_API_KEY` | — | Required. Without it every cleanup answers 502 and the app inserts its locally formatted text. |
| `CLEANUP_MODEL` | `claude-opus-5-5` | The model (effort `low`). |
| `CLEANUP_TIMEOUT_MS` | `5000` | Time allowed for Anthropic's response headers; a timed-out request is retried once. |
| `CLEANUP_DEADLINE_MS` | `9000` | Hard bound on the whole call including the streamed body; keep it below the app's request timeout. |
| `CLEANUP_DISABLED` | unset | `1` answers 503 before any database or model call (kill switch). |

Anonymous (trial) users are limited to 10 cleanups per minute and 6 000-character transcripts.
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
