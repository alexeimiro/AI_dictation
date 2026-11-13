import Foundation

/// Every line onboarding shows. It has no dependencies, because the UI tests compile this file
/// too: the words and the tests that look for them change together.
enum OnboardingCopy {
    static let next = "Next"
    static let `continue` = "Continue"
    static let back = "Back"
    static let skip = "Skip"
    static let openSettings = "Open Settings"

    /// "Step 2 of 4": the bar at the top of a page, and the pages that open a part.
    static func step(_ part: Int, of parts: Int) -> String {
        "Step \(part) of \(parts)"
    }

    enum Welcome {
        static let talk = "Talk instead of typing."
        static let languages = "Speak your language."
        static let dictionary = "It learns your words."
        static let line = "Murmur is a keyboard that writes what you say."
        static let button = "Get started"

        /// What the picture's talk button has just heard, page by page.
        static let talkSample = "Running ten minutes late, start without me"
        static let languagesSample = "Опаздываю на десять минут, начинайте без меня"
        static let languagesCaption = "Dictated in Russian"
        static let dictionarySample = "Ask Priya about the Lindqvist contract"
        /// The words in `dictionarySample` that came from the dictionary.
        static let dictionaryWords = ["Priya", "Lindqvist"]
        static let dictionaryCaption = "Names from your dictionary"
        static let picture = "The talk button while Murmur listens"
    }

    enum Survey {
        static let title = "What do you want help with?"
        static let line = "Pick any that fit."
        static let messages = "Replying to messages"
        static let emails = "Writing emails"
        static let chatWithAI = "Talking to AI assistants"
        static let captureIdeas = "Catching ideas before they go"
        static let onTheGo = "Working on the move"
        static let typeFaster = "Typing faster on my phone"
        static let typingIsHard = "Typing is hard for me"
    }

    enum Explainer {
        static func title(benefit: String) -> String {
            "Murmur helps you \(benefit), \(ending)."
        }

        static let ending = "wherever you write"
        static let messages = "answer messages faster"
        static let emails = "write emails faster"
        static let chatWithAI = "chat with AI faster"
        static let captureIdeas = "capture ideas faster"
        static let onTheGo = "write on the go"
        static let typeFaster = "type faster"
        static let typingIsHard = "write without typing"

        /// The picture's text box: where the words go, and what was said.
        static let message = "Message"
        static let email = "Email"
        static let assistant = "Assistant"
        static let note = "Note"
        static let messageSample = "Running ten minutes late, start without me"
        static let emailSample = "Hi Tim, are you free on Friday at 4?"
        static let assistantSample = "Summarize this article in three points"
        static let ideaSample = "Idea: a walking tour that ends at the bakery"
        static let onTheGoSample = "On my way, there in five"
        static let noteSample = "Call the bank, then buy milk"
    }

    enum SignIn {
        static let title = "Sign in to start"
        static let line = "Your dictionary, snippets and plan stay with your account."
        static let google = "Continue with Google"
        static let apple = "Continue with Apple"
        static let email = "Continue with Email"
        static let more = "More options"
        static let withoutAccount = "Continue without an account"
        static let legalStart = "By continuing, you acknowledge that you have read and agreed to our "
        static let terms = "Terms of Service"
        static let legalJoin = " and "
        static let privacy = "Privacy Policy"
    }

    enum Email {
        static let title = "Continue with your email"
        static let sentTitle = "Check your email"
        /// How `sentLine(to:)` starts.
        static let sentLineStart = "Enter the 6-digit code"

        static func sentLine(to address: String) -> String {
            "\(sentLineStart) we sent to \(address), or open the link in that email on this iPhone."
        }

        static let addressPrompt = "Email address"
        static let codePrompt = "123456"
        static let resend = "Send a new code"
    }

    enum SetupIntro {
        static let title = "Add the keyboard."
        static let line = "Two switches in Settings. It takes a minute."
        static let button = "Set up"
    }

    enum Keyboard {
        static let title = "Turn on Murmur in Settings"
        static let line = "In Settings, tap Keyboards and turn on Murmur and Allow Full Access."
        static let keyboards = "Keyboards"
        static let murmur = "Murmur"
        static let fullAccess = "Allow Full Access"
        static let picture = "In Settings, open Keyboards, then turn on Murmur and Allow Full Access"
        static let added = "Keyboard added"
        static let done = "Done"
        static let notDone = "Not done"
        static let note = "Full Access lets the keyboard talk to the Murmur app. Murmur never sells what you say."
        static let button = "Go to Settings"
    }

    enum PracticeIntro {
        static let title = "Now try it."
        static let line = "One short dictation, so you know how it feels."
        static let button = "Try Murmur"
    }

    enum Microphone {
        static let title = "Murmur needs the microphone"
        static let line = "It listens only while Murmur is on. Whenever the mic is open, you’ll see the red dot."
        static let caption = "Red means the microphone is open"
        static let offTitle = "Turn on the microphone for Murmur"
        static let deniedLine = "Microphone access is off. Turn it on in Settings › Murmur to dictate."
        static let restrictedLine = "Microphone access is restricted on this iPhone, so dictation can’t start."
        static let skip = "Skip the exercises"
    }

    enum Practice {
        static let guideTitle = "Hold the globe key, then pick Murmur"
        static let guidePicture = "The list of keyboards the globe key opens, with Murmur picked"
        static let otherKeyboards = ["English", "Emoji"]
        static let murmurKeyboard = "Murmur"

        /// The check mark the keyboard's talk button shows follows these words.
        static let basicTitle = "Say anything, then tap"
        static let basicTitleSpoken = "Say anything, then tap the check mark"
        static let basicLine = "Your words appear in the box."
        static let basicPrompt = "Your words appear here"

        static let emailTitle = "Dictate an email"
        static let emailLine = "Change your mind halfway. Murmur keeps the last version."
        static let emailLabel = "Email"
        static let emailPrompt = "Hey Tim, are you available on Friday at 3pm… actually 4pm?"

        static let whisperTitle = "Whisper a note"
        static let whisperLine = "Hold the phone close."
        static let noteLabel = "Note"
        static let notePrompt = "Things to do today:\n1. Run the laundry\n2. Buy groceries"

        /// After "Not now" to "Before Murmur listens" (`AIConsentCopy`).
        static let notAllowed = "Murmur writes what you say with its AI services, so the exercises need your OK. You can skip them and try Murmur later."
        static let askAgain = "Try again"
        static let skipExercises = "Skip the exercises"

        static let listening = "Listening. Go ahead."
        static let writing = "Writing…"
        static let fullAccess = "Turn on Allow Full Access so the keyboard can dictate."
        static let box = "Practice text"
        /// Only with `-onboarding-fixtures`: the UI tests' stand-in for a dictation.
        static let simulate = "Simulate dictation"
    }

    enum WhisperIntro {
        static let title = "You can whisper, too."
        static let line = "Handy in a meeting, on a train or late at night."
        static let caption = "A quiet voice is enough"
    }

    enum PracticeDone {
        static let title = "That’s it. You’re dictating."
        static let skippedTitle = "Skipped for now."
        static let skippedLine = "Open any text field and switch to Murmur when you want to try it."
        static let spoke = "Spoke"
        static let email = "Dictated an email"
        static let whispered = "Whispered"
        static let done = "Done"
        static let skipped = "Skipped"
    }

    enum WrapUpIntro {
        static let title = "A few choices left."
        static let line = "Then you’re done."
    }

    enum DataChoice {
        static let title = "Your words, your call."
        static let line = "Choose what Murmur may do with your voice and text."
        // The two options are the consent's wording (`DataChoiceDecision.currentPolicyVersion`).
        static let improveTitle = "Improve Murmur for everyone"
        static let improveDetail = "To make Murmur better, this option lets us review your transcripts and edits to improve transcription and cleanup."
        // Not "Don't share data": a dictation still goes to the AI services that write it, which
        // "Before Murmur listens" (`AIConsentCopy`) asks about. This choice is about Murmur's team.
        static let privateTitle = "Don’t review my dictations"
        static let privateDetail = "Nobody at Murmur reads your transcripts. They go only to the AI services that write your text, which don’t train on them."
    }

    enum Languages {
        static let title = "Confirm your language"
        static let line = "We picked this from your iPhone’s languages. Add or remove languages if needed."
        static let edit = "Edit"
        static let pickerTitle = "Languages"
        static let pickerLine = "Murmur dictates in up to two languages and switches between them from the keyboard."
        static let primary = "Primary"
        static let second = "Second"
        static let done = "Done"
    }

    enum Style {
        static let title = "Pick how Murmur writes"
        static let line = "You can change it any time from the keyboard."
        static let youSay = "You say"
    }

    enum Notifications {
        static let title = "Notifications"
        static let line = "A tip now and then, and news when something changes. Turn them off any time."
        static let benefits = [
            "Tips for faster dictation",
            "News about new features",
            "A nudge if you forget Murmur is there",
        ]
        static let allow = "Allow notifications"
        static let later = "Not now"
        static let sampleSender = "Murmur"
        static let sampleTime = "now"
        static let sampleText = "Tip: say “new paragraph” and Murmur starts one."
        static let picture = "An example notification from Murmur"
    }

    enum Desktop {
        static let title = "Murmur for Mac and PC is on the way."
        static let line = "Want the link when it’s ready? We’ll email it once."
        static let accept = "Email me the link"
        static let decline = "No thanks"
        static let alertTitle = "Email a link?"
        static let alertMessage = "We’ll send it when Murmur for desktop is available."
        static let alertField = "Email address"
        static let send = "Send"
        static let cancel = "Cancel"
        static let failed = "Couldn’t save that. Try again, or choose No thanks."
        static let sample = "Running ten minutes late, start without me"
        static let listening = "Listening"
        static let picture = "Murmur writing what you say on a computer"
    }

    enum Referral {
        static let title = "How did you find Murmur?"
        static let detailTitle = "Which search engine?"
        static let xTwitter = "X / Twitter"
        static let searchEngine = "Search engine"
        static let tikTok = "TikTok"
        static let articleNews = "Article / News"
        static let newsletter = "Newsletter"
        static let linkedIn = "LinkedIn"
        static let friendColleague = "Friend / Colleague"
        static let youTube = "YouTube"
        static let reddit = "Reddit"
        static let other = "Other"
    }

    enum Ready {
        static let title = "You’re set."
        static let line = "Open any text field, switch to Murmur and talk."
        static let button = "Start dictating"
        static let caption = "Tap to speak"
        static let picture = "The talk button on the Murmur keyboard"
    }

    enum Offer {
        static let button = "Get started"

        static let trialBadge = "Pro trial"
        static let trialFootnote = "After the trial you’re on Basic: 1,000 words a week, free."

        /// "Two weeks of Pro, on us".
        static func trialTitle(days: Int) -> String {
            "\(spelledAtStart(duration(days))) of Pro, on us"
        }

        static func trialLine(days: Int) -> String {
            "Unlimited words for \(duration(days)). No card needed."
        }

        /// Under the big number of days.
        static func trialCaption(days: Int) -> String {
            days == 1 ? "day of unlimited words" : "days of unlimited words"
        }

        static let subscriberBadge = "Pro"
        static let subscriberTitle = "You have Pro. Unlimited words."
        static let subscriberLine = "Your Murmur Pro subscription is active on this account."
        static let subscriberCaption = "unlimited words"

        static let freeBadge = "Basic"
        static let freeTitle = "You’re on Basic. Start dictating."
        static let freeLine = "Basic includes 1,000 words of dictation every week."
        static let freeFootnote = "Your words reset every Sunday."
        /// Basic because the free trial is one per iPhone.
        static let trialUsedLine = "This iPhone has already had its free trial. Basic includes 1,000 words of dictation every week."
        static let freeNumber = "1,000"
        static let freeCaption = "words a week, free"

        static let failedTitle = "Couldn’t load your plan"
        static let failedLine = "Check your connection and try again."
        static let retry = "Try again"
        static let signedOutTitle = "You’re signed out"
        static let signInAgain = "Sign in again"

        /// `phrase`: how the copy names the remembered account ("with Apple", "as olga@example.com").
        static func signedOutLine(_ phrase: String?) -> String {
            guard let phrase else { return "Sign in again to load your plan." }
            return "Sign in again \(phrase) to load your plan."
        }

        /// 14 → "2 weeks", 7 → "1 week", 10 → "10 days".
        static func duration(_ days: Int) -> String {
            if days % 7 == 0 {
                let weeks = days / 7
                return weeks == 1 ? "1 week" : "\(weeks) weeks"
            }
            return days == 1 ? "1 day" : "\(days) days"
        }

        /// "2 weeks" → "Two weeks": a number that opens a sentence is spelled out, up to ten.
        static func spelledAtStart(_ duration: String) -> String {
            let words = ["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
            let parts = duration.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let number = Int(parts[0]), words.indices.contains(number - 1) else {
                return duration
            }
            return "\(words[number - 1]) \(parts[1])"
        }
    }
}
