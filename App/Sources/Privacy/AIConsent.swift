import MurmurCore
import MurmurUI
import Observation
import SwiftUI
import UIKit

/// The user's OK to send recordings and their text to the AI services that write them (App Review
/// guideline 5.1.2(i)). Without it no session starts, so nothing is recorded for upload:
/// `SessionController.start` asks first, on whichever path the microphone is turned on.
@MainActor
@Observable
final class AIConsent {
    /// Bump when the services, or what they receive, change: everyone is asked again.
    static let currentVersion = 1

    private(set) var isGranted: Bool
    @ObservationIgnored private let settings: SharedSettings?
    @ObservationIgnored private let ask: @MainActor () async -> Bool
    /// The question while it's on screen, shared by everything that asks meanwhile.
    @ObservationIgnored private var asking: Task<Bool, Never>?

    /// `settings`: where the answer is kept; nil keeps it for this launch only. `ask`: puts the
    /// question on screen and returns the answer.
    init(settings: SharedSettings? = .shared, ask: @escaping @MainActor () async -> Bool = AIConsentPrompt.ask) {
        self.settings = settings
        self.ask = ask
        isGranted = (settings?.aiConsentVersion ?? 0) >= Self.currentVersion
    }

    /// Screenshot runs and UI tests on fake services: allowed without asking, and nothing saved.
    static func allowedForFixtures() -> AIConsent {
        let consent = AIConsent(settings: nil, ask: { true })
        consent.isGranted = true
        return consent
    }

    /// True once the user has allowed it, asking them first if they haven't.
    func ensure() async -> Bool {
        if isGranted { return true }
        if let asking { return await asking.value }
        let question = Task { await ask() }
        asking = question
        let allowed = await question.value
        asking = nil
        if allowed { grant() }
        return allowed
    }

    func grant() {
        isGranted = true
        settings?.aiConsentVersion = Self.currentVersion
    }

    /// Settings' switch turned off, a sign-out, a deleted account. The next start asks again.
    func withdraw() {
        isGranted = false
        settings?.aiConsentVersion = 0
    }
}

/// The question's words. They are the consent's wording: a change in what they say needs a new
/// `AIConsent.currentVersion`.
enum AIConsentCopy {
    struct Point: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let title = "Before Murmur listens"
    static let line = "Murmur writes what you say with two AI services. Here’s what each one gets."
    static let points = [
        Point(symbol: "waveform", title: "OpenAI gets your recording",
              detail: "It turns what you said into text."),
        Point(symbol: "text.alignleft", title: "Anthropic gets the text",
              detail: "When it needs tidying or translating, Claude rewrites it."),
        Point(symbol: "hand.raised", title: "Only to write your text",
              detail: "Neither service trains its models on your recordings or text, and Murmur’s servers don’t keep them."),
    ]
    static let allow = "Allow"
    static let notNow = "Not now"
    static let footnote = "You can change this in Settings › Data and privacy."
    static let privacy = "Privacy Policy"

    /// Settings' switch for the same permission.
    static let settingTitle = "Write with AI services"
    static let settingDetail = "Send your recordings to OpenAI and their text to Anthropic, which write what you say. Murmur can’t dictate without them."
}

/// The question, in a window of its own above whatever is on screen: a sheet, the swipe-back
/// screen, onboarding. UIKit presents one thing at a time, and a session that is starting can't
/// wait for the others to close.
@MainActor
enum AIConsentPrompt {
    private static var window: UIWindow?

    /// Shows the question and returns the answer; false when it can't be shown (it's already up,
    /// or Murmur isn't on screen).
    static func ask() async -> Bool {
        guard window == nil, let scene = frontScene() else { return false }
        // A keyboard left up in the app would cover the buttons.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let underneath = scene.keyWindow
        return await withCheckedContinuation { continuation in
            let shown = UIWindow(windowScene: scene)
            let page = AIConsentView { allowed in
                // Once: the page takes no second answer, and the window is gone after the first.
                guard window === shown else { return }
                window = nil
                UIView.animate(withDuration: 0.2) {
                    shown.alpha = 0
                } completion: { _ in
                    shown.isHidden = true
                    underneath?.makeKey()
                }
                continuation.resume(returning: allowed)
            }
            shown.rootViewController = UIHostingController(rootView: page)
            shown.windowLevel = .alert
            shown.accessibilityViewIsModal = true
            shown.alpha = 0
            window = shown
            shown.makeKeyAndVisible()
            UIView.animate(withDuration: 0.2) { shown.alpha = 1 }
        }
    }

    private static func frontScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
    }
}

/// "Before Murmur listens": who gets a recording and its text, and the two answers.
struct AIConsentView: View {
    let answer: (Bool) -> Void
    @State private var answered = false

    var body: some View {
        OnboardingPage(top: .wordmark) {
            OnboardingTitle(AIConsentCopy.title, line: AIConsentCopy.line)
                .accessibilityIdentifier(AccessibilityID.screen("aiConsent"))
                .padding(.top, 24)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(AIConsentCopy.points) { point in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Image(systemName: point.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 26)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: point.title)
                                .font(.murmur(.headline))
                                .foregroundStyle(Theme.ink)
                            Text(verbatim: point.detail)
                                .font(.murmur(.subhead))
                                .lineSpacing(2)
                                .foregroundStyle(Theme.second)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 32)
            Spacer(minLength: 24)
            Text(verbatim: AIConsentCopy.footnote)
                .font(.murmur(.footnote))
                .foregroundStyle(Theme.third)
                .fixedSize(horizontal: false, vertical: true)
            if let privacy = AccountView.privacyURL {
                Link(AIConsentCopy.privacy, destination: privacy)
                    .font(.murmur(.footnote))
                    .underline()
                    .tint(Theme.ink)
                    .padding(.top, 6)
            }
        } actions: {
            Button(AIConsentCopy.allow) { decide(true) }
                .buttonStyle(.murmur(.primary))
                .accessibilityIdentifier(AccessibilityID.aiConsentAllow)
            Button(AIConsentCopy.notNow) { decide(false) }
                .buttonStyle(.textOnly)
                .accessibilityIdentifier(AccessibilityID.aiConsentNotNow)
                .padding(.top, 4)
        }
        .disabled(answered)
    }

    private func decide(_ allowed: Bool) {
        guard !answered else { return }
        answered = true
        answer(allowed)
    }
}
