import SwiftUI

/// Delete, the voice keyboard's toolbar key: a bare glyph that fades while it is held. One
/// character on touch, repeating while held (`KeyRepeater`); a swipe left takes the whole word.
struct DeleteKey: View {
    let model: KeyboardModel
    var size: CGFloat = 46
    @State private var pressed = false
    @State private var swiped = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 20))
            .foregroundStyle(KeyboardChrome.primary)
            .opacity(pressed ? 0.5 : 1)
            .frame(width: size, height: size)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            pressed = true
                            model.actions.deleteDown()
                        }
                        if !swiped, value.translation.width < -28 {
                            swiped = true
                            model.actions.deleteWord()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        swiped = false
                        model.actions.deleteUp()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Delete")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                model.actions.deleteDown()
                model.actions.deleteUp()
            }
    }
}
