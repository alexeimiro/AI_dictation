import SwiftUI

/// Murmur for Mac's Signal look, as the approved mock draws it (2026-11-16): white canvas, ink
/// text, greys, one fill and one line colour, and red only while the microphone is open.
/// Light only for now (the user's choice), so these are fixed values rather than dynamic colours.
enum Mac {
    enum Palette {
        static let canvas = Color(hex: 0xFFFFFF)
        static let ink = Color(hex: 0x0D0D0D)
        /// Sidebar, search fields, intro cards, the selected row.
        static let fill = Color(hex: 0xF4F4F4)
        /// Dividers; the selected sidebar row.
        static let line = Color(hex: 0xE5E5E5)
        /// The window's outline and input borders.
        static let border = Color(hex: 0xD9D9D9)
        static let track = Color(hex: 0xD4D4D4)
        /// Secondary text.
        static let second = Color(hex: 0x5D5D5D)
        /// Captions, times, meta.
        static let third = Color(hex: 0x6B6B6B)
        static let unselected = Color(hex: 0x8F8F8F)
        /// Only while the microphone is open: on white, and on the black bar.
        static let live = Color(hex: 0xD92D20)
        static let liveOnDark = Color(hex: 0xFF5247)
        /// Heatmap steps, lightest to darkest.
        static let heat: [Color] = [0xEDEDED, 0xC9C9C9, 0x9A9A9A, 0x5D5D5D, 0x0D0D0D].map { Color(hex: $0) }
    }

    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 26, weight: .bold)
        static let noteTitle = SwiftUI.Font.system(size: 24, weight: .bold)
        static let dialogTitle = SwiftUI.Font.system(size: 18, weight: .bold)
        static let wordmark = SwiftUI.Font.system(size: 18, weight: .semibold)
        static let cardTitle = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 15)
        static let lede = SwiftUI.Font.system(size: 14)
        static let row = SwiftUI.Font.system(size: 14)
        static let label = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let small = SwiftUI.Font.system(size: 13)
        static let caption = SwiftUI.Font.system(size: 12)
        static let badge = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let stat = SwiftUI.Font.system(size: 24, weight: .bold).monospacedDigit()
        static let tile = SwiftUI.Font.system(size: 26, weight: .bold).monospacedDigit()
    }

    enum Metric {
        static let sidebarWidth: CGFloat = 240
        static let barHeight: CGFloat = 52
        static let pagePadding: CGFloat = 48
        static let contentMaxWidth: CGFloat = 760
        static let windowSize = CGSize(width: 1200, height: 780)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
