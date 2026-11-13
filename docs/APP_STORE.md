# Murmur on the App Store: listing, review notes, privacy answers

Drafts for App Store Connect, app "Murmur: Voice Keyboard" (Apple ID 6829429992), version 1.0.
`node scripts/fill_app_store_listing.mjs` puts them there (all but the App Privacy answers, which
App Store Connect only takes in its web page). Character limits are App Store Connect's.

## Listing

**Subtitle** (30): `Talk instead of typing`

**Promotional text** (170):
> Switch to Murmur in any text field and talk. It writes what you say, spelled your way. Translate as you speak, teach it your names, and dictate from the Action Button.

**Keywords** (100):
`dictation,voice typing,speech to text,keyboard,transcribe,translate,voice notes,talk to text,dictate`

**Description** (4,000):
> Murmur is a keyboard that writes what you say. Switch to it in any text field, tap the mic and talk. Your words arrive in seconds: punctuated, with "um" and "uh" gone, and with names spelled the way you spell them.
>
> WRITE WHEREVER YOU WRITE
> Messages, email, notes, documents, chats with AI. Switch to the Murmur keyboard, tap the mic, talk, and tap the check mark.
>
> YOUR WORDS, OR YOUR WORDS TIDIED
> Word for word keeps exactly what you said. Improve my grammar fixes mistakes and drops false starts without changing your tone. Professional makes it clear and polite for work, Casual writes it the way you text, and Concise says it in fewer words.
>
> TRANSLATE AS YOU SPEAK
> Speak one language and type in another, in more than 50 languages. Murmur detects the language you speak.
>
> IT LEARNS YOUR WORDS
> Add names, brands and jargon, or fix a word Murmur keeps mishearing. Add a word straight from the keyboard.
>
> SNIPPETS
> Say "my calendar link" and Murmur types the link. Save anything you type often.
>
> NOTES
> A place to say a thought and keep it, on all your devices.
>
> ACTION BUTTON AND CONTROL CENTER
> Start and stop a dictation without touching the keyboard.
>
> YOU ALWAYS KNOW WHEN IT LISTENS
> Red means the microphone is open, and nothing else in Murmur is red. Murmur asks before your first recording leaves your iPhone: OpenAI turns it into text, and Anthropic tidies or translates the text. Neither trains AI models on it. Your history of transcripts and recordings stays on your iPhone.
>
> MURMUR PRO
> Murmur is free with 1,000 words a week, after a 14-day trial of Pro, one per iPhone. Murmur Pro has no weekly limit: $9.99 a month or $79.99 a year. Payment is charged to your Apple Account, and the subscription renews automatically unless cancelled at least 24 hours before the end of the period. Manage or cancel it in Settings › Apple Account › Subscriptions.
>
> Terms of Use: https://simplymurmur.com/terms/
> Privacy Policy: https://simplymurmur.com/privacy/

**Category**: Productivity (secondary: Utilities)

**Support URL**: `https://simplymurmur.com/support/`

**Marketing URL**: `https://simplymurmur.com/`

**Privacy Policy URL**: `https://simplymurmur.com/privacy/`, from `docs/legal/privacy-policy.md`.

**Copyright**: `2026 OKNENOR L.L.C-FZ`

## Screenshots

The 6.9" set (1320 × 2868) is taken on an iPhone 17 Pro Max simulator from a Debug build with sample
data, into `build/app-store-screenshots`, which `scripts/fill_app_store_listing.mjs` uploads in
file name order:

```sh
SIM="iPhone 17 Pro Max" DD=build/DerivedData OUT=build/app-store-screenshots scripts/screenshots.sh \
  "1-home=-route home -session-fixture on" \
  "2-note=-route note -session-fixture listening" \
  "3-dictionary=-route dictionary" \
  "4-snippets=-route snippets" \
  "5-style=-route style" \
  "6-paywall=-route paywall" \
  "7-welcome=-onboarding-step welcome"
```

## App Review notes

> Murmur is a keyboard extension with a companion app.
>
> HOW DICTATION WORKS
> iOS doesn't let keyboard extensions use the microphone. So the Murmur app records, and the keyboard asks it to. The first time you tap the mic in the keyboard (or when Murmur has been off a while), the keyboard opens the Murmur app, which starts listening and takes you back to the app you were typing in. After that, the microphone stays ready in the background (shown by the orange dot and a Live Activity) until it times out ("Turn off after" in Settings), and each tap of the mic dictates without leaving your app.
>
> The keyboard needs Allow Full Access, only to exchange the dictation with the Murmur app through their shared App Group container. It doesn't log keystrokes or send what you type anywhere.
>
> TO TRY IT
> 1. Open Murmur and sign in with Apple. Any Apple ID works, so no demo account is needed. Sign-in is required, because the account holds the plan and the weekly word count.
> 2. Follow the setup: add the keyboard in Settings › General › Keyboard › Keyboards, and turn on Allow Full Access.
> 3. On the microphone page, tap Continue. "Before Murmur listens" asks for permission to send recordings to the AI services (see AI below): tap Allow, then allow the microphone.
> 4. Open Notes, switch to the Murmur keyboard with the globe key, tap the mic and speak.
>
> SUBSCRIPTIONS
> The first account on an iPhone gets a 14-day trial of Pro without payment details. Murmur asks Apple's DeviceCheck, through its server, whether the iPhone has had one, so a later account on the same iPhone starts on the free plan (1,000 words a week); if this device already had a Murmur trial, that is why. Either way the subscriptions can be bought. "Upgrade to Pro" in the menu or Settings shows the two auto-renewing subscriptions, Murmur Pro Monthly and Murmur Pro Annual, in the group "Murmur Pro". Restore purchase is on the same screen.
>
> AI
> Recordings are transcribed by OpenAI's API, and the transcript is tidied or translated by Anthropic's Claude API, both through Murmur's server. Before the microphone is first turned on, the page "Before Murmur listens" names both services, says what each receives, and offers Allow and Not now (guideline 5.1.2(i)). Without Allow, Murmur doesn't turn the microphone on, so nothing is recorded or sent. The same permission is a switch in Settings › Data and privacy ("Write with AI services"). Neither service trains its models on the data. The user's words are typed into their own text field and aren't shared with other users.
>
> ACCOUNT DELETION
> Open the menu, tap the account's row at the bottom, then Delete account. It deletes the account and its data on the server and revokes Sign in with Apple.

**Sign-in information**: leave "Sign-in required" unticked: Sign in with Apple works with any Apple ID (the user decided on 13 Nov 2026 to keep sign-in required, and the notes say so). If Apple asks for a demo account anyway, create one with an email you can read for the 6-digit code.

## App Privacy answers

These match `App/Resources/PrivacyInfo.xcprivacy`. Murmur doesn't track, show ads, or share data with data brokers.

| Data type | Collected | Linked to the user | Used for | Why |
|---|---|---|---|---|
| Contact Info › Name | Yes | Yes | App Functionality | The name Apple or Google passes on at sign-in |
| Contact Info › Email Address | Yes | Yes | App Functionality | Signing in (email, Google, Apple) |
| Identifiers › User ID | Yes | Yes | App Functionality | The account |
| Purchases › Purchase History | Yes | Yes | App Functionality | Granting Pro |
| User Content › Audio Data | Yes | No | App Functionality | Transcription by OpenAI; not kept by Murmur's server |
| User Content › Other User Content | Yes | Yes | App Functionality, Analytics | Dictionary, snippets and notes synced to the account; a dictation's text sent to Anthropic to be tidied or translated; feedback text when the user turns on "Improve Murmur for everyone" |
| User Content › Customer Support | Yes | Yes | App Functionality | Support messages from the app |
| Usage Data › Product Interaction | Yes | Yes | App Functionality | The number of words in each dictation, for the free plan's weekly limit |
| Diagnostics › Other Diagnostic Data | Yes | Yes | App Functionality | App version, iOS version, device model and language with a support message |
| Other Data › Other Data Types | Yes | Yes | Analytics | The answers given during setup (what Murmur is for, how the user found it) |

For every type: "No" to tracking. For each "Used for", tick only the purposes listed. Transcripts' history, recordings kept for playback and keystrokes aren't collected: they stay on the device.

Third-party AI (guideline 5.1.2(i)): the app asks for permission before a recording goes to OpenAI and its text to Anthropic ("Before Murmur listens"), and the privacy policy names both.

## Age rating

No objectionable content. The app isn't made for children. "Unrestricted web access": No.

## Before submitting

- [ ] Paid Apps agreement signed by the account holder (Business › Agreements), with banking and tax.
- [x] Privacy Policy, Terms of Use and support page hosted on GitHub Pages (`scripts/publish_site.sh`), and in the build settings `MURMUR_PRIVACY_URL`, `MURMUR_TERMS_URL` and `MURMUR_SUPPORT_URL`.
- [x] URLs, category and age rating in App Store Connect (`scripts/fill_app_store_listing.mjs`).
- [ ] The listing text, the review notes and the 6.9" screenshots (1320 × 2868) of the November 2026 redesign uploaded with the same script. What is in App Store Connect now shows the earlier design.
- [ ] App Privacy answers (below), entered in App Store Connect › App Privacy.
- [ ] App Review contact: name, phone and email, in the version's App Review Information.
- [ ] The two subscriptions attached to version 1.0 under "In-App Purchases and Subscriptions", so they're reviewed with the app.

## Risks to know about

- **Returning to the previous app.** After the keyboard opens Murmur, Murmur reads which app the keyboard was in from a private UIKit value, so it can reopen it (`HostReturn.swift`). Review may flag it under guideline 2.5.1. Shipping keyboards rely on the same behavior. If it's rejected, turn off "Return to the app automatically" (Settings › Keyboard) by default; users then swipe back themselves, as a line on Home tells them.
- **Noticing that the keyboard was added.** Onboarding moves on by itself once Murmur's keyboard is in the list of keyboards, which it tells from an undocumented `identifier` of `UITextInputMode` (`SetupStatus.swift`). If review objects, the page can wait for the keyboard's first run instead.
- **Sign-in during onboarding.** Guideline 5.1.1(v) asks that features that don't need an account work without one. Dictation needs the server, which needs an account. Onboarding's sign-in page offers "Continue without an account" only in a build without a server; someone who has signed out can go on as a guest from the sign-in sheet. On 13 Nov 2026 the user decided to keep sign-in required; the review notes tell App Review to sign in with Apple.
- **The keyboard opens the app.** Guideline 4.4.1 says keyboards must not launch other apps. iOS gives a keyboard no microphone, so Murmur's keyboard opens its own app to turn it on; the review notes explain it.
