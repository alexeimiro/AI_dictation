import SwiftUI

/// A short confirmation at the bottom of the screen ("Copied"): white on an ink capsule.
public struct ToastModifier: ViewModifier {
    @Binding var message: String?
    let duration: Duration

    public func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(verbatim: message)
                    .font(.murmur(.subhead, weight: .semibold))
                    .foregroundStyle(Theme.onInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Theme.ink, in: .rect(cornerRadius: 22))
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
