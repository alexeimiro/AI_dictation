import MurmurCore
import MurmurUI
import SwiftUI

/// An explicit choice about the user's data, with nothing preselected. The decision is recorded
/// with the policy version and time.
struct DataChoiceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let choice = store.answers.dataChoice?.choice
        OnboardingPage {
            OnboardingTitle(OnboardingCopy.DataChoice.title, line: OnboardingCopy.DataChoice.line)
                .padding(.top, 14)
            VStack(spacing: 12) {
                DataChoiceCard(title: OnboardingCopy.DataChoice.improveTitle,
                               detail: OnboardingCopy.DataChoice.improveDetail,
                               isSelected: choice == .improveModel) {
                    store.send(.selectDataChoice(.improveModel, at: Date()))
                }
                DataChoiceCard(title: OnboardingCopy.DataChoice.privateTitle,
                               detail: OnboardingCopy.DataChoice.privateDetail,
                               isSelected: choice == .doNotShare) {
                    store.send(.selectDataChoice(.doNotShare, at: Date()))
                }
            }
            .padding(.top, 22)
        } actions: {
            Button(OnboardingCopy.next) { store.send(.next) }
                .buttonStyle(.murmur(.primary))
                .disabled(!store.allows(.next))
        }
    }
}

private struct DataChoiceCard: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: title)
                        .font(.murmur(.headline))
                        .foregroundStyle(Theme.ink)
                    Text(verbatim: detail)
                        .font(.murmur(.subhead))
                        .lineSpacing(2)
                        .foregroundStyle(Theme.second)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                SelectionMark(isOn: isSelected)
            }
            .padding(16)
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(isSelected ? Theme.ink : Theme.line, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The languages from the enabled keyboards, filtered to what dictation supports, to confirm or
/// change.
struct ConfirmLanguagesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        let store = model.onboarding
        OnboardingPage {
            OnboardingTitle(OnboardingCopy.Languages.title, line: OnboardingCopy.Languages.line)
                .padding(.top, 14)
            VStack(spacing: 8) {
                ForEach(Array(store.answers.languages.enumerated()), id: \.element) { index, tag in
                    HStack(spacing: 12) {
                        Text(verbatim: Self.displayName(tag))
                            .font(.transcript(.callout))
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: index == 0 ? OnboardingCopy.Languages.primary : OnboardingCopy.Languages.second)
                            .font(.murmur(.footnote, weight: .semibold))
                            .foregroundStyle(Theme.third)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.ink, lineWidth: 1.5) }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 22)
        } actions: {
            VStack(spacing: 10) {
                Button(OnboardingCopy.Languages.edit) { editing = true }
                    .buttonStyle(.murmur(.secondary))
                Button(OnboardingCopy.next) { applyAndContinue() }
                    .buttonStyle(.murmur(.primary))
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
        VStack(spacing: 0) {
            SheetHeader(OnboardingCopy.Languages.pickerTitle, confirmTitle: OnboardingCopy.Languages.done,
                        canConfirm: !selected.isEmpty, cancel: { dismiss() }) {
                onDone(selected)
                dismiss()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: OnboardingCopy.Languages.pickerLine)
                        .font(.murmur(.subhead))
                        .foregroundStyle(Theme.second)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                    ForEach(available) { language in
                        row(language)
                        Hairline()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.canvas)
        .presentationBackground(Theme.canvas)
        // As in onboarding: text scales up to XXXL, the accessibility sizes beyond it are capped.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .task { available = await model.onboardingServices.languages.availableLanguages() }
    }

    private func row(_ language: DictationLanguage) -> some View {
        let index = selected.firstIndex(of: language.tag)
        return Button {
            toggle(language.tag)
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: language.localizedFullName)
                    .font(.transcript(.body))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let index {
                    Text(verbatim: index == 0 ? OnboardingCopy.Languages.primary : OnboardingCopy.Languages.second)
                        .font(.murmur(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.third)
                }
                CheckCircle(isOn: index != nil)
            }
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(selected.count >= 2 && index == nil)
        .opacity(selected.count >= 2 && index == nil ? 0.4 : 1)
        .accessibilityAddTraits(index == nil ? [] : .isSelected)
    }

    private func toggle(_ tag: String) {
        if let index = selected.firstIndex(of: tag) {
            selected.remove(at: index)
        } else if selected.count < 2 {
            selected.append(tag)
        }
    }
}

/// Writes the default style the keyboard uses, with what each style makes of one sentence.
struct DefaultStyleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        OnboardingPage {
            OnboardingTitle(OnboardingCopy.Style.title, line: OnboardingCopy.Style.line)
                .padding(.top, 14)
            SectionLabel(OnboardingCopy.Style.youSay)
                .padding(.top, 22)
            Text(verbatim: "“\(StyleView.spoken)”")
                .font(.transcript(.body))
                .lineSpacing(2)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(spacing: 12) {
                ForEach(StylePreset.allCases) { style in
                    StyleCard(style: style, isSelected: store.answers.style == style) {
                        store.send(.selectStyle(style))
                    }
                }
            }
            .padding(.top, 20)
        } actions: {
            Button(OnboardingCopy.next) {
                if let style = store.answers.style, store.send(.next), !model.launchOptions.usesOnboardingFixtures {
                    SharedSettings.shared.defaultStyle = style
                }
            }
            .buttonStyle(.murmur(.primary))
            .disabled(!store.allows(.next))
        }
        // Word for word is the default; one tap on Next keeps it. After a reinstall it's the
        // style the account had, taken when the user signed in (`StyleSync`).
        .onAppear {
            if store.answers.style == nil {
                let style = model.launchOptions.usesOnboardingFixtures ? .verbatim : SharedSettings.shared.defaultStyle
                store.send(.selectStyle(style))
            }
        }
    }
}

/// What notifications are for, with an example, before the system asks. "Not now" never blocks.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model
    @State private var requesting = false

    var body: some View {
        let store = model.onboarding
        OnboardingPage {
            Spacer(minLength: 16)
            NotificationPicture()
            Spacer(minLength: 16)
            OnboardingTitle(OnboardingCopy.Notifications.title, line: OnboardingCopy.Notifications.line)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(OnboardingCopy.Notifications.benefits, id: \.self) { benefit in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .accessibilityHidden(true)
                        Text(verbatim: benefit)
                            .font(.murmur(.callout))
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 2)
        } actions: {
            Button {
                requesting = true
                Task {
                    defer { requesting = false }
                    _ = await model.requestNotifications()
                    store.send(.next)
                }
            } label: {
                // Disabled, and so grey, while the system asks.
                if requesting { ProgressView().tint(Theme.ink) } else { Text(OnboardingCopy.Notifications.allow) }
            }
            .buttonStyle(.murmur(.primary))
            .disabled(requesting)
            Button(OnboardingCopy.Notifications.later) { store.send(.skipOptional) }
                .buttonStyle(.textOnly)
                .padding(.top, 4)
        }
    }
}

/// Murmur has no desktop app yet, so this offers a link for when it does, and asks before
/// recording the request.
struct DesktopOfferView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var email = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        let store = model.onboarding
        OnboardingPage {
            Spacer(minLength: 16)
            DesktopPicture()
            Spacer(minLength: 16)
            OnboardingTitle(OnboardingCopy.Desktop.title, line: OnboardingCopy.Desktop.line)
            FieldError(message: error)
                .padding(.top, 12)
        } actions: {
            Button {
                email = model.onboardingServices.auth.accountEmail ?? ""
                confirming = true
            } label: {
                // Disabled, and so grey, while it sends.
                if sending { ProgressView().tint(Theme.ink) } else { Text(OnboardingCopy.Desktop.accept) }
            }
            .buttonStyle(.murmur(.primary))
            .disabled(sending)
            Button(OnboardingCopy.Desktop.decline) { store.send(.desktopLinkDeclined) }
                .buttonStyle(.textOnly)
                .padding(.top, 4)
        }
        .alert(OnboardingCopy.Desktop.alertTitle, isPresented: $confirming) {
            TextField(OnboardingCopy.Desktop.alertField, text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
            Button(OnboardingCopy.Desktop.cancel, role: .cancel) {}
            Button(OnboardingCopy.Desktop.send) { send() }
                .disabled(!EmailSignInView.isValidEmail(email))
        } message: {
            Text(OnboardingCopy.Desktop.alertMessage)
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
                self.error = OnboardingCopy.Desktop.failed
            }
        }
    }
}

/// "How did you find Murmur?"
struct ReferralSourceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        ReferralPage(title: OnboardingCopy.Referral.title,
                     options: ReferralSource.allCases.map { ($0.rawValue, $0.title) },
                     selected: store.answers.referralSource?.rawValue) { value in
            if let source = ReferralSource(rawValue: value) { store.send(.selectReferral(source)) }
        }
    }
}

/// Which one, only after "Search engine".
struct ReferralDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let options = store.answers.referralSource?.detailOptions ?? []
        ReferralPage(title: OnboardingCopy.Referral.detailTitle, options: options.map { ($0, $0) },
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
        OnboardingPage {
            OnboardingTitle(title)
                .padding(.top, 14)
            VStack(spacing: 8) {
                ForEach(options, id: \.id) { option in
                    OptionRow(option.title, isSelected: selected == option.id, marker: .mark) {
                        select(option.id)
                    }
                }
            }
            .padding(.top, 18)
        } actions: {
            Button(OnboardingCopy.next) { store.send(.next) }
                .buttonStyle(.murmur(.primary))
                .disabled(!store.allows(.next))
        }
    }
}

extension ReferralSource {
    var title: String {
        switch self {
        case .xTwitter: OnboardingCopy.Referral.xTwitter
        case .searchEngine: OnboardingCopy.Referral.searchEngine
        case .tikTok: OnboardingCopy.Referral.tikTok
        case .articleNews: OnboardingCopy.Referral.articleNews
        case .newsletter: OnboardingCopy.Referral.newsletter
        case .linkedIn: OnboardingCopy.Referral.linkedIn
        case .friendColleague: OnboardingCopy.Referral.friendColleague
        case .youTube: OnboardingCopy.Referral.youTube
        case .reddit: OnboardingCopy.Referral.reddit
        case .other: OnboardingCopy.Referral.other
        }
    }
}
