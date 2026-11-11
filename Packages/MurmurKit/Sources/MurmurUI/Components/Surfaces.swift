import SwiftUI

extension View {
    /// A soft grey card: the fill colour and 20 pt corners, with no border or shadow.
    public func softCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: .rect(cornerRadius: 20))
    }
}

/// A small outlined label: the plan chip, a transcript count.
public struct Chip: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.murmur(.caption, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay {
                Capsule().strokeBorder(Theme.ink, lineWidth: 1.5)
            }
            .fixedSize()
    }
}

/// The marker on a row or card that can be chosen: the mark when it is, an empty ring when it isn't.
public struct SelectionMark: View {
    let isOn: Bool

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    public var body: some View {
        BrandMark(ring: isOn ? Theme.ink : Theme.graphic, dot: isOn ? Theme.ink : .clear)
            .frame(width: 24, height: 24)
    }
}

/// A row of segments, some filled: the trial's days, onboarding's steps.
public struct Meter: View {
    let total: Int
    let filled: Int
    let height: CGFloat

    public init(total: Int, filled: Int, height: CGFloat = 6) {
        self.total = max(total, 0)
        self.filled = min(max(filled, 0), max(total, 0))
        self.height = height
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < filled ? Theme.ink : Theme.track)
                    .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(filled) of \(total)")
    }
}

/// The red dot that says the microphone is open, with one slow ring around it. The ring rests
/// under Reduce Motion.
public struct LiveDot: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    public init(size: CGFloat = 12) {
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(Theme.live)
            .frame(width: size, height: size)
            .background {
                if !reduceMotion {
                    Circle()
                        .strokeBorder(Theme.live, lineWidth: 1.5)
                        .scaleEffect(pulsing ? 2.8 : 1)
                        .opacity(pulsing ? 0 : 0.7)
                        .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulsing)
                }
            }
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

/// A notice on a soft card: a title, a line under it and its actions. `isAlert` adds the warning
/// mark, in ink like the rest.
public struct NoticeCard<Actions: View>: View {
    let title: String
    let message: String?
    let isAlert: Bool
    let onDismiss: (() -> Void)?
    let actions: Actions

    public init(_ title: String, message: String? = nil, isAlert: Bool = false, onDismiss: (() -> Void)? = nil,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.isAlert = isAlert
        self.onDismiss = onDismiss
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isAlert {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.murmur(.callout, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: title)
                    .font(.murmur(.callout, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.trailing, onDismiss == nil ? 0 : 32)
            if let message {
                Text(verbatim: message)
                    .font(.murmur(.subhead))
                    .foregroundStyle(Theme.second)
            }
            HStack(spacing: 10) {
                actions
            }
            .padding(.top, 8)
        }
        .softCard()
        .overlay(alignment: .topTrailing) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.murmur(.subhead, weight: .semibold))
                        .foregroundStyle(Theme.second)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
    }
}

/// What a list shows when it has nothing: the mark, a title, a line and an optional action.
public struct EmptyState<Action: View>: View {
    let title: String
    let message: String
    let action: Action

    public init(_ title: String, message: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.message = message
        self.action = action()
    }

    public var body: some View {
        VStack(spacing: 10) {
            BrandMark(ring: Theme.graphic)
                .frame(width: 52, height: 52)
                .padding(.bottom, 6)
            Text(verbatim: title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(verbatim: message)
                .font(.murmur(.subhead))
                .foregroundStyle(Theme.second)
                .multilineTextAlignment(.center)
            action
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

extension EmptyState where Action == EmptyView {
    public init(_ title: String, message: String) {
        self.init(title, message: message) { EmptyView() }
    }
}
