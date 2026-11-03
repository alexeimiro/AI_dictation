import MurmurUI
import SwiftUI

/// Which header a step shows. The segments are phases (survey, keyboard, practice, wrap-up,
/// referral); a partly filled segment is progress inside a phase, as in the references.
enum OnboardingProgress {
    static func fills(for step: OnboardingStep) -> [Double]? {
        switch step {
        case .useCases: [1, 0.3]
        case .personalizedExplainer: [1, 1]
        case .keyboardInstructions: [1, 0]
        case .microphonePrimer, .basicPractice: [1, 0.33, 0]
        case .formattingPractice: [1, 0.66, 0]
        case .whisperIntro: [1, 1, 0]
        case .whisperPractice: [1, 1, 0.55]
        case .practiceComplete: [1, 1, 1]
        case .dataChoice: [1, 0, 0, 0, 0]
        case .languages: [1, 1, 0, 0, 0]
        case .defaultStyle: [1, 1, 1, 0, 0]
        case .notifications: [1, 1, 1, 1, 0]
        case .desktopOffer: [1, 1, 1, 1, 1]
        case .referralSource: [1, 0]
        case .referralDetail: [1, 1]
        default: nil
        }
    }

    /// Skip sits in the header on the exercises and the style screen.
    static func showsSkip(_ step: OnboardingStep) -> Bool {
        [.basicPractice, .formattingPractice, .whisperIntro, .whisperPractice, .defaultStyle].contains(step)
    }
}

/// The back chevron, progress and Skip for the current step, wired to the store.
struct OnboardingHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let step = store.step
        if let fills = OnboardingProgress.fills(for: step) {
            SegmentedProgressHeader(
                fills: fills,
                onBack: OnboardingReducer.backward(from: step) == nil ? nil : { store.send(.back) },
                onSkip: OnboardingProgress.showsSkip(step) ? { store.send(.skipOptional) } : nil)
                .padding(.top, 11)
        }
    }
}

/// Header, content, and the bottom action region at the reference positions: the primary
/// button's bottom edge sits 64 pt above the bottom of a 402 × 874 screen.
struct OnboardingPage<Content: View, Actions: View>: View {
    var showsHeader = true
    var actionInset: CGFloat = Metrics.screenMargin
    /// False for pages whose content is already a scroll view (long option lists).
    var scrollable = true
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { OnboardingHeader() }
            if scrollable {
                // At least as tall as the space above the buttons, so the layout is the reference's
                // when it fits; at large text sizes it scrolls instead of running under the buttons.
                GeometryReader { proxy in
                    ScrollView {
                        content
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                }
            } else {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            actions
                .padding(.horizontal, actionInset)
                .padding(.bottom, Metrics.buttonBottom - 34)
        }
        .background(Palette.paper)
    }
}

/// Serif title and subtitle centered above a lavender button ("Let's set up Murmur",
/// "Now, let's test the magic", "Wrap up the setup").
struct IntroPage: View {
    let title: String
    var accent: String?
    var sparkles = false
    /// Letter spacing; the references set some of these titles tighter than others.
    var tracking: CGFloat = -2
    /// From the top of the safe area to the title.
    var top: CGFloat = 230
    var lineHeight: CGFloat = 79
    var subtitleGap: CGFloat = 13.6
    let subtitle: String
    let button: String
    let action: () -> Void

    var body: some View {
        OnboardingPage(showsHeader: false) {
            VStack(spacing: 0) {
                SerifTitle(title, accent: accent, size: 64, color: Palette.ink, tracking: tracking,
                           lineHeight: lineHeight, trailing: sparkles ? Sparkles.image(size: 44) : nil)
                Text(subtitle)
                    .font(.ui(20))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, subtitleGap)
            }
            .padding(.horizontal, 24)
            .padding(.top, top)
        } actions: {
            Button(button, action: action)
                .buttonStyle(.pill(.lavender))
        }
    }
}
