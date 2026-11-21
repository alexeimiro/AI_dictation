# Redmic on the App Store: listing, review notes, privacy answers

Texts for App Store Connect, app "Redmic: Voice Keyboard" (Apple ID 6829429992; "Murmur: Voice
Keyboard" until 1.0.5), version 1.0.5. Character limits are App Store Connect's. Since 1.0.5 the
listing goes in through the API with a script that leaves the subscriptions' review screenshots
alone; `node scripts/fill_app_store_listing.mjs` would replace them, so it is for a first listing
only.

## Listing

**App name** (30): `Redmic: Voice Keyboard`

**Subtitle** (30): `Talk instead of typing`

**Promotional text** (170):
> Switch to Redmic in any text field and talk. It writes what you say, spelled your way, in four modes. Speak 65 languages and type in 91, with Translate one tap away.

**Keywords** (100):
`dictation,voice typing,speech to text,keyboard,transcribe,translate,voice notes,talk to text,dictate`

**Description** (4,000):
> Redmic is a keyboard that writes what you say. Switch to it in any text field, tap the mic and talk. Your words arrive in seconds: punctuated, with "um" and "uh" gone, and with names spelled the way you spell them.
>
> WRITE WHEREVER YOU WRITE
> Messages, email, notes, documents, chats with AI. Switch to the Redmic keyboard, tap the mic, talk, and tap the check mark.
>
> FOUR WAYS TO WRITE
> Word-to-Word keeps exactly what you said, in the order you said it, punctuated. Rewrite fixes grammar and sentence structure and cuts repetition, keeping your meaning, facts and tone. Email turns it into a clear, polite email. Funny makes it playful, with a light joke or an emoji or two, and keeps every fact. Pick one on the Style screen or from the keyboard.
>
> TRANSLATE AS YOU SPEAK
> Speak 65 languages and type in 91. Speak one language and type in another: Redmic detects the language you speak, and one tap on the keyboard turns translation on or off.
>
> IT LEARNS YOUR WORDS
> Add names, brands and jargon, or fix a word Redmic keeps mishearing. Add a word straight from the keyboard.
>
> SNIPPETS
> Say "my calendar link" and Redmic types the link. Save anything you type often.
>
> NOTES
> A place to say a thought and keep it, on all your devices.
>
> ACTION BUTTON AND CONTROL CENTER
> Start and stop a dictation without touching the keyboard.
>
> YOU ALWAYS KNOW WHEN IT LISTENS
> Whenever the microphone is open, Redmic shows it: a red dot in the app, and its mark in the Dynamic Island and on the Lock Screen, all red while you dictate. Lock your iPhone and the microphone turns off within about a minute. Redmic asks before your first recording leaves your iPhone: OpenAI turns it into text, and Anthropic tidies or translates the text. Neither trains AI models on it. Your history of transcripts and recordings stays on your iPhone.
>
> REDMIC PRO
> Redmic is free with 1,000 words a week, after a 14-day trial of Pro, one per iPhone; accounts on the same iPhone share its free words. Redmic Pro has no weekly limit: $9.99 a month or $79.99 a year. Payment is charged to your Apple Account, and the subscription renews automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel it in Settings › Apple Account › Subscriptions.
>
> Terms of Use: https://simplymurmur.com/terms/
> Privacy Policy: https://simplymurmur.com/privacy/

**What's New in 1.0.5** (4,000):
> Murmur is now Redmic: a new name and a red logo, the same app and your same account.
> • Four writing modes: Word-to-Word, Rewrite, Email and Funny. Pick one on the new Style screen or from the keyboard's style button.
> • Speak 65 languages and type in 91.
> • Translate on or off in one tap, from the keyboard's bar, which shows the languages it translates between.
> • Easier on your battery: when you lock your iPhone, the microphone turns off after about a minute.
> • Dictations upload about half as much data.
> • On the free plan, accounts on the same iPhone now share its 1,000 words a week.

**Category**: Productivity (secondary: Utilities)

**Support URL**: `https://simplymurmur.com/support/`

**Marketing URL**: `https://simplymurmur.com/`

**Privacy Policy URL**: `https://simplymurmur.com/privacy/`, from `docs/legal/privacy-policy.md`.

**Copyright**: `2026 OKNENOR L.L.C-FZ`

## Screenshots

The 6.9" set (1320 × 2868) is taken on an iPhone 17 Pro Max simulator from a Debug build with sample
data, into `build/app-store-screenshots`, which `scripts/fill_app_store_listing.mjs` uploads in
file name order. Home's history is `-history-fixture showcase`: only dictations that went through,
so no row has a "Failed" or "Limit reached" badge. The paywall shot, at 1290 × 2796, is also each
subscription's review screenshot: App Store Connect has taken that size for them, and refused a
1178 × 2556 one.

```sh
SIM="iPhone 17 Pro Max" DD=build/DerivedData OUT=build/app-store-screenshots scripts/screenshots.sh \
  "1-home=-route home -session-fixture on -history-fixture showcase" \
  "2-note=-route note -session-fixture listening" \
  "3-dictionary=-route dictionary" \
  "4-snippets=-route snippets" \
  "5-style=-route style" \
  "6-paywall=-route paywall" \
  "7-welcome=-onboarding-step welcome"
mkdir -p build/app-store-screenshots/review
sips -z 2796 1290 build/app-store-screenshots/6-paywall.png --out build/app-store-screenshots/review/paywall.png
```

## App Review notes

> Redmic (named Murmur until this version; same bundle ID and subscriptions) is a keyboard extension with a companion app.
>
> HOW DICTATION WORKS
> iOS doesn't let keyboard extensions use the microphone, so the Redmic app records and the keyboard asks it to. The first time you tap the mic (or after Redmic has been off a while), the keyboard opens the Redmic app, which starts listening and takes you back to the app you were typing in. Where it can't (Safari, for example), Home says to swipe right along the bottom edge to go back, and the keyboard is listening when you get there. After that the microphone stays ready in the background (orange dot and a Live Activity) until it times out ("Turn off after" in Settings) or the iPhone has been locked for about a minute, and each tap of the mic dictates without leaving your app.
>
> The keyboard needs Allow Full Access only to exchange the dictation with the Redmic app through their shared App Group container. It doesn't log keystrokes or send what you type anywhere.
>
> TO TRY IT
> 1. Open Redmic, tap Get started and answer the first questions. On "Sign in to start", tap Continue with Apple. Any Apple ID works, so no demo account is needed; sign-in is required because the account holds the plan and the weekly word count.
> 2. Add the keyboard in Settings › General › Keyboard › Keyboards, and turn on Allow Full Access.
> 3. On the microphone page, tap Continue and allow the microphone. The first exercise then shows "Before Redmic listens" (see AI below): tap Allow. After Not now, "Skip the exercises" finishes setup without them.
> 4. Open Notes, switch to the Redmic keyboard with the globe key and tap the mic. Redmic opens, starts listening and brings you back to Notes. Speak, then tap the check mark.
>
> Signed out, the keyboard shows only "You are logged out" and a Log in button; the globe key still switches keyboards.
>
> SUBSCRIPTIONS
> The first account on an iPhone gets a 14-day trial of Pro without payment details. Redmic asks Apple's DeviceCheck, through its server, whether the iPhone has had one; a later account on the same iPhone starts on the free plan (1,000 words a week, shared by the accounts on that iPhone). Either way, "Upgrade to Pro" (menu or Settings) shows Redmic Pro Monthly and Redmic Pro Annual, group "Redmic Pro", with Restore purchase.
>
> AI
> Recordings are transcribed by OpenAI's API, and the transcript is tidied or translated by Anthropic's Claude API, both through Redmic's server. Before anything is recorded, the page "Before Redmic listens" says that the data goes to two third-party AI services and what each receives, links the privacy policy that names them, and offers Allow and Not now (guideline 5.1.2(i)). Without Allow, Redmic doesn't turn the microphone on, so nothing is recorded or sent. The same permission is a switch in Settings › Data and privacy ("Write with AI services"). Neither service trains its models on the data.
>
> ACCOUNT DELETION
> Menu › the account's row at the bottom › Delete account. It deletes the account and its data on the server and revokes Sign in with Apple. For 30 days the server keeps a hashed fingerprint of the sign-in with that week's word count and trial state, so signing up again can't reset the free plan.
>
> TYPE AS I SPEAK (BETA)
> Off by default: Settings › Keyboard › "Type as I speak" (Pro or the trial). After step 4, tap the mic again while the microphone is still ready: the words go into the note as you speak, and the final text replaces them at the check mark.
>
> NEW IN 1.0.5
> - New name and logo (Murmur → Redmic).
> - Four writing modes (Word-to-Word, Rewrite, Email, Funny): menu › Style, or the style button on the keyboard's bar.
> - The keyboard's bar has a Translate button with the language pair; one tap turns translation on or off (needs Full Access).
> - A random identifier kept in the Keychain goes with each dictation so the free plan's words count per iPhone (declared as Device ID under App Privacy; not used for tracking).

**Sign-in information**: leave "Sign-in required" unticked: Sign in with Apple works with any Apple ID (the user decided on 13 Nov 2026 to keep sign-in required, and the notes say so). If Apple asks for a demo account anyway, create one with an email you can read for the 6-digit code.

## App Privacy answers

These match `App/Resources/PrivacyInfo.xcprivacy`. Redmic doesn't track, show ads, or share data with data brokers.

| Data type | Collected | Linked to the user | Used for | Why |
|---|---|---|---|---|
| Contact Info › Name | Yes | Yes | App Functionality | The name Apple or Google passes on at sign-in |
| Contact Info › Email Address | Yes | Yes | App Functionality | Signing in (email, Google, Apple) |
| Identifiers › User ID | Yes | Yes | App Functionality | The account |
| Identifiers › Device ID | Yes | Yes | App Functionality | A random number kept in the iPhone's keychain and sent with each dictation, so the free plan's weekly limit counts per iPhone as well as per account. Not the advertising identifier; not used for tracking |
| Purchases › Purchase History | Yes | Yes | App Functionality | Granting Pro |
| User Content › Audio Data | Yes | No | App Functionality | Transcription by OpenAI; not kept by Redmic's server |
| User Content › Other User Content | Yes | Yes | App Functionality, Analytics | Dictionary, snippets and notes synced to the account; a dictation's text sent to Anthropic to be tidied or translated; feedback text when the user turns on "Improve Redmic for everyone" |
| User Content › Customer Support | Yes | Yes | App Functionality | Support messages from the app |
| Usage Data › Product Interaction | Yes | Yes | App Functionality | The number of words in each dictation, for the free plan's weekly limit; and what each dictation cost to serve (seconds of audio, tokens, which service), never its words |
| Diagnostics › Other Diagnostic Data | Yes | Yes | App Functionality | App version, iOS version, device model and language with a support message |
| Other Data › Other Data Types | Yes | Yes | Analytics | The answers given during setup (what Redmic is for, how the user found it) |

For every type: "No" to tracking. For each "Used for", tick only the purposes listed. Transcripts' history, recordings kept for playback and keystrokes aren't collected: they stay on the device.

Third-party AI (guideline 5.1.2(i)): the app asks for permission before a recording goes to OpenAI and its text to Anthropic ("Before Redmic listens"). The page says "third-party AI services" without the names; the privacy policy, linked on the page, names both.

## Age rating

No objectionable content. The app isn't made for children. "Unrestricted web access": No.

## Before submitting

- [ ] Paid Apps agreement signed by the account holder (Business › Agreements), with banking and tax.
- [ ] Privacy Policy, Terms of Use and support page of 13 Nov 2026 published to GitHub Pages (`scripts/publish_site.sh`); the build settings `MURMUR_PRIVACY_URL`, `MURMUR_TERMS_URL` and `MURMUR_SUPPORT_URL` point there. The live ones are from 9 Nov and name only OpenAI.
- [x] URLs, category and age rating in App Store Connect (`scripts/fill_app_store_listing.mjs`).
- [ ] The listing text, the review notes, the 6.9" screenshots (1320 × 2868), the review build and each subscription's review screenshot, with the same script: `node scripts/fill_app_store_listing.mjs --build <build number>`. Run it with `--dry-run` first to see what changes.
- [ ] App Privacy answers (below), entered in App Store Connect › App Privacy.
- [ ] App Review contact: name, phone and email, in the version's App Review Information.
- [ ] The two subscriptions attached to version 1.0 under "In-App Purchases and Subscriptions", so they're reviewed with the app.

## Risks to know about

- **Returning to the previous app.** After the keyboard opens Redmic, Redmic reads which app the keyboard was in from a private UIKit value, so it can reopen it (`HostReturn.swift`). Review may flag it under guideline 2.5.1. Shipping keyboards rely on the same behavior. If it's rejected, turn off "Return to the app automatically" (Settings › Keyboard) by default; users then swipe back themselves, as a line on Home tells them.
- **Noticing that the keyboard was added.** Onboarding moves on by itself once Redmic's keyboard is in the list of keyboards, which it tells from an undocumented `identifier` of `UITextInputMode` (`SetupStatus.swift`). If review objects, the page can wait for the keyboard's first run instead.
- **Sign-in during onboarding.** Guideline 5.1.1(v) asks that features that don't need an account work without one. Dictation needs the server, which needs an account. Onboarding's sign-in page offers "Continue without an account" only in a build without a server. On 13 Nov 2026 the user decided to keep sign-in required; the review notes tell App Review to sign in with Apple. Since then the sign-in sheet has no guest option either, Redmic records only while someone is signed in, and the keyboard shows "You are logged out" with a Log in button until then (like Wispr Flow's).
- **The keyboard opens the app.** Guideline 4.4.1 says keyboards must not launch other apps. iOS gives a keyboard no microphone, so Redmic's keyboard opens its own app to turn it on; the review notes explain it.
