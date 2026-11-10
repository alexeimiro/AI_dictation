import MurmurUI
import SwiftUI

/// The hamburger at the top left of every tab: opens the side menu.
struct MenuButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { model.router.isMenuOpen = true }
        } label: {
            Image(systemName: "line.3.horizontal")
        }
        .accessibilityLabel("Menu")
    }
}

/// The cream card that introduces a tab, with a serif headline, a call to action and ✕, which
/// hides it for good (`dismissedKey` in the app's defaults).
struct IntroCard: View {
    let title: String
    var accent: String?
    let message: Text
    let action: String
    let dismissedKey: String
    let onAction: () -> Void
    @AppStorage private var dismissed: Bool

    init(title: String, accent: String? = nil, message: Text, action: String, dismissedKey: String,
         onAction: @escaping () -> Void) {
        self.title = title
        self.accent = accent
        self.message = message
        self.action = action
        self.dismissedKey = dismissedKey
        self.onAction = onAction
        _dismissed = AppStorage(wrappedValue: false, dismissedKey)
    }

    var body: some View {
        if !dismissed {
            VStack(spacing: 14) {
                SerifTitle(title, accent: accent, accentStyle: .italic, size: 30, color: Palette.ink, tracking: -0.3)
                message
                    .font(.ui(16))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button(action, action: onAction)
                    .buttonStyle(.pill(.ink, height: 50))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .background(Palette.cream, in: .rect(cornerRadius: 24))
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 44, height: 44)
                        // Without it only the glyph, about 11 pt, takes the tap.
                        .contentShape(Rectangle())
                }
                // Inside a List row, so only the ✕ itself, not the whole card, closes it.
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
        }
    }
}

/// The round + in the bottom-right corner of a list.
struct AddButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Palette.ink, in: .circle)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .accessibilityLabel(label)
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }
}

/// "Your words (3)" above a tab's list.
struct CountHeader: View {
    let title: String
    let count: Int

    var body: some View {
        Text("\(title) (\(count))")
            .font(.ui(15, .medium, relativeTo: .subheadline))
            .foregroundStyle(Palette.textSecondary)
            .textCase(nil)
    }
}

/// An empty list's message, centered with an icon.
struct EmptyTabMessage: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(Palette.lockGray)
            Text(title)
                .font(.ui(17, .medium))
                .foregroundStyle(Palette.text)
            Text(detail)
                .font(.ui(14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// An editor sheet's red message under the fields.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.ui(14))
                .foregroundStyle(Palette.danger)
        }
    }
}
