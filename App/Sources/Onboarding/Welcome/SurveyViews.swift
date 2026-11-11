import MurmurUI
import SwiftUI

/// "What do you want help with?" Any number of answers; Next needs one.
struct UseCasesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        OnboardingPage {
            OnboardingTitle(OnboardingCopy.Survey.title, line: OnboardingCopy.Survey.line)
                .padding(.top, 14)
            VStack(spacing: 8) {
                ForEach(UseCase.allCases) { useCase in
                    OptionRow(useCase.title, isSelected: store.answers.useCases.contains(useCase)) {
                        store.send(.toggleUseCase(useCase))
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

/// What Murmur does for the first thing the user picked: the talk button over a text box with
/// that kind of writing in it.
struct PersonalizedExplainerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let useCase = UseCase.allCases.first { store.answers.useCases.contains($0) } ?? .typeFaster
        OnboardingPage {
            OnboardingTitle(OnboardingCopy.Explainer.title(benefit: useCase.benefit))
                .padding(.top, 14)
            Spacer(minLength: 32)
            VStack(spacing: 44) {
                TalkButtonPicture(size: 72, mode: .listening(reach: 1.9))
                TextBoxPicture(label: useCase.place, text: useCase.sample)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 32)
        } actions: {
            Button(OnboardingCopy.next) { store.send(.next) }
                .buttonStyle(.murmur(.primary))
        }
    }
}

extension UseCase {
    var title: String {
        switch self {
        case .messages: OnboardingCopy.Survey.messages
        case .emails: OnboardingCopy.Survey.emails
        case .chatWithAI: OnboardingCopy.Survey.chatWithAI
        case .captureIdeas: OnboardingCopy.Survey.captureIdeas
        case .onTheGo: OnboardingCopy.Survey.onTheGo
        case .typeFaster: OnboardingCopy.Survey.typeFaster
        case .typingIsHard: OnboardingCopy.Survey.typingIsHard
        }
    }

    /// "Murmur helps you <benefit>, wherever you write."
    var benefit: String {
        switch self {
        case .messages: OnboardingCopy.Explainer.messages
        case .emails: OnboardingCopy.Explainer.emails
        case .chatWithAI: OnboardingCopy.Explainer.chatWithAI
        case .captureIdeas: OnboardingCopy.Explainer.captureIdeas
        case .onTheGo: OnboardingCopy.Explainer.onTheGo
        case .typeFaster: OnboardingCopy.Explainer.typeFaster
        case .typingIsHard: OnboardingCopy.Explainer.typingIsHard
        }
    }

    /// The label on the explainer's text box: where this kind of writing goes.
    var place: String {
        switch self {
        case .messages, .onTheGo, .typeFaster: OnboardingCopy.Explainer.message
        case .emails: OnboardingCopy.Explainer.email
        case .chatWithAI: OnboardingCopy.Explainer.assistant
        case .captureIdeas, .typingIsHard: OnboardingCopy.Explainer.note
        }
    }

    /// What was said into it.
    var sample: String {
        switch self {
        case .messages, .typeFaster: OnboardingCopy.Explainer.messageSample
        case .emails: OnboardingCopy.Explainer.emailSample
        case .chatWithAI: OnboardingCopy.Explainer.assistantSample
        case .captureIdeas: OnboardingCopy.Explainer.ideaSample
        case .onTheGo: OnboardingCopy.Explainer.onTheGoSample
        case .typingIsHard: OnboardingCopy.Explainer.noteSample
        }
    }
}
