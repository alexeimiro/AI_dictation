import SwiftUI

/// What opens over the keyboard under the toolbar: the style menu, the settings sheet or the
/// languages sheet, on a scrim that closes it. The toolbar stays above it, so its buttons can
/// close what they opened.
struct KeyboardOverlayView: View {
    let model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let overlay = model.overlay {
                    // A drawn fill: an extension gets no touches where it draws nothing.
                    KeyboardChrome.scrim
                        .contentShape(.rect)
                        .onTapGesture(perform: model.actions.hideOverlay)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    card(overlay, width: proxy.size.width)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .accessibilityAction(.escape, model.actions.hideOverlay)
    }

    @ViewBuilder
    private func card(_ overlay: KeyboardOverlay, width: CGFloat) -> some View {
        switch overlay {
        case .style:
            StyleMenuCard(model: model)
                .frame(width: min(340, width - 24))
                .padding(.top, 6)
                .padding(.leading, 12)
        case .settings:
            KeyboardSettingsPanel(model: model)
                .padding(.top, 6)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        case .languages:
            LanguageSelectorPanel(model: model)
                .padding(.top, 6)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }
}
