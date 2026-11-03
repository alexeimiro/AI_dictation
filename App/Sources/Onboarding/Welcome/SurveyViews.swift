import MurmurCore
import MurmurUI
import SwiftUI

/// Reference 04: "Which of these do you resonate with?" Multi-select; Next needs one answer.
struct UseCasesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        OnboardingPage(scrollable: false) {
            ScrollView {
                VStack(spacing: 0) {
                    SerifTitle("Which of these do you resonate with?", size: 33, color: Palette.ink,
                               tracking: -1.9, lineHeight: 40.5)
                        .padding(.horizontal, 70)
                        .padding(.top, 10)
                    Text("Select all that apply.")
                        .font(.ui(16, .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.top, 10)
                    VStack(spacing: 14) {
                        ForEach(UseCase.allCases) { useCase in
                            OptionCard(useCase.title, systemImage: useCase.systemImage,
                                       isSelected: store.answers.useCases.contains(useCase), height: 64) {
                                store.send(.toggleUseCase(useCase))
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 25)
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

/// Reference 05: what Murmur does for the first thing the user picked.
struct PersonalizedExplainerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.onboarding
        let useCase = UseCase.allCases.first { store.answers.useCases.contains($0) } ?? .typeFaster
        OnboardingPage {
            VStack(spacing: 0) {
                SerifTitle("\(Brand.name) helps you \(useCase.benefit) in any app you like", accent: "any app",
                           accentStyle: .italic, size: 33, color: Palette.ink, tracking: -1.9, lineHeight: 40.5)
                    .padding(.horizontal, 22)
                    .padding(.top, 10)
                AnyAppIllustration(useCase: useCase)
                    .frame(width: 345, height: 345)
                    .padding(.top, 102.7)
                Spacer(minLength: 0)
            }
        } actions: {
            Button("Next") { store.send(.next) }
                .buttonStyle(.pill(.ink))
        }
    }
}

/// Fades scrolling cards out above the bottom button.
struct BottomFade: View {
    var body: some View {
        LinearGradient(colors: [Palette.paper.opacity(0), Palette.paper], startPoint: .top, endPoint: .bottom)
            .frame(height: 28)
            .allowsHitTesting(false)
    }
}

extension UseCase {
    var title: String {
        switch self {
        case .messages: "I can’t keep up with my messages"
        case .emails: "Writing emails takes forever"
        case .chatWithAI: "I want to chat with AI faster"
        case .captureIdeas: "I struggle to capture ideas quickly"
        case .onTheGo: "I often have to work on-the-go"
        case .typeFaster: "I want to type faster on my phone"
        case .typingIsHard: "Typing is hard for me"
        }
    }

    var systemImage: String {
        switch self {
        case .messages: "message"
        case .emails: "envelope.open"
        case .chatWithAI: "wand.and.sparkles"
        case .captureIdeas: "lightbulb"
        case .onTheGo: "shoe"
        case .typeFaster: "keyboard.badge.ellipsis"
        case .typingIsHard: "hand.raised"
        }
    }

    /// "Murmur helps you <benefit> in any app you like".
    var benefit: String {
        switch self {
        case .messages: "answer messages faster"
        case .emails: "write emails faster"
        case .chatWithAI: "chat with AI faster"
        case .captureIdeas: "capture ideas faster"
        case .onTheGo: "write on the go"
        case .typeFaster: "type faster"
        case .typingIsHard: "write without typing"
        }
    }

    /// The app tile on the explainer's illustration.
    var appGlyph: String {
        switch self {
        case .messages: "message.fill"
        case .emails: "envelope.fill"
        case .chatWithAI: "sparkles"
        case .captureIdeas: "note.text"
        case .onTheGo: "figure.walk"
        case .typeFaster, .typingIsHard: "text.bubble.fill"
        }
    }
}
