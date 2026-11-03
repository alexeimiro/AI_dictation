import Foundation

/// The onboarding state machine. Pure: the same record and event always give the same result,
/// and nothing here touches permissions, the network or storage. Returns nil when the event isn't
/// allowed on the current step (a disabled button, a gate that isn't met, or the finished state).
enum OnboardingReducer {
    static func reduce(_ record: OnboardingRecord, _ event: OnboardingEvent, now: Date) -> OnboardingRecord? {
        guard !record.isComplete else { return nil }
        var next = record
        let step = record.step

        switch event {
        case .next:
            guard let target = forward(from: record) else { return nil }
            if step == .practiceComplete { next.practiceCommittedAt = now }
            if target == .complete { next.completedAt = now }
            next.step = target

        case .back:
            guard let target = backward(from: step) else { return nil }
            next.step = target

        case .skipOptional:
            if step == .microphonePrimer {
                // Without a microphone the exercises can't run; the rest of setup still can.
                guard [.denied, .restricted].contains(record.permissions.microphone) else { return nil }
                next.step = .wrapUpIntro
            } else {
                guard let target = skipTarget(from: step) else { return nil }
                next.step = target
            }

        case .toggleUseCase(let useCase):
            guard step == .useCases else { return nil }
            if let index = next.answers.useCases.firstIndex(of: useCase) {
                next.answers.useCases.remove(at: index)
            } else {
                next.answers.useCases.append(useCase)
            }

        case .showSignInOptions:
            guard step == .signIn else { return nil }
            next.step = .signInOptions

        case .showEmailSignIn:
            guard step == .signInOptions else { return nil }
            next.step = .emailSignIn

        case .authenticated(let method):
            guard [.signIn, .signInOptions, .emailSignIn].contains(step) else { return nil }
            next.answers.authMethod = method
            next.step = .setupIntro

        case .keyboardStatusChanged(let added, let fullAccess):
            // Confirmed requirements stick: detection is best effort, and Full Access is only
            // visible once the keyboard has run.
            next.permissions.keyboardAdded = record.permissions.keyboardAdded || added
            next.permissions.fullAccessConfirmed = record.permissions.fullAccessConfirmed || fullAccess
            if step == .keyboardInstructions, !record.permissions.keyboardAdded, next.permissions.keyboardAdded {
                next.step = .practiceIntro
            }

        case .permissionChanged(let permission, let state):
            switch permission {
            case .microphone:
                next.permissions.microphone = state
                if step == .microphonePrimer, record.permissions.microphone != .granted, state == .granted {
                    next.step = .basicPractice
                }
            case .notifications:
                next.permissions.notifications = state
            }

        case .practiceCompleted(let exercise):
            guard step == exercise.step else { return nil }
            if !next.practiceDone.contains(exercise) { next.practiceDone.append(exercise) }

        case .selectDataChoice(let choice, let date):
            guard step == .dataChoice else { return nil }
            next.answers.dataChoice = DataChoiceDecision(
                choice: choice, policyVersion: DataChoiceDecision.currentPolicyVersion, decidedAt: date)

        case .setLanguages(let tags):
            guard step == .languages else { return nil }
            var seen: Set<String> = []
            next.answers.languages = tags.filter { seen.insert($0).inserted }

        case .selectStyle(let style):
            guard step == .defaultStyle else { return nil }
            next.answers.style = style

        case .desktopLinkRequested(let date):
            guard step == .desktopOffer else { return nil }
            next.answers.desktopLink = .requested(date)
            next.step = .referralSource

        case .desktopLinkDeclined:
            guard step == .desktopOffer else { return nil }
            next.answers.desktopLink = .declined
            next.step = .referralSource

        case .selectReferral(let source):
            guard step == .referralSource else { return nil }
            if next.answers.referralSource != source { next.answers.referralDetail = nil }
            next.answers.referralSource = source

        case .selectReferralDetail(let detail):
            guard step == .referralDetail,
                  record.answers.referralSource?.detailOptions?.contains(detail) == true else { return nil }
            next.answers.referralDetail = detail

        case .offerResolved(let offer):
            guard step == .ready || step == .trialOffer else { return nil }
            next.answers.offer = offer

        case .sessionLinkOpened:
            if let target = missingRequirement(for: record) { next.step = target }
        }
        return next
    }

    /// Where the primary action leads, or nil when its gate isn't met.
    static func forward(from record: OnboardingRecord) -> OnboardingStep? {
        let answers = record.answers
        let permissions = record.permissions
        switch record.step {
        case .welcome: return .useCases
        case .useCases: return answers.useCases.isEmpty ? nil : .personalizedExplainer
        case .personalizedExplainer: return .signIn
        case .signIn, .signInOptions, .emailSignIn: return nil
        case .setupIntro: return .keyboardInstructions
        case .keyboardInstructions: return permissions.keyboardAdded ? .practiceIntro : nil
        case .practiceIntro: return permissions.microphone == .granted ? .basicPractice : .microphonePrimer
        case .microphonePrimer: return permissions.microphone == .granted ? .basicPractice : nil
        case .basicPractice: return record.isDone(.basic) ? .formattingPractice : nil
        case .formattingPractice: return record.isDone(.formatting) ? .whisperIntro : nil
        case .whisperIntro: return .whisperPractice
        case .whisperPractice: return record.isDone(.whisper) ? .practiceComplete : nil
        case .practiceComplete: return .wrapUpIntro
        case .wrapUpIntro: return .dataChoice
        case .dataChoice: return answers.dataChoice == nil ? nil : .languages
        case .languages: return answers.languages.isEmpty ? nil : .defaultStyle
        case .defaultStyle: return answers.style == nil ? nil : .notifications
        case .notifications: return permissions.notifications.isDetermined ? .desktopOffer : nil
        case .desktopOffer: return nil
        case .referralSource:
            guard let source = answers.referralSource else { return nil }
            return source.detailOptions == nil ? .ready : .referralDetail
        case .referralDetail: return answers.referralDetail == nil ? nil : .ready
        case .ready: return .trialOffer
        case .trialOffer: return answers.offer == nil ? nil : .complete
        case .complete: return nil
        }
    }

    /// The back button's destination; nil on screens without one.
    static func backward(from step: OnboardingStep) -> OnboardingStep? {
        switch step {
        case .welcome, .setupIntro, .practiceIntro, .wrapUpIntro, .ready, .trialOffer, .complete: nil
        case .useCases: .welcome
        case .personalizedExplainer: .useCases
        case .signIn: .personalizedExplainer
        case .signInOptions: .signIn
        case .emailSignIn: .signInOptions
        case .keyboardInstructions: .setupIntro
        case .microphonePrimer, .basicPractice: .practiceIntro
        case .formattingPractice: .basicPractice
        case .whisperIntro: .formattingPractice
        case .whisperPractice: .whisperIntro
        case .practiceComplete: .whisperPractice
        case .dataChoice: .wrapUpIntro
        case .languages: .dataChoice
        case .defaultStyle: .languages
        case .notifications: .defaultStyle
        case .desktopOffer: .notifications
        case .referralSource: .desktopOffer
        case .referralDetail: .referralSource
        }
    }

    /// "Skip" on the exercises and the style screen, "Maybe later" on notifications.
    static func skipTarget(from step: OnboardingStep) -> OnboardingStep? {
        switch step {
        case .basicPractice: .formattingPractice
        case .formattingPractice: .whisperIntro
        case .whisperIntro, .whisperPractice: .practiceComplete
        case .defaultStyle: .notifications
        case .notifications: .desktopOffer
        default: nil
        }
    }

    /// A keyboard session link can't start dictation until the keyboard and microphone are set
    /// up, so it sends a signed-in user to whichever of those is missing.
    static func missingRequirement(for record: OnboardingRecord) -> OnboardingStep? {
        guard record.step.order >= OnboardingStep.setupIntro.order else { return nil }
        if !record.permissions.keyboardAdded { return .keyboardInstructions }
        if record.permissions.microphone != .granted { return .microphonePrimer }
        return nil
    }
}
