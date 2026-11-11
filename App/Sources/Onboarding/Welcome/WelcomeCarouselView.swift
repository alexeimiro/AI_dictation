import MurmurUI
import SwiftUI

/// Where the journey starts: the talk button, listening, over something it has just heard. Three
/// pages say what Murmur does; they turn by themselves, with a swipe, or from the page dots with
/// VoiceOver. "Get started" is always there.
struct WelcomeCarouselView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int

    init(page: Int = 0) {
        _page = State(initialValue: page)
    }

    var body: some View {
        let current = WelcomePage(rawValue: page) ?? .talk
        OnboardingPage(top: .wordmark) {
            Spacer(minLength: 24)
            VStack(spacing: 68) {
                TalkButtonPicture(mode: .listening(reach: 2.2))
                // All three, one showing: the page keeps its height as they change.
                ZStack(alignment: .top) {
                    ForEach(WelcomePage.allCases) { item in
                        WelcomeSample(page: item)
                            .opacity(item == current ? 1 : 0)
                            .accessibilityHidden(item != current)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 24)
            ZStack(alignment: .topLeading) {
                ForEach(WelcomePage.allCases) { item in
                    Text(verbatim: item.title)
                        .font(.murmur(.display))
                        .tracking(-0.8)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(item == current ? 1 : 0)
                        .accessibilityHidden(item != current)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Text(verbatim: OnboardingCopy.Welcome.line)
                .font(.murmur(.body))
                .lineSpacing(2)
                .foregroundStyle(Theme.second)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            PageDots(count: WelcomePage.allCases.count, current: page)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: turn(by: 1)
                    case .decrement: turn(by: -1)
                    @unknown default: break
                    }
                }
                .padding(.top, 22)
                .padding(.bottom, 6)
        } actions: {
            Button(OnboardingCopy.Welcome.button) { model.onboarding.send(.next) }
                .buttonStyle(.murmur(.primary))
        }
        .contentShape(.rect)
        // Beside the page's own scrolling, which only moves when the text is too large to fit.
        .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
            turn(by: value.translation.width < 0 ? 1 : -1)
        })
        .task(id: page) {
            guard !reduceMotion, !model.launchOptions.isOnboardingScreenshot else { return }
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            show((page + 1) % WelcomePage.allCases.count)
        }
    }

    /// A swipe or VoiceOver's adjust: one page on or back, stopping at the ends.
    private func turn(by step: Int) {
        guard WelcomePage(rawValue: page + step) != nil else { return }
        show(page + step)
    }

    private func show(_ next: Int) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.35)) { page = next }
    }
}

enum WelcomePage: Int, CaseIterable, Identifiable {
    case talk, languages, dictionary

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .talk: OnboardingCopy.Welcome.talk
        case .languages: OnboardingCopy.Welcome.languages
        case .dictionary: OnboardingCopy.Welcome.dictionary
        }
    }

    /// What the talk button has just heard.
    var sample: String {
        switch self {
        case .talk: OnboardingCopy.Welcome.talkSample
        case .languages: OnboardingCopy.Welcome.languagesSample
        case .dictionary: OnboardingCopy.Welcome.dictionarySample
        }
    }

    var caption: String? {
        switch self {
        case .talk: nil
        case .languages: OnboardingCopy.Welcome.languagesCaption
        case .dictionary: OnboardingCopy.Welcome.dictionaryCaption
        }
    }
}

/// A page's dictated sentence, with a line under it where it needs explaining.
private struct WelcomeSample: View {
    let page: WelcomePage

    var body: some View {
        VStack(spacing: 12) {
            Text(sentence)
                .font(.transcript(.title2))
                .tracking(-0.3)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let caption = page.caption {
                Text(verbatim: caption)
                    .font(.murmur(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.second)
            }
        }
        .frame(maxWidth: 300)
        .accessibilityElement(children: .combine)
    }

    /// The words that came from the dictionary are in bold.
    private var sentence: AttributedString {
        var text = AttributedString(page.sample)
        guard page == .dictionary else { return text }
        for word in OnboardingCopy.Welcome.dictionaryWords {
            if let range = text.range(of: word) {
                text[range].font = .system(.title2, weight: .bold)
            }
        }
        return text
    }
}
