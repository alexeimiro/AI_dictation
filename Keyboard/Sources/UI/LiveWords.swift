import MurmurCore
import SwiftUI

/// The words of the dictation so far, while it listens: settled words in ink, the newest, which may
/// still change, in grey. Two lines; a longer text shows its end, with "…" before it. Empty until
/// the first word, at the same size, so nothing moves when it comes.
struct LiveWords: View {
    enum Place {
        /// Under the voice pad's talk button: large and centred.
        case pad
        /// Under the key layouts' listening caption: text-sized, from the edge the words start at.
        case panel

        var fontSize: CGFloat { self == .pad ? 22 : 16 }
        var lineHeight: CGFloat { self == .pad ? 28 : 21 }
        var sidePadding: CGFloat { self == .pad ? 24 : 20 }
        /// Two lines.
        static let lines = 2
        var height: CGFloat { lineHeight * CGFloat(Self.lines) }
    }

    let model: KeyboardModel
    var place: Place
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let preview = model.livePreview
        let text = preview?.text ?? ""
        let centred = place == .pad
        // The keyboard is laid out left to right whatever is spoken. Words written from the right
        // (Arabic, Hebrew) are laid out from the right all the same, and on the key layouts their
        // lines start at the right edge; from the left every word would slide sideways as the
        // next one came.
        let fromRight = LiveWordsScript.readsRightToLeft(text)
        // Thai stacks a tone mark over a vowel and hangs vowels under a letter, more than a line
        // of the system font holds: at full size the window's edge cuts the marks off its top row.
        // Smaller and a little lower, the tallest stack and the deepest vowel stay inside the line.
        let stacked = LiveWordsScript.stacksMarks(text)
        let font = Font.system(size: stacked ? place.fontSize * 0.8 : place.fontSize, weight: centred ? .semibold : .regular)
        let lowered = stacked ? place.lineHeight * 0.09 : 0
        // A two-line window on the whole text, which hangs from the window's bottom edge: one or
        // two lines sit at its top, a longer text shows its last two. The words are not measured;
        // only the mark reads where its line is.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: place.height)
            .overlay(alignment: .bottom) {
                Text("\(Text(verbatim: preview?.settled ?? "").foregroundStyle(KeyboardChrome.primary))\(Text(verbatim: preview?.unsettled ?? "").foregroundStyle(KeyboardChrome.unsettled))")
                    .baselineOffset(-lowered)
                    .font(font)
                    // Exact, so the window's edge falls between two lines' boxes whatever the
                    // script's own line height.
                    .lineHeight(.exact(points: place.lineHeight))
                    .multilineTextAlignment(centred ? .center : .leading)
                    // From the right whatever the preview happens to begin with: it is only the end
                    // of the dictation, and a name in Latin letters at its start would otherwise
                    // turn the whole paragraph round.
                    .writingDirection(strategy: fromRight ? .layoutBased : .default)
                    .frame(maxWidth: .infinity, minHeight: place.height, alignment: centred ? .top : .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, fromRight ? .rightToLeft : layoutDirection)
                    // Inside the window, so the mark has the padding to stand in.
                    .padding(.horizontal, place.sidePadding)
                    .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                        EarlierWordsMark(
                            layouts: layouts, mark: Text(verbatim: "…").font(font).foregroundStyle(KeyboardChrome.primary),
                            shownLines: Place.lines, lowered: lowered, fromRight: fromRight)
                    }
            }
            .clipped()
            .transaction { $0.animation = nil }
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Words so far")
            .accessibilityValue(text)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityHidden(preview?.isEmpty != false)
    }
}

/// "…" before the first line that shows, once the words run to more lines than the window holds:
/// earlier words are above it. It is drawn over the side padding, at the line's own baseline, so
/// no word moves when it appears.
private struct EarlierWordsMark: View {
    var layouts: Text.LayoutKey.Value
    var mark: Text
    var shownLines: Int
    /// How far the words sit under their baseline (Thai).
    var lowered: CGFloat
    /// The lines start at their right end.
    var fromRight: Bool

    var body: some View {
        GeometryReader { proxy in
            if let words = layouts.first, words.layout.count > shownLines {
                let origin = proxy[words.origin]
                let line = words.layout[words.layout.count - shownLines].typographicBounds
                // A Text, not a Canvas (see `EchoRingsView` for why not, in the keyboard). A frame
                // without size puts the mark's first baseline on the line's and its near edge at
                // the line's start.
                mark
                    .fixedSize()
                    .frame(width: 0, height: 0,
                           alignment: Alignment(horizontal: fromRight ? .leading : .trailing, vertical: .firstTextBaseline))
                    .offset(x: origin.x + (fromRight ? line.rect.maxX : line.rect.minX),
                            y: origin.y + line.origin.y + lowered)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
