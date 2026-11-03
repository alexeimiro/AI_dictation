import SwiftUI

/// Back chevron, progress segments and an optional Skip (survey, setup and practice steps).
/// Each segment fills from 0 to 1, so a phase can show partial progress.
public struct SegmentedProgressHeader: View {
    let fills: [Double]
    let onBack: (() -> Void)?
    let onSkip: (() -> Void)?

    public init(fills: [Double], onBack: (() -> Void)? = nil, onSkip: (() -> Void)? = nil) {
        self.fills = fills
        self.onBack = onBack
        self.onSkip = onSkip
    }

    public init(segments: Int, filled: Int, onBack: (() -> Void)? = nil) {
        self.init(fills: (0..<segments).map { $0 < filled ? 1 : 0 }, onBack: onBack)
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button {
                onBack?()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22.5, weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 35, height: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Back")
            .opacity(onBack == nil ? 0 : 1)
            .disabled(onBack == nil)

            HStack(spacing: 16) {
                ForEach(fills.indices, id: \.self) { index in
                    ProgressSegment(fill: fills[index])
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(Int((fills.reduce(0, +) / Double(max(fills.count, 1)) * 100).rounded())) percent")

            if let onSkip {
                Button("Skip", action: onSkip)
                    .font(.ui(17))
                    .foregroundStyle(Palette.muted)
                    .padding(.leading, 25)
                    .frame(height: 44)
                    .contentShape(.rect)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, onSkip == nil ? 24 : 25)
        .frame(height: 44)
    }
}

private struct ProgressSegment: View {
    let fill: Double

    var body: some View {
        Capsule()
            .fill(Palette.progressOff)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Palette.ink)
                        .frame(width: proxy.size.width * min(max(fill, 0), 1))
                }
            }
            .frame(height: 4)
            .animation(.easeInOut(duration: 0.45), value: fill)
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
                .font(.system(size: 22, weight: .medium))
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

/// Selectable survey row: an optional icon, a label and an optional second line, in a rounded card.
public struct OptionCard: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let isSelected: Bool
    let height: CGFloat
    let action: () -> Void

    public init(_ title: String, subtitle: String? = nil, systemImage: String? = nil, isSelected: Bool,
                height: CGFloat = Metrics.cardHeight, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.height = height
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 19))
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.ui(subtitle == nil ? 17 : 19, subtitle == nil ? .regular : .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.ui(17))
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, systemImage == nil ? 25 : 22)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(isSelected ? Palette.selectedFill : Palette.paper,
                        in: .rect(cornerRadius: Metrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardRadius)
                    .stroke(isSelected ? Palette.ink : Palette.cardBorder, lineWidth: Metrics.borderWidth)
            }
            .contentShape(.rect(cornerRadius: Metrics.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
