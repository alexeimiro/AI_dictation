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
| `App/` | The app: session controller, dictation pipeline, screens |
| `Keyboard/` | The keyboard extension: UIKit key grid, SwiftUI toolbar and listening panel |
| `Widgets/` | The Live Activity UI |
| `Shared/Activity/` | Live Activity attributes and intents, compiled into the app and the widget extension |
| `Packages/MurmurKit/` | `MurmurCore` (IPC, keyboard session client, text utilities) and `MurmurUI` (design tokens, components) |
| `supabase/` | Backend (Phase 2) |

## Setup

```sh
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM
xcodegen generate
open Murmur.xcodeproj
```

## Tests

```sh
# Fast logic tests on the Mac (IPC, keyboard state machine, text utilities)
swift test --package-path Packages/MurmurKit

# Everything on the simulator
xcodebuild -project Murmur.xcodeproj -scheme Murmur \
  -destination 'platform=iOS Simulator,name=iPhone 16 (Murmur)' test
```

## Backend (Supabase)

Requires Docker, the Supabase CLI and Deno (`brew install supabase/tap/supabase deno`).

```sh
supabase start                       # local Postgres, Auth, Edge Runtime; applies supabase/migrations
supabase test db                     # pgTAP: RLS, quota, rate limits (supabase/tests)
deno test --allow-env supabase/functions/          # cleanup prompt/guard/request-shape tests
supabase functions serve             # serve functions locally (needs supabase/functions/.env for secrets)
scripts/smoke_functions.sh           # HTTP checks: auth, 401/400/402, auth helpers, delete-account

# Live model checks (cost money):
RUN_GOLDEN=1 ANTHROPIC_API_KEY=... deno test --allow-env --allow-net supabase/functions/cleanup/golden_test.ts
```

Secrets for a hosted project: `supabase secrets set ANTHROPIC_API_KEY=...`. The optional
`CLEANUP_MODEL` secret overrides the model (default `claude-opus-5-5`, effort `low`). To use the
backend from the app, set `SUPABASE_HOST` and `SUPABASE_ANON_KEY` in `Config/Local.xcconfig`.

## Trying it on an iPhone

1. Run the `Murmur` scheme on the device.
2. In Settings › Murmur › Keyboards, turn on **Murmur** and **Allow Full Access**.
3. Open Notes, switch to the Murmur keyboard (globe key) and tap the mic.
4. Murmur opens once. Swipe right along the bottom edge to go back, then speak and tap ✓.
5. The Debug screen in the app shows per-dictation timings (ASR and total). The keyboard
   toolbar shows the extension's remaining memory in Debug builds.
