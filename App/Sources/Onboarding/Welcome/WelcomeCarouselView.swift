import MurmurCore
import MurmurUI
import SwiftUI

/// References 01–03: an autoplaying three-page carousel over moving gradients, ending in
/// "Get started". The artwork is original: mesh gradients and SwiftUI-drawn props.
struct WelcomeCarouselView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page: Int

    init(page: Int = 0) {
        _page = State(initialValue: page)
    }

    var body: some View {
        ZStack {
            TabView(selection: $page) {
                ForEach(WelcomePage.allCases) { item in
                    WelcomeBackdrop(page: item, animated: !reduceMotion)
                        .ignoresSafeArea()
                        .tag(item.rawValue)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // The props sit at fixed positions from the top of the screen, outside the layout, so
            // the title and button stay anchored to the bottom.
            // Decorative; at large text sizes the title needs the room.
            ZStack(alignment: .top) {
                ForEach(WelcomePage.allCases) { item in
                    WelcomeProp(page: item, animated: !reduceMotion)
                        .opacity(item.rawValue == page ? 1 : 0)
                }
            }
            .opacity(dynamicTypeSize > .xLarge ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Wordmark(height: 34, color: .white)
                    .padding(.top, 43)
                Text(WelcomePage(rawValue: page)?.headline ?? "")
                    .font(.serif(32))
                    .tracking(-1.1)
                    .foregroundStyle(Palette.cream)
                    .padding(.top, 10)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: page)
                Spacer(minLength: 0)
                // A non-breaking hyphen keeps "voice-first" together on the first line.
                SerifTitle("\(Brand.name) is a voice\u{2011}first keyboard", size: 52, color: Palette.cream,
                           tracking: -1.9, lineHeight: 57)
                    .padding(.horizontal, 18)
                PageDots(count: WelcomePage.allCases.count, current: page,
                         activeColor: .white, inactiveColor: .white.opacity(0.45))
                    .padding(.top, 21)
                    .padding(.bottom, 28)
                Button("Get started") { model.onboarding.send(.next) }
                    .buttonStyle(.pill(.cream))
                    .padding(.horizontal, 35)
                    .padding(.bottom, Metrics.buttonBottom - 34)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .task(id: page) {
            guard !reduceMotion, !model.launchOptions.isOnboardingScreenshot else { return }
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.6)) { page = (page + 1) % WelcomePage.allCases.count }
        }
    }
}

enum WelcomePage: Int, CaseIterable, Identifiable {
    case speed, languages, dictionary

    var id: Int { rawValue }

    var headline: String {
        switch self {
        case .speed: "4x faster than typing"
        case .languages: "Dozens of languages"
        case .dictionary: "Personal dictionary"
        }
    }

    /// Mesh colors, dark to light, per page.
    var palette: [Color] {
        switch self {
        case .speed:
            [Color(hex: 0x1E1E20), Color(hex: 0x5B5B5E), Color(hex: 0x9C9C9F), Color(hex: 0x3A3A3D)]
        case .languages:
            [Color(hex: 0x1B0F0A), Color(hex: 0x6E3B17), Color(hex: 0xE59A45), Color(hex: 0x3E6B70)]
        case .dictionary:
            [Color(hex: 0x231A14), Color(hex: 0x6B5646), Color(hex: 0xC9B8A4), Color(hex: 0x3B2A20)]
        }
    }
}

/// A slowly drifting mesh gradient with soft light streaks.
private struct WelcomeBackdrop: View {
    let page: WelcomePage
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { timeline in
            let t = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
            let c = page.palette
            let drift = Float(sin(t * 0.35)) * 0.08
            let sway = Float(cos(t * 0.27)) * 0.1
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + sway, 0], [1, 0],
                    [0, 0.45 + drift], [0.5 - sway, 0.5 + drift], [1, 0.55 - drift],
                    [0, 1], [0.5 + drift, 1], [1, 1],
                ],
                colors: [
                    c[0], c[1], c[0],
                    c[1], c[2], c[3],
                    c[0], c[3], c[0],
                ])
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.15), .clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
    }
}

/// The prop in the middle of each page.
private struct WelcomeProp: View {
    let page: WelcomePage
    let animated: Bool

    var body: some View {
        switch page {
        case .speed: SpeedProp(animated: animated)
        case .languages: LanguagesProp(animated: animated)
        case .dictionary: DictionaryProp()
        }
    }
}

/// "Typing 45 wpm", then the words of a dictation sweeping past on an arc.
private struct SpeedProp: View {
    let animated: Bool
    private let sentence = "so, how would you like to set up the file? Here are a few ideas to get started "

    var body: some View {
        VStack(spacing: 0) {
            Text("Typing")
                .font(.ui(17, .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 262.4)
            Text("45 wpm")
                .font(.serif(40))
                .foregroundStyle(.white)
                .padding(.top, -6.5)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { timeline in
                let t = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
                ArcText(text: sentence, phase: CGFloat(t.truncatingRemainder(dividingBy: 40)) / 40)
            }
            .frame(height: 60)
            .padding(.top, 104)
        }
    }
}

/// Text laid along a shallow arc, scrolling left.
private struct ArcText: View {
    let text: String
    let phase: CGFloat

    var body: some View {
        Canvas { context, size in
            let font = Font.ui(15, .medium)
            let glyphs = Array(text).map { character in
                context.resolve(Text(String(character)).font(font).foregroundStyle(.white.opacity(0.9)))
            }
            let advances = glyphs.map { $0.measure(in: CGSize(width: 100, height: 100)).width }
            let total = advances.reduce(0, +)
            var x = -phase * total
            // Two passes of the sentence so the loop never shows a gap.
            for index in 0..<(glyphs.count * 2) {
                let glyph = glyphs[index % glyphs.count]
                let advance = advances[index % glyphs.count]
                defer { x += advance }
                guard x > -advance, x < size.width + advance else { continue }
                let progress = (x + advance / 2) / size.width - 0.5
                let y = size.height * 0.5 - cos(progress * .pi * 0.8) * 20
                let slope = sin(progress * .pi * 0.8) * 20 * .pi * 0.8 / size.width
                var symbol = context
                symbol.translateBy(x: x + advance / 2, y: y)
                symbol.rotate(by: .radians(Double(atan(slope))))
                symbol.draw(glyph, at: .zero, anchor: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A message in another language with a voice pill under it.
private struct LanguagesProp: View {
    let animated: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            Text("Hé, as-tu eu l’occasion de\nregarder le moodboard ?")
                .font(.ui(14, .medium))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .padding(.horizontal, 21)
                .padding(.vertical, 15)
                .background(Palette.bubble, in: .rect(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).stroke(Palette.cream, lineWidth: 1.5) }
                .frame(maxWidth: .infinity, alignment: .leading)
            VoicePill(animated: animated, color: Palette.cream)
                .frame(width: 95, height: 48)
                .padding(.trailing, 22)
        }
        .padding(.leading, 51)
        .padding(.trailing, 36)
        .padding(.top, 450)
    }
}

/// An outlined capsule with a moving waveform.
struct VoicePill: View {
    let animated: Bool
    var color: Color = .white
    var filled = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animated)) { timeline in
            let t = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
            HStack(spacing: 2.2) {
                ForEach(0..<18, id: \.self) { index in
                    let wave = abs(sin(Double(index) * 0.9 + t * 5)) * 0.7 + 0.15
                    Capsule()
                        .fill(filled ? Palette.ink : color)
                        .frame(width: 1.6, height: 22 * wave * (index % 3 == 0 ? 0.55 : 1))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Capsule().fill(filled ? Palette.cream : .clear)
                Capsule().stroke(filled ? Palette.ink : color, lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Teal name pills: words Murmur learns to spell.
private struct DictionaryProp: View {
    private let names = ["Ananya", "Mateo", "CRM", "Okafor", "Lindqvist", "Hoang", "Priya"]

    var body: some View {
        VStack(spacing: 6.6) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.ui(13, .medium))
                    .foregroundStyle(.white)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, minHeight: 28.4, alignment: .leading)
                    .background(Palette.teal, in: .capsule)
                    .overlay { Capsule().stroke(.white, lineWidth: 1.5) }
            }
        }
        .padding(.horizontal, 79)
        .padding(.top, 345.2)
    }
}
