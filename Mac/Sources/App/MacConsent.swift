import AppKit
import MurmurCore

/// The question the iPhone asks before a recording goes to the AI services (`AIConsent` and
/// `AIConsentCopy` in App/Sources/Privacy, which are UIKit-bound), asked on the Mac with the same
/// words and kept in the same setting and version.
///
/// TODO: move `AIConsent` and `AIConsentCopy` out of the UIKit file so both apps share one copy.
@MainActor
enum MacConsent {
    /// `AIConsent.currentVersion`.
    static let currentVersion = 1

    static var isGranted: Bool { SharedSettings.shared.aiConsentVersion >= currentVersion }

    /// True once allowed, asking first if it hasn't been.
    static func ensure() async -> Bool {
        if isGranted { return true }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Before Redmic listens"
        alert.informativeText = """
            Redmic writes what you say with two third-party AI services. Here’s what each one gets.

            An AI service gets your recording. It turns what you said into text.

            A second AI service gets the text. When it needs tidying or translating, it rewrites it.

            Only to write your text. Neither service trains its models on your recordings or text, and Redmic’s servers don’t keep them.

            You can change this in Settings › Data and privacy. The Privacy Policy names both services.
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Not now")
        let allowed = alert.runModal() == .alertFirstButtonReturn
        if allowed { SharedSettings.shared.aiConsentVersion = currentVersion }
        return allowed
    }

    static func withdraw() {
        SharedSettings.shared.aiConsentVersion = 0
    }
}
