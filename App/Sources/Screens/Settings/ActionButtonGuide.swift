import MurmurCore
import MurmurUI
import SwiftUI

/// Settings › Action Button shortcut, Wispr Flow's two pages: what it does, then how to set it up
/// (the Action Button, Control Center or Back Tap all run "Dictate with Murmur", `DictateIntent`).
struct ActionButtonGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showsSteps = false

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if showsSteps {
                steps
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                intro
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: showsSteps)
    }

    private var intro: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                closeButton
            }
            Spacer()
            SerifTitle("Set up your \(Brand.name) Action Button shortcut", accent: "Action Button",
                       accentStyle: .italic, size: 40, color: Palette.ink)
                .padding(.horizontal, 30)
            Text("Dictate with \(Brand.name) in a single press")
                .font(.ui(18))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 22)
                .padding(.horizontal, 30)
            Spacer()
            Button("Let's go") { showsSteps = true }
                .buttonStyle(.pill(.lavender))
                .padding(.horizontal, Metrics.authMargin)
                .padding(.bottom, 24)
        }
    }

    private var steps: some View {
        VStack(spacing: 0) {
            HStack {
                Button { showsSteps = false } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Back")
                Spacer()
                closeButton
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SerifTitle("Dictate without opening \(Brand.name)", accent: "without", accentStyle: .italic,
                               size: 32, color: Palette.ink, alignment: .leading)
                        .padding(.bottom, 26)
                    step(1, icon: "gearshape", "Open Settings, then Action Button.")
                    step(2, icon: "square.grid.2x2",
                         "Swipe to Controls, tap Choose a Control and pick Dictate with \(Brand.name). Or swipe to Shortcut and pick it there.")
                    step(3, icon: "keyboard",
                         "In any app, switch to the \(Brand.name) keyboard. Press the Action Button to start dictating, and again to type it out.")
                    Text("Without the keyboard on screen, the button opens \(Brand.name) on a new note and dictates into it.")
                        .font(.ui(15))
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Action Button?")
                            .font(.ui(17, .semibold))
                            .foregroundStyle(Palette.text)
                        Text("Add the Dictate control to Control Center: swipe down from the top right, tap +, then Add a Control and search for \(Brand.name). Or run it with a double tap on the back of your iPhone: Settings › Accessibility › Touch › Back Tap.")
                            .font(.ui(15))
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.canvas, in: .rect(cornerRadius: 18))
                    .padding(.top, 28)
                }
                .padding(.horizontal, 26)
                .padding(.top, 8)
            }
            VStack(spacing: 12) {
                Button("Try it in Notes") {
                    if let url = URL(string: "mobilenotes://") { openURL(url) }
                    dismiss()
                }
                .buttonStyle(.pill(.lavender))
                Button("Done") { dismiss() }
                    .buttonStyle(.pill(.outline))
            }
            .padding(.horizontal, Metrics.authMargin)
            .padding(.vertical, 16)
        }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Close")
        .padding(.trailing, 8)
    }

    private func step(_ number: Int, icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle().fill(Palette.lavender).frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Palette.ink)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Step \(number)")
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Text(text)
                    .font(.ui(17))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.bottom, 22)
    }
}
