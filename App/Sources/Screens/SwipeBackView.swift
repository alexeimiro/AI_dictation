import MurmurUI
import SwiftUI

/// Shown after the keyboard opens the app to start a session. Murmur first tries to send the user
/// back by itself (`HostReturn`); iOS has no API for that, so when it can't, this teaches the
/// swipe-back gesture.
struct SwipeBackView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Only once the mic is on (recording can't start after leaving the app), and not while
        // Murmur is about to take the user back itself.
        let teachesSwipe = model.session.isLive && !model.hostReturn.isPending
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 8)
            Spacer()
            content
                .padding(.horizontal, 24)
            Spacer()
            if teachesSwipe {
                VStack(spacing: 10) {
                    Text("Swipe right along the bottom edge to go back to your app")
                        .font(.murmur(.callout, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(isListening
                         ? "Murmur is already listening, so you can start talking. Your words will appear in your app."
                         : "Keyboards can’t use the microphone, so Murmur keeps it on for your next dictations.")
                        .font(.murmur(.footnote))
                        .foregroundStyle(Theme.third)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 56)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) {
            if teachesSwipe {
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
            VStack(spacing: 12) {
                Text("Couldn’t start Murmur")
                    .font(.murmur(.title))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.murmur(.body))
                    .foregroundStyle(Theme.second)
                Button("Try again") { Task { await model.session.start() } }
                    .buttonStyle(.murmur(.primary))
                    .padding(.top, 12)
                Button { dismiss() } label: {
                    Text("Close")
                        .font(.murmur(.subhead, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .multilineTextAlignment(.center)
        case .starting, .off:
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.ink)
                Text(model.session.startDetail ?? "Turning on the microphone…")
                    .font(.murmur(.body))
                    .foregroundStyle(Theme.second)
                    .multilineTextAlignment(.center)
            }
        default:
            VStack(spacing: 0) {
                // The microphone is open: the one place red belongs.
                LiveDot(size: 28, rings: 2)
                    .padding(.bottom, 44)
                Text("Murmur is on")
                    .font(.murmur(.display))
                    .tracking(-0.8)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(AccessibilityID.screen("swipeBack"))
                if model.hostReturn.isPending {
                    Text("Taking you back to your app…")
                        .font(.murmur(.body))
                        .foregroundStyle(Theme.second)
                        .padding(.top, 10)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private var isListening: Bool {
        if case .recording = model.session.phase { true } else { false }
    }
}

/// An arrow sliding along the system home indicator, which is where the swipe has to start. No
/// bar of our own: one drawn above the real edge looks like the thing to swipe and does nothing.
/// The ◀︎ breadcrumb isn't mentioned either; iOS doesn't show it reliably when a keyboard opened
/// the app. The arrow rests under Reduce Motion.
private struct SwipeHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .offset(x: reduceMotion ? 0 : (animate ? 55 : -55))
            .opacity(!reduceMotion && animate ? 0 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.3).repeatForever(autoreverses: false), value: animate)
            .padding(.bottom, 22)
            .accessibilityHidden(true)
            .onAppear { animate = true }
    }
}
