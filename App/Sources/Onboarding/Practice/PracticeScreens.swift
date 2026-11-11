import MurmurUI
import SwiftUI

/// Before the last exercise: the talk button with a whisper's rings, which stay close.
struct WhisperIntroView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingPage {
            Spacer(minLength: 16)
            VStack(spacing: 44) {
                TalkButtonPicture(mode: .listening(reach: 1.35))
                Text(verbatim: OnboardingCopy.WhisperIntro.caption)
                    .font(.murmur(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.second)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 16)
            OnboardingTitle(OnboardingCopy.WhisperIntro.title, line: OnboardingCopy.WhisperIntro.line)
        } actions: {
            Button(OnboardingCopy.continue) { model.onboarding.send(.next) }
                .buttonStyle(.murmur(.primary))
        }
    }
}

/// After the exercises: a tick for each one done. Continue commits the practice section.
struct PracticeCompleteView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let record = model.onboarding.record
        // Every exercise can be skipped, so the page says only what happened.
        let anyDone = PracticeExercise.allCases.contains(where: record.isDone)
        OnboardingPage {
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(PracticeExercise.allCases, id: \.self) { exercise in
                    let done = record.isDone(exercise)
                    HStack(spacing: 12) {
                        CheckCircle(isOn: done)
                        Text(verbatim: exercise.doneTitle)
                            .font(.murmur(.body, weight: done ? .semibold : .regular))
                            .foregroundStyle(done ? Theme.ink : Theme.second)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(done ? OnboardingCopy.PracticeDone.done : OnboardingCopy.PracticeDone.skipped)
                }
            }
            Spacer(minLength: 24)
            OnboardingTitle(anyDone ? OnboardingCopy.PracticeDone.title : OnboardingCopy.PracticeDone.skippedTitle,
                            line: anyDone ? nil : OnboardingCopy.PracticeDone.skippedLine, size: .statement)
        } actions: {
            Button(OnboardingCopy.continue) { model.onboarding.send(.next) }
                .buttonStyle(.murmur(.primary))
        }
    }
}

extension PracticeExercise {
    /// What the user did in it, on the page after the exercises.
    var doneTitle: String {
        switch self {
        case .basic: OnboardingCopy.PracticeDone.spoke
        case .formatting: OnboardingCopy.PracticeDone.email
        case .whisper: OnboardingCopy.PracticeDone.whispered
        }
    }
}
