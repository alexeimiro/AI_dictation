import MurmurUI
import SwiftUI

/// Shown after the keyboard opens the app to start a session. Since iOS 26.4 there is no way to
/// return to the previous app programmatically, so we teach the swipe-back gesture.
struct SwipeBackView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var animate = false

    var body: some View {
        VStack(spacing: 0) {
            Wordmark(height: 30)
                .padding(.top, 36)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                    .padding(.trailing, 12)
                    .padding(.top, 26)
                }
            Spacer()
            content
                .padding(.horizontal, Metrics.screenMargin)
            Spacer()
            gestureHint
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        .onAppear { animate = true }
    }

    @ViewBuilder
    private var content: some View {
        switch model.session.phase {
        case .failed(let message):
            VStack(spacing: 24) {
                SerifTitle("Couldn't start Murmur", size: 38)
                Text(message)
                    .font(.ui(17))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await model.session.start() } }
                    .buttonStyle(.pill(.ink))
                Button("Close") { dismiss() }
                    .font(.ui(17, .medium))
                    .foregroundStyle(Palette.ink)
            }
        case .starting, .off:
            VStack(spacing: 20) {
                ProgressView().controlSize(.large)
                Text(model.session.startDetail ?? "Turning on the microphone…")
                    .font(.ui(17))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        default:
            VStack(spacing: 18) {
                SerifTitle("Murmur is on", accent: "on", size: 52)
                Text("Swipe right across the bottom edge to continue")
                    .font(.ui(19))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                Text("or tap ◀︎ in the top-left corner")
                    .font(.ui(15))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// A finger sliding along the home indicator.
    private var gestureHint: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Palette.ink.opacity(0.15))
                .frame(width: 140, height: 5)
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 30))
                .foregroundStyle(Palette.ink)
                .offset(x: animate ? 120 : -10, y: 14)
                .opacity(animate ? 0.2 : 1)
                .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false), value: animate)
        }
        .frame(width: 160, height: 60)
        .accessibilityHidden(true)
    }
}
