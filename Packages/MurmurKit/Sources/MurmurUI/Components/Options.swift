import SwiftUI

/// The round marker for something that is ticked or done: ink with a white tick when it is, an
/// empty ring when it isn't.
public struct CheckCircle: View {
    let isOn: Bool
    /// Grows with the text beside it.
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    public init(isOn: Bool) {
        self.isOn = isOn
    }

    public var body: some View {
        ZStack {
            if isOn {
                Circle().fill(Theme.ink)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Theme.onInk)
            } else {
                Circle().strokeBorder(Theme.graphic, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// An answer in a list of answers: its title and a marker, in an outline that turns ink once it
/// is picked.
public struct OptionRow: View {
    public enum Marker: Sendable {
        /// Any number of the answers can be picked.
        case tick
        /// One of the answers.
        case mark
    }

    let title: String
    let isSelected: Bool
    let marker: Marker
    let action: () -> Void

    public init(_ title: String, isSelected: Bool, marker: Marker = .tick, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.marker = marker
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(verbatim: title)
                    .font(.murmur(.callout, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch marker {
                case .tick: CheckCircle(isOn: isSelected)
                case .mark: SelectionMark(isOn: isSelected)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 52)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Theme.ink : Theme.line, lineWidth: 1.5)
            }
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Which page of a few is showing: a short bar for the current one, dots for the others.
public struct PageDots: View {
    let count: Int
    let current: Int

    public init(count: Int, current: Int) {
        self.count = count
        self.current = current
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule(style: .circular)
                    .fill(index == current ? Theme.ink : Theme.graphic)
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
