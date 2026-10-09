import SwiftUI

/// Back chevron followed by N progress segments (survey and setup steps).
public struct SegmentedProgressHeader: View {
    let segments: Int
    let filled: Int
    let onBack: (() -> Void)?

    public init(segments: Int, filled: Int, onBack: (() -> Void)? = nil) {
        self.segments = segments
        self.filled = filled
        self.onBack = onBack
    }

    public var body: some View {
        HStack(spacing: 16) {
            Button {
                onBack?()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 30, height: 44, alignment: .leading)
            }
            .accessibilityLabel("Back")
            .opacity(onBack == nil ? 0 : 1)
            .disabled(onBack == nil)

            HStack(spacing: 16) {
                ForEach(0..<segments, id: \.self) { index in
                    Capsule()
                        .fill(index < filled ? Palette.ink : Palette.progressOff)
                        .frame(height: 3.5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(filled) of \(segments)")
        }
        .padding(.horizontal, Metrics.screenMargin)
        .frame(height: 44)
    }
}

/// White circular back button with a soft shadow (auth screens).
public struct CircleBackButton: View {
    let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Palette.paper, in: .circle)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 2)
        }
        .accessibilityLabel("Back")
    }
}

/// Carousel page indicator; the current page is a wider pill.
public struct PageDots: View {
    let count: Int
    let current: Int
    var activeColor: Color
    var inactiveColor: Color

    public init(count: Int, current: Int, activeColor: Color = .white, inactiveColor: Color = .white.opacity(0.5)) {
        self.count = count
        self.current = current
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? activeColor : inactiveColor)
                    .frame(width: index == current ? 15 : 5, height: 5)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// Selectable survey row: icon + label in a rounded card.
public struct OptionCard: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 19))
                    .frame(width: 26)
                Text(title)
                    .font(.ui(17.5))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: Metrics.cardHeight)
            .background(isSelected ? Palette.selectedFill : Palette.paper,
                        in: .rect(cornerRadius: Metrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .strokeBorder(isSelected ? Palette.ink : Palette.cardBorder,
                                  lineWidth: isSelected ? 2 : Metrics.borderWidth)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
