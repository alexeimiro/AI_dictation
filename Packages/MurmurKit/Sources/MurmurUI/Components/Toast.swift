import SwiftUI

/// A short confirmation at the bottom of the screen ("Transcript copied to clipboard").
public struct ToastModifier: ViewModifier {
    @Binding var message: String?
    let duration: Duration

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(verbatim: message)
                    .font(.ui(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Palette.bubble, in: .capsule)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: duration)
                        guard !Task.isCancelled else { return }
                        self.message = nil
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    public func toast(_ message: Binding<String?>, duration: Duration = .seconds(2)) -> some View {
        modifier(ToastModifier(message: message, duration: duration))
    }
}
