import MurmurCore
import MurmurUI
import SwiftUI
import UIKit

/// The three exercises. The text box is a real text view, so the dictation runs through the real
/// Murmur keyboard and session; the page only watches the result.
struct PracticeView: View {
    let exercise: PracticeExercise
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var murmurKeyboardActive = false
    @State private var fullAccessHint = false

    var body: some View {
        let store = model.onboarding
        let done = store.record.isDone(exercise)
        // Next is held above the keyboard; what is over it scrolls when it doesn't fit.
        OnboardingPage {
            title
                .padding(.top, 8)
            if let line {
                Text(verbatim: line)
                    .font(.murmur(.callout))
                    .foregroundStyle(Theme.second)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            if showsKeyboardGuide {
                KeyboardPickerPicture()
                    .padding(.top, 22)
            }
            // Under the guide the box stays focused but hidden, so the real keyboard is up to
            // switch from; picking Murmur's reveals the same box, keyboard still up.
            editor
                .padding(.top, 12)
                .frame(height: showsKeyboardGuide ? 0 : nil, alignment: .top)
                .opacity(showsKeyboardGuide ? 0 : 1)
                .allowsHitTesting(!showsKeyboardGuide)
                .accessibilityHidden(showsKeyboardGuide)
            feedback
        } actions: {
            if done {
                Button(OnboardingCopy.next) { store.send(.next) }
                    .buttonStyle(.murmur(.primary))
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: done)
        .overlay(alignment: .bottomTrailing) {
            // UI tests drive the scripted dictation from here; never shown otherwise.
            if model.launchOptions.onboardingFixtures {
                Button(OnboardingCopy.Practice.simulate) { model.practice.simulateDictation() }
                    .font(.murmur(.footnote))
                    .padding(12)
                    // Clear of Next.
                    .padding(.bottom, 84)
            }
        }
        .task {
            await model.practice.begin(exercise)
            if model.launchOptions.usesOnboardingFixtures {
                murmurKeyboardActive = OnboardingFixtures.murmurKeyboardActive(variant: model.launchOptions.onboardingVariant)
                if case .completed(let result) = model.practice.state { apply(result) }
            }
        }
        .onDisappear { model.practice.end() }
        .onChange(of: model.practice.state) { _, state in
            if case .completed(let result) = state { apply(result) }
        }
        .onChange(of: text) { _, newValue in
            // Typed text counts for the first exercise; the others need a dictation.
            if exercise == .basic, !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.send(.practiceCompleted(.basic))
            }
        }
        .task(id: murmurKeyboardActive) { await watchFullAccess() }
    }

    // MARK: Pieces

    /// Until the Murmur keyboard is up, the first exercise shows how to switch to it.
    private var showsKeyboardGuide: Bool {
        exercise == .basic && !murmurKeyboardActive && text.isEmpty
    }

    @ViewBuilder
    private var title: some View {
        Group {
            switch exercise {
            case .basic where showsKeyboardGuide:
                Text(verbatim: OnboardingCopy.Practice.guideTitle)
            case .basic:
                // The red ✓ the talk button shows while it listens.
                let check = Text(Image(systemName: "checkmark.circle.fill")).foregroundStyle(Theme.live)
                Text("\(OnboardingCopy.Practice.basicTitle) \(check)")
                    .accessibilityLabel(OnboardingCopy.Practice.basicTitleSpoken)
            case .formatting:
                Text(verbatim: OnboardingCopy.Practice.emailTitle)
            case .whisper:
                Text(verbatim: OnboardingCopy.Practice.whisperTitle)
            }
        }
        .font(.murmur(.title2))
        .tracking(-0.4)
        .foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }

    private var line: String? {
        switch exercise {
        case .basic: showsKeyboardGuide ? nil : OnboardingCopy.Practice.basicLine
        case .formatting: OnboardingCopy.Practice.emailLine
        case .whisper: OnboardingCopy.Practice.whisperLine
        }
    }

    /// The box: a soft card with the text view in it, and for the email and the note a small
    /// label saying what it stands for.
    private var editor: some View {
        // Fixture runs keep the keyboard down: they dictate through the scripted client.
        let field = PracticeTextView(text: $text, focusOnAppear: !model.launchOptions.usesOnboardingFixtures) { active in
            if !model.launchOptions.usesOnboardingFixtures { murmurKeyboardActive = active }
        }
        return VStack(alignment: .leading, spacing: 0) {
            if let label = boxLabel {
                Text(verbatim: label)
                    .font(.murmur(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.third)
                    .padding(.leading, 5)
                    .padding(.top, 6)
            }
            field
                .overlay(alignment: .topLeading) { placeholder }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        // As tall as three lines need, and no taller: on the smallest iPhone the page then fits
        // over the keyboard.
        .frame(height: exercise == .basic ? 112 : 124)
        .background(Theme.fill, in: .rect(cornerRadius: 20))
    }

    private var boxLabel: String? {
        switch exercise {
        case .basic: nil
        case .formatting: OnboardingCopy.Practice.emailLabel
        case .whisper: OnboardingCopy.Practice.noteLabel
        }
    }

    /// What to say, in the empty box. It sits where the text view's first line does.
    @ViewBuilder
    private var placeholder: some View {
        if text.isEmpty {
            Text(verbatim: prompt)
                .font(.transcript(.body))
                .foregroundStyle(Theme.third)
                .lineSpacing(PracticeTextView.lineSpacing)
                .padding(.top, 8)
                .padding(.leading, 5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var prompt: String {
        switch exercise {
        case .basic: OnboardingCopy.Practice.basicPrompt
        case .formatting: OnboardingCopy.Practice.emailPrompt
        case .whisper: OnboardingCopy.Practice.notePrompt
        }
    }

    /// Under the box: what the dictation is doing, since the keyboard's own talk button is easy
    /// to miss while watching the box for the result.
    @ViewBuilder
    private var feedback: some View {
        Group {
            switch model.practice.state {
            case .listening:
                status(OnboardingCopy.Practice.listening) {
                    Circle()
                        .fill(Theme.live)
                        .frame(width: 10, height: 10)
                }
            case .processing:
                status(OnboardingCopy.Practice.writing) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.ink)
                }
            default:
                fallbackFeedback
            }
        }
        .padding(.top, 12)
    }

    private func status(_ words: String, @ViewBuilder marker: () -> some View) -> some View {
        HStack(spacing: 10) {
            marker()
            Text(verbatim: words)
                .font(.murmur(.subhead, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    @ViewBuilder
    private var fallbackFeedback: some View {
        if fullAccessHint {
            ActionRow {
                Text(verbatim: OnboardingCopy.Practice.fullAccess)
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button(OnboardingCopy.openSettings) { model.setup.openSettings() }
                    .buttonStyle(.murmur(.secondary, size: .compact))
            }
        } else if case .failed(let message) = model.practice.state {
            FieldError(message: message)
        }
    }

    // MARK: Behavior

    private func apply(_ result: String) {
        if !model.practice.insertsText { text = result }
        model.onboarding.send(.practiceCompleted(exercise))
    }

    /// The keyboard can only reach the app with Full Access, and only says so once it runs: if it
    /// is on screen and hasn't reported in, point to Settings.
    private func watchFullAccess() async {
        fullAccessHint = false
        guard murmurKeyboardActive, !model.launchOptions.usesOnboardingFixtures else { return }
        for _ in 0..<4 {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            model.setup.refresh()
            if model.setup.fullAccessConfirmed { return }
        }
        fullAccessHint = true
    }
}

/// A UITextView so the Murmur keyboard can type into it, and so the page can tell which keyboard
/// is up (switching to Murmur's changes the title). Its text is the system font at the body size.
struct PracticeTextView: UIViewRepresentable {
    static let lineSpacing: CGFloat = 1.2

    @Binding var text: String
    var focusOnAppear = true
    let onKeyboardChange: (Bool) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing
        let font = UIFont.preferredFont(forTextStyle: .body)
        view.typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.brand(.ink),
            .paragraphStyle: paragraph,
        ]
        view.font = font
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .brand(.ink)
        view.tintColor = .brand(.ink)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.accessibilityLabel = OnboardingCopy.Practice.box
        context.coordinator.textView = view
        context.coordinator.observe()
        if focusOnAppear {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PracticeTextView
        weak var textView: UITextView?
        private var token: NSObjectProtocol?

        init(parent: PracticeTextView) {
            self.parent = parent
        }

        func observe() {
            token = NotificationCenter.default.addObserver(
                forName: UITextInputMode.currentInputModeDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportKeyboard() }
            }
            reportKeyboard()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            reportKeyboard()
        }

        /// Uses the undocumented `identifier` of the input mode, like `SetupStatus` — best effort.
        private func reportKeyboard() {
            guard let mode = textView?.textInputMode, let appID = Bundle.main.bundleIdentifier else { return }
            let selector = NSSelectorFromString("identifier")
            let identifier = mode.responds(to: selector) ? mode.value(forKey: "identifier") as? String : nil
            parent.onKeyboardChange(identifier?.hasPrefix(appID + ".keyboard") == true)
        }

        isolated deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
