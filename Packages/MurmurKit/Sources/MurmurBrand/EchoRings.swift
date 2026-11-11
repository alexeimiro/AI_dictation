import SwiftUI

/// The echo rings: thin rings that swell from the talk button with each syllable, the outer ones
/// trailing the inner like an echo. Pure numbers, so the keyboard, the app and the tests share them.
public enum EchoRings {
    public struct Ring: Sendable, Equatable {
        /// The ring's diameter relative to the button's: 1 sits on the button's edge.
        public let scale: Double
        public let opacity: Double
    }

    public static let count = 3
    /// The outermost ring's diameter at full voice, relative to the button's.
    public static let maxScale = 1.85
    /// How many level samples (50 ms each) a ring trails the one inside it.
    public static let lag = 3

    /// The rings for a level history: newest last, each 0...1. Under Reduce Motion the rings keep
    /// their place and only their opacity follows the voice.
    public static func rings(levels: [Double], reduceMotion: Bool = false) -> [Ring] {
        (0..<count).map { index in
            let level = level(in: levels, trailingBy: index * lag)
            let reach = Double(index + 1) / Double(count)
            let swell = reduceMotion ? 0.6 : pow(level, 0.6)
            // Fades in just above the noise floor, so silence shows no rings.
            let presence = min(1, level / 0.08)
            return Ring(scale: 1 + (maxScale - 1) * reach * swell,
                        opacity: presence * (0.35 + 0.65 * level) * (1 - 0.28 * Double(index)))
        }
    }

    /// Two samples averaged, `offset` back from the newest; anything missing or not a number is 0.
    static func level(in levels: [Double], trailingBy offset: Int) -> Double {
        let newest = levels.count - 1 - offset
        let samples = [newest, newest - 1].map { index -> Double in
            guard levels.indices.contains(index), levels[index].isFinite else { return 0 }
            return min(max(levels[index], 0), 1)
        }
        return (samples[0] + samples[1]) / 2
    }
}

/// Draws the echo rings around a talk button `diameter` wide. It redraws when `levels` changes and
/// has no clock of its own. Under Reduce Motion the rings keep their place; under Increase
/// Contrast they are heavier and more solid.
public struct EchoRingsView: View {
    let levels: [Double]
    let diameter: CGFloat
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(levels: [Double], diameter: CGFloat, color: Color = Theme.live) {
        self.levels = levels
        self.diameter = diameter
        self.color = color
    }

    public var body: some View {
        let rings = EchoRings.rings(levels: levels, reduceMotion: reduceMotion)
        let lineWidth: CGFloat = contrast == .increased ? 3 : 2
        // Shapes, not a Canvas: where the appearance is overridden, as in the keyboard, a Canvas
        // draws a colour that follows the appearance in its light value.
        ZStack {
            ForEach(rings.indices, id: \.self) { index in
                Circle()
                    .stroke(color, lineWidth: lineWidth)
                    .frame(width: diameter * rings[index].scale, height: diameter * rings[index].scale)
                    .opacity(contrast == .increased ? min(1, rings[index].opacity * 1.5) : rings[index].opacity)
            }
        }
        .frame(width: diameter * EchoRings.maxScale + lineWidth, height: diameter * EchoRings.maxScale + lineWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
