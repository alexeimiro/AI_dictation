import MurmurCore
import MurmurUI
import SwiftUI

/// Settings › Action Button shortcut: what it does and how to set it up (the Action Button,
/// Control Center or Back Tap all run "Dictate with Murmur", `DictateIntent`).
struct ActionButtonGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
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
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ScreenTitle("Dictate with one press")
                    Text("Set the Action Button to start a dictation, without opening \(Brand.name).")
                        .font(.murmur(.callout))
                        .foregroundStyle(Theme.second)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    step(1, "Open Settings, then Action Button.")
                    step(2, "Swipe to Controls, tap Choose a Control and pick Dictate with \(Brand.name). Or swipe to Shortcut and pick it there.")
                    step(3, "Wherever you write, switch to the \(Brand.name) keyboard. Press the Action Button to start dictating, and again to type it out.")
                    Text("Without the keyboard on screen, the button opens \(Brand.name) on a new note and dictates into it.")
                        .font(.murmur(.subhead))
                        .foregroundStyle(Theme.second)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No Action Button?")
                            .font(.murmur(.callout, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Add the Dictate control to Control Center: swipe down from the top right, tap +, then Add a Control and search for \(Brand.name). Or run it with a double tap on the back of your iPhone: Settings › Accessibility › Touch › Back Tap.")
                            .font(.murmur(.subhead))
                            .foregroundStyle(Theme.second)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .softCard()
                    .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            VStack(spacing: 10) {
                Button("Try it in Notes") {
                    if let url = URL(string: "mobilenotes://") { openURL(url) }
                    dismiss()
                }
                .buttonStyle(.murmur(.primary))
                Button("Done") { dismiss() }
                    .buttonStyle(.murmur(.secondary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.canvas.ignoresSafeArea())
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            StepNumber(number)
            Text(text)
                .font(.murmur(.body))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(text)")
    }
}
