import MurmurCore
import MurmurUI
import SwiftUI

/// Reference 26.
struct WhisperIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingPage(actionInset: Metrics.authMargin) {
            VStack(spacing: 0) {
                SerifTitle("You can even whisper with \(Brand.name).", accent: "whisper", accentStyle: .italic,
                           size: 33, color: Palette.ink, tracking: -0.2, lineHeight: 42.2)
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                WhisperIllustration()
                    .frame(width: 232, height: 401)
                    .padding(.top, 38.3)
                Spacer(minLength: 0)
            }
        } actions: {
            Button("Continue") { model.onboarding.send(.next) }
                .buttonStyle(.pill(.ink))
        }
    }
}

/// Reference 30: Continue commits the practice section.
struct PracticeCompleteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader()
            SerifTitle("Congrats! You’ve experienced the magic of \(Brand.name)", size: 46, color: Palette.ink,
                       tracking: -1.2, lineHeight: 58.7, trailing: Sparkles.image(size: 36), alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 55)
                .padding(.trailing, 0)
                .padding(.top, 66)
            StreakCard(days: 1)
                .padding(.horizontal, 45)
                .padding(.top, 64)
            Spacer(minLength: 0)
            Button("Continue") { model.onboarding.send(.next) }
                .buttonStyle(.pill(.ink, height: 53))
                .padding(.horizontal, Metrics.authMargin)
                .padding(.bottom, 10)
        }
        .background(Palette.paper)
    }
}

/// "1 Day Streak", with the first of five days ticked.
private struct StreakCard: View {
    let days: Int

    var body: some View {
        VStack(spacing: 0) {
            Text("\(days) Day Streak 🔥")
                .font(.serif(30))
                .foregroundStyle(Palette.ink)
                .padding(.top, 27)
            Text("Keep dictating for the next 5 days\nto make it a habit!")
                .font(.ui(16, .medium))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
                .padding(.top, 12)
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { day in
                    VStack(spacing: 8) {
                        Circle()
                            .fill(day <= days ? Palette.accent : Color(hex: 0xF4F2F4))
                            .frame(width: 32, height: 32)
                            .overlay {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(day <= days ? .white : Palette.accent.opacity(0.35))
                            }
                        Text("Day \(day)")
                            .font(.ui(13))
                            .foregroundStyle(day <= days ? Palette.ink : Palette.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.paper, in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Color(hex: 0xE6E5E9), lineWidth: 1.5) }
        .accessibilityElement(children: .combine)
    }
}
