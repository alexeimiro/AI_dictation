import MurmurCore
import MurmurUI
import SwiftUI

/// Reference 32: an explicit choice, nothing preselected (the reference preselects sharing; we
/// don't). The decision is recorded with the policy version and time.
struct DataChoiceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let choice = store.answers.dataChoice?.choice
        OnboardingPage(scrollable: false) {
            ScrollView {
                VStack(spacing: 0) {
                    SerifTitle("Your data is safe", accent: "safe", size: 33, color: Palette.ink, tracking: -0.3)
                        .padding(.top, 11)
                    Text("Choose how \(Brand.name) handles your\nvoice and text")
                        .font(.ui(16, .medium))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                    VStack(spacing: 10) {
                        DataChoiceCard(
                            title: "Improve \(Brand.name) for everyone",
                            detail: "To make \(Brand.name) better, this option lets us review your transcripts and edits to improve transcription and cleanup.",
                            locked: false, isSelected: choice == .improveModel) {
                                store.send(.selectDataChoice(.improveModel, at: Date()))
                            }
                        DataChoiceCard(
                            title: "Don’t share data",
                            detail: "Your dictations are only used to write your text, never for training by us or anyone else.",
                            locked: true, isSelected: choice == .doNotShare) {
                                store.send(.selectDataChoice(.doNotShare, at: Date()))
                            }
                    }
                    .padding(.horizontal, 31)
                    .padding(.top, 17)
                }
            }
            .scrollIndicators(.hidden)
        } actions: {
            Button("Next") { store.send(.next) }
                .buttonStyle(.pill(.ink))
                .disabled(!store.allows(.next))
        }
    }
}

private struct DataChoiceCard: View {
    let title: String
    let detail: String
    let locked: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    Text(title)
                        .font(.ui(21, .medium))
                        .foregroundStyle(Palette.text)
                    Spacer(minLength: 12)
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 19)).foregroundStyle(Palette.text)
                    }
                }
                Text(detail)
                    .font(.ui(17))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .padding(.leading, 23)
            .padding(.trailing, 25)
            .padding(.vertical, 22.2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.selectedFill : Palette.paper, in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(isSelected ? Palette.ink : Palette.cardBorder, lineWidth: isSelected ? 2.5 : Metrics.borderWidth)
            }
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Reference 33: languages from the enabled keyboards, filtered to what dictation supports.
struct ConfirmLanguagesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        let store = model.onboarding
        OnboardingPage {
            VStack(spacing: 0) {
                SerifTitle("Confirm your language", size: 33, color: Palette.ink, tracking: -0.3)
                    .padding(.top, 11)
                Text("We picked this from your keyboard. Add or\nremove languages if needed.")
                    .font(.ui(16))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                VStack(spacing: 10) {
                    ForEach(store.answers.languages, id: \.self) { tag in
                        Text(Self.displayName(tag))
                            .font(.transcript(.title3))
                            .foregroundStyle(Palette.text)
                            .padding(.horizontal, 23)
                            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                            .background(Palette.selectedFill, in: .rect(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).stroke(Palette.ink, lineWidth: 2) }
                    }
                }
                .padding(.horizontal, 31)
                .padding(.top, 33)
                Spacer(minLength: 0)
            }
        } actions: {
            VStack(spacing: 16) {
                Button("Edit") { editing = true }
                    .buttonStyle(.pill(.outline))
                Button("Next") { applyAndContinue() }
                    .buttonStyle(.pill(.ink))
                    .disabled(!store.allows(.next))
            }
        }
        .sheet(isPresented: $editing) {
            LanguagePicker(selected: store.answers.languages) { tags in
                store.send(.setLanguages(tags))
            }
        }
        .task {
            if store.answers.languages.isEmpty {
                store.send(.setLanguages(await model.onboardingServices.languages.detectedLanguages()))
            }
        }
    }

    /// "English", "Russian (Русский)": the name, plus its own name when it differs.
    static func displayName(_ tag: String) -> String {
        let language = DictationLanguage(tag: tag)
        let native = Locale(identifier: tag).localizedString(forLanguageCode: language.languageCode)
        guard let native, native.lowercased() != language.localizedName.lowercased() else { return language.localizedName }
        return "\(language.localizedName) (\(native.prefix(1).uppercased() + native.dropFirst()))"
    }

    /// The first language becomes the primary one, the second the keyboard's switch.
    private func applyAndContinue() {
        let tags = model.onboarding.answers.languages
        guard model.onboarding.send(.next) else { return }
        guard !model.launchOptions.usesOnboardingFixtures, let primary = tags.first else { return }
        Task {
            await model.languages.setPrimary(primary)
            await model.languages.setSecondary(tags.dropFirst().first)
        }
    }
}

/// Edit: up to two languages, since dictation switches between a primary and a secondary one.
private struct LanguagePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var selected: [String]
    let onDone: ([String]) -> Void
    @State private var available: [DictationLanguage] = []

    init(selected: [String], onDone: @escaping ([String]) -> Void) {
        _selected = State(initialValue: selected)
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            List(available) { language in
                Button {
                    toggle(language.tag)
                } label: {
                    HStack {
                        Text(language.localizedFullName).font(.transcript()).foregroundStyle(Palette.text)
                        Spacer()
                        if let index = selected.firstIndex(of: language.tag) {
                            Text(index == 0 ? "Primary" : "Second")
                                .font(.ui(13, .medium))
                                .foregroundStyle(Palette.textSecondary)
                            Image(systemName: "checkmark").foregroundStyle(Palette.ink)
                        }
                    }
                }
                .disabled(selected.count >= 2 && !selected.contains(language.tag))
            }
            .navigationTitle("Languages")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                Text("\(Brand.name) dictates in up to two languages and switches between them from the keyboard.")
                    .font(.ui(14))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .task { available = await model.onboardingServices.languages.availableLanguages() }
    }

    private func toggle(_ tag: String) {
        if let index = selected.firstIndex(of: tag) {
            selected.remove(at: index)
        } else if selected.count < 2 {
            selected.append(tag)
        }
    }
}

/// Reference 34: writes the default style the keyboard uses.
struct DefaultStyleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        OnboardingPage(scrollable: false) {
            ScrollView {
                VStack(spacing: 0) {
                    SerifTitle("Set your default style", accent: "default style", accentStyle: .purple, size: 32.5,
                               color: Palette.ink, tracking: -0.3)
                        .padding(.top, 16.7)
                    Text("\(Brand.name) will use this style for all your dictations.\nYou can change it anytime from the keyboard.")
                        .font(.ui(16))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 15)
                    VStack(spacing: 18) {
                        ForEach(StylePreset.allCases) { style in
                            OptionCard(style.title, subtitle: style.subtitle,
                                       isSelected: store.answers.style == style, height: 71.3) {
                                store.send(.selectStyle(style))
                            }
                        }
                    }
                    .padding(.horizontal, 31)
                    .padding(.top, 41)
                }
            }
            .scrollIndicators(.hidden)
            // Word for word is the default; one tap on Next keeps it.
            .onAppear { if store.answers.style == nil { store.send(.selectStyle(.verbatim)) } }
        } actions: {
            Button("Next") {
                if let style = store.answers.style, store.send(.next), !model.launchOptions.usesOnboardingFixtures {
                    SharedSettings.shared.defaultStyle = style
                }
            }
            .buttonStyle(.pill(.ink))
            .disabled(!store.allows(.next))
        }
    }
}


/// References 35–36: benefits first, then the system prompt. "Maybe later" never blocks.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @State private var requesting = false

    var body: some View {
        let store = model.onboarding
        OnboardingPage(actionInset: 16) {
            VStack(spacing: 0) {
                SerifTitle("Allow notifications", size: 33, color: Palette.ink, tracking: -0.3)
                    .padding(.top, 11)
                Text("Remember, you can opt out anytime.")
                    .font(.ui(16))
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 12)
                NotificationsIllustration()
                    .scaleEffect(0.78)
                    .frame(width: 220, height: 220)
                    .padding(.top, 12)
                VStack(alignment: .leading, spacing: 13.5) {
                    benefit("lightbulb", "Learn tips that help you dictate faster")
                    benefit("arrow.triangle.2.circlepath", "Stay in the loop with new features")
                    benefit("clock.badge.checkmark", "Receive gentle reminders to use \(Brand.name)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 49)
                .padding(.top, 93.7)
                Spacer(minLength: 0)
            }
        } actions: {
            VStack(spacing: 14) {
                Button {
                    requesting = true
                    Task {
                        defer { requesting = false }
                        _ = await model.requestNotifications()
                        store.send(.next)
                    }
                } label: {
                    if requesting { ProgressView().tint(.white) } else { Text("Allow notifications") }
                }
                .buttonStyle(.pill(.ink))
                .disabled(requesting)
                Button("Maybe later") { store.send(.skipOptional) }
                    .buttonStyle(.quiet(size: 14))
                    .padding(.top, 2)
                    .padding(.bottom, -22)
            }
        }
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 15) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 20)
            Text(text).font(.ui(17))
        }
        .foregroundStyle(Palette.ink)
    }
}

/// Reference 37. Murmur has no desktop app yet, so this offers a link for when it does, and asks
/// before recording the request.
struct DesktopOfferView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var email = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        let store = model.onboarding
        OnboardingPage(actionInset: 16) {
            VStack(spacing: 0) {
                SerifTitle("\(Brand.name) is coming to your computer", size: 33.5, color: Palette.ink,
                           tracking: -0.3, lineHeight: 43.3)
                    .padding(.horizontal, 40)
                    .padding(.top, 9.3)
                Text("\(Brand.name) is great on iPhone. Want it on your Mac or PC too? We’ll email you a link when it’s ready.")
                    .font(.ui(16))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 13.4)
                DesktopIllustration()
                    .frame(height: 245)
                    .padding(.horizontal, 16)
                    .padding(.top, 34)
                if let error {
                    Text(error).font(.ui(14)).foregroundStyle(Palette.danger).padding(.top, 12)
                }
                Spacer(minLength: 0)
            }
        } actions: {
            VStack(spacing: 14) {
                Button {
                    email = model.onboardingServices.auth.accountEmail ?? ""
                    confirming = true
                } label: {
                    if sending { ProgressView().tint(.white) } else { Text("Email me a link for later") }
                }
                .buttonStyle(.pill(.ink))
                .disabled(sending)
                Button("Another time") { store.send(.desktopLinkDeclined) }
                    .buttonStyle(.quiet(size: 14))
                    .padding(.top, -6)
                    .padding(.bottom, -22)
            }
        }
        .alert("Email a link?", isPresented: $confirming) {
            TextField("Email address", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Send") { send() }
                .disabled(!EmailSignInView.isValidEmail(email))
        } message: {
            Text("We’ll send it when \(Brand.name) for desktop is available.")
        }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                try await model.onboardingServices.profile.requestDesktopLink(email: email)
                model.onboarding.send(.desktopLinkRequested(at: Date()))
            } catch {
                self.error = "Couldn’t save that. Try again, or choose Another time."
            }
        }
    }
}

/// Reference 38.
struct ReferralSourceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        ReferralPage(title: "Where did you hear about us?",
                     options: ReferralSource.allCases.map { ($0.rawValue, $0.title) },
                     selected: store.answers.referralSource?.rawValue) { value in
            if let source = ReferralSource(rawValue: value) { store.send(.selectReferral(source)) }
        }
    }
}

/// Reference 39: only after "Search engine".
struct ReferralDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let options = store.answers.referralSource?.detailOptions ?? []
        ReferralPage(title: "Which search engine?", options: options.map { ($0, $0) },
                     selected: store.answers.referralDetail) { store.send(.selectReferralDetail($0)) }
    }
}

private struct ReferralPage: View {
    @Environment(AppModel.self) private var model
    let title: String
    let options: [(id: String, title: String)]
    let selected: String?
    let select: (String) -> Void

    var body: some View {
        let store = model.onboarding
        OnboardingPage(scrollable: false) {
            ScrollView {
                VStack(spacing: 0) {
                    SerifTitle(title, size: 33, color: Palette.ink, tracking: -2.1)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                    VStack(spacing: 18) {
                        ForEach(options, id: \.id) { option in
                            OptionCard(option.title, isSelected: selected == option.id, height: 64) {
                                select(option.id)
                            }
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 31)
                    .padding(.bottom, 40)
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) { BottomFade() }
        } actions: {
            Button("Next") { store.send(.next) }
                .buttonStyle(.pill(.ink))
                .disabled(!store.allows(.next))
        }
    }
}

extension ReferralSource {
    var title: String {
        switch self {
        case .xTwitter: "X / Twitter"
        case .searchEngine: "Search engine"
        case .tikTok: "TikTok"
        case .articleNews: "Article / News"
        case .newsletter: "Newsletter"
        case .linkedIn: "LinkedIn"
        case .friendColleague: "Friend / Colleague"
        case .youTube: "YouTube"
        case .reddit: "Reddit"
        case .other: "Other"
        }
    }
}
