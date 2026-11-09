import SwiftUI

/// Delete, the voice keyboard's toolbar chip: one character on touch, repeating while held
/// (`KeyRepeater`); a swipe left takes the whole word.
struct DeleteKey: View {
    let model: KeyboardModel
    @State private var pressed = false
    @State private var swiped = false

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background { KeyboardSurface(shape: Circle(), pressed: pressed) }
            .contentShape(.circle)
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
