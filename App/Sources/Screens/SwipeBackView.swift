import MurmurUI
import SwiftUI

/// Shown after the keyboard opens the app to start a session. Since iOS 26.4 there is no way to
/// return to the previous app programmatically, so we teach the swipe-back gesture.
struct SwipeBackView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        .overlay(alignment: .bottom) {
            // Only once the mic is on: recording can't start after leaving the app.
            if model.session.isLive {
                SwipeHint()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
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
                Text("Swipe right along the bottom edge of the screen to go back to your app")
                    .font(.ui(19))
                    .foregroundStyle(Palette.text)
                    .multilineTextAlignment(.center)
                Text("Keyboards can't use the microphone, so Murmur keeps it on for your next dictations.")
                    .font(.ui(15))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// A finger sliding along the system home indicator, which is where the swipe has to start.
/// No bar of our own: one drawn above the real edge looks like the thing to swipe and does
/// nothing. The ◀︎ breadcrumb isn't mentioned either; iOS doesn't show it reliably when a
/// keyboard opened the app.
private struct SwipeHint: View {
    @State private var animate = false

    var body: some View {
        Image(systemName: "hand.point.down.fill")
            .font(.system(size: 30))
            .foregroundStyle(Palette.ink)
            .offset(x: animate ? 55 : -55)
            .opacity(animate ? 0 : 1)
            .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false), value: animate)
            .padding(.bottom, 12)
            .accessibilityHidden(true)
            .onAppear { animate = true }
    }
}
