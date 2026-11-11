import SwiftUI

extension View {
    /// A soft grey card: the fill colour and 20 pt corners, with no border or shadow.
    public func softCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: .rect(cornerRadius: 20))
    }
}

extension Shape where Self == Capsule {
    /// Murmur's capsule: its ends are half circles. SwiftUI's own `.capsule` flattens them.
    public static var roundCapsule: Capsule { Capsule(style: .circular) }
}

/// A thin line in the line colour: between rows, between the menu's groups.
public struct Hairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A card's buttons: side by side when they fit, stacked when they don't (a narrow screen, large
/// type).
public struct ActionRow<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content }
            VStack(alignment: .leading, spacing: 10) { content }
        }
    }
}

/// A small label in a capsule: outlined for the plan chip, solid ink for "Pro" and "Save 33%".
public struct Chip: View {
    let text: String
    let isSolid: Bool

    public init(_ text: String, solid: Bool = false) {
        self.text = text
        self.isSolid = solid
    }

    public var body: some View {
        Text(verbatim: text)
            .font(.murmur(.caption, weight: isSolid ? .bold : .semibold))
            .foregroundStyle(isSolid ? Theme.onInk : Theme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, isSolid ? 3 : 2)
            .background(isSolid ? Theme.ink : .clear, in: .roundCapsule)
            .overlay {
                if !isSolid {
                    Capsule(style: .circular).strokeBorder(Theme.ink, lineWidth: 1.5)
                }
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

/// A step's number in an outlined circle.
public struct StepNumber: View {
    let number: Int
    /// The circle grows with the text size, so the number stays inside it.
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 24

    public init(_ number: Int) {
        self.number = number
    }

    public var body: some View {
        Text(verbatim: "\(number)")
            .font(.murmur(.footnote, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
            .frame(width: size, height: size)
            .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 1.5) }
            .accessibilityHidden(true)
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

/// Rings that leave a disc one after another, growing as they fade. Put it behind the disc: a ring
/// starts at the disc's own size. Under Reduce Motion, or when `isStill` (a screenshot), the rings
/// stand where a moment of the animation would have them.
public struct PulseRings: View {
    let color: Color
    let count: Int
    /// How many times the disc's size a ring has reached when it has faded out.
    let reach: CGFloat
    /// Seconds a ring takes; the rings leave evenly within it.
    let cycle: Double
    let lineWidth: CGFloat
    let isStill: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    public init(color: Color = Theme.live, count: Int = 3, reach: CGFloat = 2.2, cycle: Double = 2.1,
                lineWidth: CGFloat = 2, isStill: Bool = false) {
        self.color = color
        self.count = max(count, 1)
        self.reach = reach
        self.cycle = cycle
        self.lineWidth = lineWidth
        self.isStill = isStill
    }

    public var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                let ring = Circle().strokeBorder(color, lineWidth: lineWidth)
                if isStill || reduceMotion {
                    let progress = CGFloat(index + 1) / CGFloat(count + 1)
                    ring
                        .scaleEffect(1 + (reach - 1) * progress)
                        .opacity(0.7 * (1 - progress))
                } else {
                    ring
                        .scaleEffect(pulsing ? reach : 1)
                        .opacity(pulsing ? 0 : 0.7)
                        .animation(
                            .easeOut(duration: cycle).repeatForever(autoreverses: false)
                                .delay(cycle * Double(index) / Double(count)),
                            value: pulsing)
                }
            }
        }
        .onAppear { pulsing = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The red dot that says the microphone is open, with rings leaving it: one slow ring while
/// Murmur waits, two quicker ones while it listens. No rings under Reduce Motion.
public struct LiveDot: View {
    let size: CGFloat
    let rings: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(size: CGFloat = 12, rings: Int = 1) {
        self.size = size
        self.rings = max(rings, 1)
    }

    public var body: some View {
        Circle()
            .fill(Theme.live)
            .frame(width: size, height: size)
            .background {
                if !reduceMotion {
                    // One ring takes 1.8 s; two take 1.4 s each, half a cycle apart.
                    PulseRings(count: rings, reach: 2.8, cycle: rings == 1 ? 1.8 : 1.4, lineWidth: 1.5)
                }
            }
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
            ActionRow {
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
