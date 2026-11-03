import MurmurCore
import MurmurUI
import SwiftUI
import UIKit

/// References 19–29: the three exercises. The text box is a real text view, so the dictation runs
/// through the real Murmur keyboard and session; the screen only watches the result.
struct PracticeView: View {
    let exercise: PracticeExercise
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var murmurKeyboardActive = false
    @State private var fullAccessHint = false

    var body: some View {
        let store = model.onboarding
        let done = store.record.isDone(exercise)
        VStack(spacing: 0) {
            OnboardingHeader()
            VStack(spacing: 0) {
                title
                    .padding(.top, showsKeyboardGuide ? 28 : exercise == .basic ? 26 : 24.5)
                if let subtitle {
                    Text(subtitle)
                        .font(.ui(14.5, .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.top, 9)
                }
                if showsKeyboardGuide {
                    GlobeKeyIllustration()
                        .frame(width: 271, height: 232)
                        .padding(.top, 30.7)
                }
                // Under the guide the box stays focused but hidden, so the real keyboard is up to
                // switch from (reference 20); picking Murmur's reveals the same box, keyboard still up.
                editor
                    .padding(.top, exercise == .basic ? 13 : 14)
                    .padding(.horizontal, 20)
                    .frame(height: showsKeyboardGuide ? 0 : nil, alignment: .top)
                    .opacity(showsKeyboardGuide ? 0 : 1)
                    .allowsHitTesting(!showsKeyboardGuide)
                    .accessibilityHidden(showsKeyboardGuide)
                feedback
                if done {
                    Button("Next") { store.send(.next) }
                        .buttonStyle(.pill(.ink))
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer(minLength: 0)
            }
            .animation(.smooth(duration: 0.3), value: done)
        }
        .background(Palette.paper)
        .overlay(alignment: .bottomTrailing) {
            // UI tests drive the scripted dictation from here; never shown otherwise.
            if model.launchOptions.onboardingFixtures {
                Button("Simulate dictation") { model.practice.simulateDictation() }
                    .font(.ui(13))
                    .padding(12)
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
        switch exercise {
        case .basic where showsKeyboardGuide:
            SerifTitle("Tap and hold 🌐, then\npick the \(Brand.name) keyboard", size: 33,
                       color: Palette.ink, tracking: -0.4, lineHeight: 39)
                .padding(.horizontal, 20)
        case .basic:
            let check = Text(CheckBadge.image(size: 30)).baselineOffset(-5)
            let sparkles = Text(Sparkles.image(size: 23)).baselineOffset(-1)
            Text("Say anything, tap \(check), and see it appear like magic\u{00A0}\(sparkles)")
                .font(.serif(31))
                .tracking(0)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .lineHeight(.exact(points: 42.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
        case .formatting:
            SwashTitle(lead: "Try dictating an ", accent: "email", tail: "", size: 39)
        case .whisper:
            SwashTitle(lead: "Try ", accent: "whispering", tail: " a note", size: 41)
        }
    }

    private var subtitle: String? {
        switch exercise {
        case .basic: nil
        case .formatting: "\(Brand.name) handles formatting and fixes mistakes!"
        case .whisper: "Bring your phone close to your face"
        }
    }

    @ViewBuilder
    private var editor: some View {
        // Fixture runs keep the keyboard down: they dictate through the scripted client.
        let field = PracticeTextView(text: $text, fontSize: textSize,
                                     focusOnAppear: !model.launchOptions.usesOnboardingFixtures) { active in
            if !model.launchOptions.usesOnboardingFixtures { murmurKeyboardActive = active }
        }
        switch exercise {
        case .basic:
            field
                .overlay(alignment: .topLeading) { placeholder("Say something!") }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .frame(height: 149)
                .background(Palette.paper, in: .rect(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xE6E5E9), lineWidth: 1) }
        case .formatting:
            PracticeCard(height: 189) {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.fill").font(.system(size: 16)).foregroundStyle(Palette.accent)
                    Text("Mail").font(.ui(15, .medium))
                    Spacer()
                    Image(systemName: "paperplane").font(.system(size: 16))
                }
            } content: {
                field.overlay(alignment: .topLeading) {
                    placeholder("Hey Tim, are you available on Friday at 3pm…actually 4pm?")
                }
            }
        case .whisper:
            PracticeCard(height: 187) {
                HStack(spacing: 18) {
                    Image(systemName: "checkmark")
                    Image(systemName: "arrow.uturn.backward")
                    Image(systemName: "arrow.uturn.forward")
                    Spacer()
                    Image(systemName: "ellipsis")
                }
                .font(.system(size: 16))
                .overlay { Text("Notes").font(.ui(14.5, .medium)) }
            } content: {
                field.overlay(alignment: .topLeading) {
                    placeholder("Things to do today:\n1. Run the laundry\n2. Buy groceries")
                }
            }
        }
    }

    /// The box text: a little smaller in the email and note cards.
    private var textSize: CGFloat { exercise == .basic ? 17 : 17.5 }

    @ViewBuilder
    private func placeholder(_ value: String) -> some View {
        if text.isEmpty {
            Text(value)
                .font(.ui(textSize))
                .foregroundStyle(Color(hex: 0xA9A7AD))
                .lineSpacing(exercise == .formatting ? 6.5 : PracticeTextView.lineSpacing)
                .padding(.top, 8)
                .padding(.leading, 5)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if fullAccessHint {
            HStack(spacing: 10) {
                Text("Turn on Allow Full Access so the keyboard can dictate.")
                    .font(.ui(14))
                    .foregroundStyle(Palette.text)
                Button("Open Settings") { model.setup.openSettings() }
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
        } else if case .failed(let message) = model.practice.state {
            Text(message)
                .font(.ui(14))
                .foregroundStyle(Palette.danger)
                .padding(.horizontal, 22)
                .padding(.top, 12)
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

/// "Try dictating an *email*" with an orange swash under the accent word.
private struct SwashTitle: View {
    let lead: String
    let accent: String
    let tail: String
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(lead)
            Text(accent)
                .font(.serif(size, .italic))
                .overlay(alignment: .bottom) {
                    Swash()
                        .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                        .frame(height: 8)
                        .offset(y: 1)
                }
            Text(tail)
        }
        .font(.serif(size))
        .tracking(-0.9)
        .foregroundStyle(Palette.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
}

/// A loose hand-drawn underline.
private struct Swash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.35),
                      control1: CGPoint(x: rect.width * 0.25, y: rect.minY),
                      control2: CGPoint(x: rect.width * 0.7, y: rect.maxY + rect.height * 0.4))
        return path
    }
}

/// The ink ✓ badge from the keyboard, inline in a title.
private enum CheckBadge {
    static func image(size: CGFloat) -> Image {
        Image(size: CGSize(width: size, height: size), label: Text("check mark")) { context in
            context.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: size, height: size)), with: .color(Palette.ink))
            var check = Path()
            check.move(to: CGPoint(x: size * 0.29, y: size * 0.52))
            check.addLine(to: CGPoint(x: size * 0.44, y: size * 0.67))
            check.addLine(to: CGPoint(x: size * 0.72, y: size * 0.36))
            context.stroke(check, with: .color(.white),
                           style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A compose card with an app-like header strip (Mail, Notes).
private struct PracticeCard<Header: View, Content: View>: View {
    let height: CGFloat
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 18)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(Color(hex: 0xF2F1F4))
            content
                .padding(.horizontal, 22)
                .padding(.top, 10.5)
                .padding(.bottom, 10)
        }
        .frame(height: height)
        .background(Palette.paper)
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(Color(hex: 0xE6E5E9), lineWidth: 1) }
    }
}

/// A UITextView so the Murmur keyboard can type into it, and so the screen can tell which
/// keyboard is up (switching to Murmur's changes the title).
struct PracticeTextView: UIViewRepresentable {
    static let lineSpacing: CGFloat = 1.2

    @Binding var text: String
    var fontSize: CGFloat = 17
    var focusOnAppear = true
    let onKeyboardChange: (Bool) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing
        view.typingAttributes = [
            .font: UIFont(name: FontName.uiRegular, size: fontSize) ?? .systemFont(ofSize: fontSize),
            .foregroundColor: UIColor(Palette.text),
            .paragraphStyle: paragraph,
        ]
        view.font = UIFont(name: FontName.uiRegular, size: fontSize) ?? .systemFont(ofSize: fontSize)
        view.textColor = UIColor(Palette.text)
        view.tintColor = UIColor(Color(hex: 0x9C86E8))
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.accessibilityLabel = "Practice text"
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
