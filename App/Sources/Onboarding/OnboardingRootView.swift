import MurmurUI
import SwiftUI

/// The onboarding journey as a full-screen root. One page per `OnboardingStep`; the store decides
/// which, and pages only send events.
struct OnboardingRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = model.onboarding
        ZStack {
            Theme.canvas.ignoresSafeArea()
            page(for: store.step)
                .environment(\.onboardingStep, store.step)
                .id(store.step)
                .transition(transition(back: store.movedBack))
        }
        .animation(.smooth(duration: 0.35), value: store.step)
        // Text scales up to XXXL; the accessibility sizes beyond it are capped here.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// Pages slide the way the journey moves; under Reduce Motion they fade.
    private func transition(back: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return back ? .onboardingBackward : .onboardingForward
    }

    @ViewBuilder
    private func page(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: WelcomeCarouselView(page: OnboardingFixtures.welcomePage(variant: model.launchOptions.onboardingVariant))
        case .useCases: UseCasesView()
        case .personalizedExplainer: PersonalizedExplainerView()
        case .signIn, .signInOptions: SignInView(expanded: step == .signInOptions)
        case .emailSignIn: EmailSignInView()
        case .setupIntro: SetupIntroView()
        case .keyboardInstructions: KeyboardInstructionsView()
        case .practiceIntro: PracticeIntroView()
        case .microphonePrimer: MicrophonePrimerView()
        case .basicPractice: PracticeView(exercise: .basic)
        case .formattingPractice: PracticeView(exercise: .formatting)
        case .whisperIntro: WhisperIntroView()
        case .whisperPractice: PracticeView(exercise: .whisper)
        case .practiceComplete: PracticeCompleteView()
        case .wrapUpIntro: WrapUpIntroView()
        case .dataChoice: DataChoiceView()
        case .languages: ConfirmLanguagesView()
        case .defaultStyle: DefaultStyleView()
        case .notifications: NotificationsView()
        case .desktopOffer: DesktopOfferView()
        case .referralSource: ReferralSourceView()
        case .referralDetail: ReferralDetailView()
        case .ready: ReadyView()
        case .trialOffer: TrialOfferView()
        case .complete: Color.clear
        }
    }
}

extension AnyTransition {
    static var onboardingForward: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }

    static var onboardingBackward: AnyTransition {
        .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity))
    }
}
