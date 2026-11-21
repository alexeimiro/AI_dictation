import MurmurCore
import SwiftUI

extension View {
    /// Lays out dictated text in its own direction. The app's layout is left to right (English
    /// UI), where Arabic, Hebrew, Persian or Urdu text would read right to left but hug the left
    /// edge; such text is aligned to the right, with its lines wrapped from there. Left-to-right
    /// text is left as it is. The direction comes from the text's first letter
    /// (`TextDirection.of`), as the Unicode rules decide a paragraph's.
    func dictatedTextDirection(_ text: String) -> some View {
        modifier(DictatedTextDirection(direction: TextDirection.of(text)))
    }
}

private struct DictatedTextDirection: ViewModifier {
    let direction: TextDirection

    func body(content: Content) -> some View {
        if direction == .rightToLeft {
            content
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .rightToLeft)
        } else {
            content
        }
    }
}
