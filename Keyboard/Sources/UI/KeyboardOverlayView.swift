import SwiftUI

/// The page under the toolbar while one is open, the ☰ menu or the styles. It takes the place of
/// the pad or the keys, which the controller hides, as Wispr Flow's menu does; the toolbar's ✕
/// closes it.
struct KeyboardOverlayView: View {
    let model: KeyboardModel

    var body: some View {
        ZStack(alignment: .top) {
            switch model.overlay {
            case .menu:
                KeyboardMenuPage(model: model)
                    .transition(.opacity)
            case .style:
                StylePage(model: model)
                    .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityAction(.escape, model.actions.hideOverlay)
    }
}
