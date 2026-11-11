import MurmurUI
import SwiftUI

/// The journey in four parts, which the bar at the top of a page counts: what you want help with,
/// the keyboard, a try, and your choices.
enum OnboardingProgress {
    static let parts = 4

    /// The part a step belongs to; nil for the pages without the bar.
    static func part(for step: OnboardingStep) -> Int? {
        switch step {
        case .useCases, .personalizedExplainer: 1
        case .keyboardInstructions: 2
        case .microphonePrimer, .basicPractice, .formattingPractice, .whisperIntro, .whisperPractice,
             .practiceComplete: 3
        case .dataChoice, .languages, .defaultStyle, .notifications, .desktopOffer, .referralSource,
             .referralDetail: 4
        default: nil
        }
    }

    /// Skip sits in the bar on the exercises and the style page.
    static func showsSkip(_ step: OnboardingStep) -> Bool {
        [.basicPractice, .formattingPractice, .whisperIntro, .whisperPractice, .defaultStyle].contains(step)
    }
}

extension EnvironmentValues {
    /// The step a page was made for. A page that is sliding away keeps its own, while the store
    /// has already moved on to the next.
    @Entry var onboardingStep: OnboardingStep? = nil
}

/// What sits in the 44 pt row at the top of a page.
enum OnboardingTop {
    /// Back, the journey's four parts and Skip, for the step on screen.
    case progress
    case wordmark
    case back(() -> Void)
    case empty
}

/// A bare chevron in a 44 pt target, its glyph on the page's margin.
struct OnboardingBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(OnboardingCopy.back)
    }
}

/// Back, the journey's parts and Skip for the step on screen, wired to the store.
struct OnboardingHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.onboardingStep) private var pageStep

    var body: some View {
        let store = model.onboarding
        let step = pageStep ?? store.step
        if let part = OnboardingProgress.part(for: step) {
            let skips = OnboardingProgress.showsSkip(step)
            HStack(spacing: 8) {
                OnboardingBackButton { store.send(.back) }
                    .opacity(OnboardingReducer.backward(from: step) == nil ? 0 : 1)
                    .disabled(OnboardingReducer.backward(from: step) == nil)
                Meter(total: OnboardingProgress.parts, filled: part, height: 4)
                    .accessibilityLabel(OnboardingCopy.step(part, of: OnboardingProgress.parts))
                if skips {
                    Button(OnboardingCopy.skip) { store.send(.skipOptional) }
                        .buttonStyle(.textOnly)
                } else {
                    Color.clear.frame(width: 30, height: 1)
                }
            }
            // The chevron's glyph and Skip's last letter sit on the 24 pt margins.
            .padding(.leading, 10)
            .padding(.trailing, skips ? 12 : 24)
            .frame(height: 44)
        }
    }
}

/// A page of the journey: the top row, the content, and the buttons held at the bottom. The
/// content is a column from the leading margin; a `Spacer` in it takes the room that is left, and
/// when the text is too large to fit, the column scrolls under the buttons instead.
struct OnboardingPage<Content: View, Actions: View>: View {
    var top: OnboardingTop = .progress
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            topRow
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
            }
            // What scrolls fades out above the buttons. The column's last 16 pt are empty, so
            // nothing is faded while the page fits.
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [Theme.canvas.opacity(0), Theme.canvas], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                actions
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(Theme.canvas)
    }

    @ViewBuilder
    private var topRow: some View {
        switch top {
        case .progress:
            OnboardingHeader()
        case .wordmark:
            Wordmark(height: 22)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 24)
        case .back(let action):
            OnboardingBackButton(action: action)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
        case .empty:
            Color.clear.frame(height: 44)
        }
    }
}

extension OnboardingPage where Actions == EmptyView {
    init(top: OnboardingTop = .progress, @ViewBuilder content: () -> Content) {
        self.init(top: top, content: content) { EmptyView() }
    }
}

/// A page's title with the line under it. `.statement` is the larger pair on the pages that say
/// one thing (welcome, sign in, the plan).
struct OnboardingTitle: View {
    enum Size {
        case page, statement
    }

    let title: String
    let line: String?
    let size: Size

    init(_ title: String, line: String? = nil, size: Size = .page) {
        self.title = title
        self.line = line
        self.size = size
    }

    var body: some View {
        VStack(alignment: .leading, spacing: size == .page ? 8 : 10) {
            Text(verbatim: title)
                .font(.murmur(size == .page ? .title : .display))
                .tracking(size == .page ? -0.6 : -0.8)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let line {
                Text(verbatim: line)
                    .font(.murmur(size == .page ? .callout : .body))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.second)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The page that opens a part of the journey: the part's number, large, over the journey's bar,
/// then what comes next and one button.
struct IntroPage: View {
    let part: Int
    let title: String
    let line: String
    let button: String
    let action: () -> Void

    var body: some View {
        OnboardingPage(top: .empty) {
            Spacer(minLength: 24)
            BigNumber(number: "\(part)", caption: OnboardingCopy.step(part, of: OnboardingProgress.parts),
                      meter: (OnboardingProgress.parts, part))
            Spacer(minLength: 24)
            OnboardingTitle(title, line: line, size: .statement)
        } actions: {
            Button(button, action: action)
                .buttonStyle(.murmur(.primary))
        }
    }
}
