import MurmurUI
import SwiftUI

/// The button at the top left of every root screen: opens the menu.
struct MenuButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.3)) { model.router.isMenuOpen = true }
        } label: {
            MenuGlyph()
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Menu")
        .accessibilityIdentifier(AccessibilityID.menuButton)
    }
}

/// A root screen's menu button in its top bar, drawn bare: no glass behind it.
struct MenuToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { MenuButton() }
            .sharedBackgroundVisibility(.hidden)
    }
}

/// One bare action at the top right of a screen.
struct BarActionItem: ToolbarContent {
    let systemImage: String
    let label: String
    /// For UI tests, when the label isn't a stable anchor.
    var id: String?
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            BarIconButton(systemImage: systemImage, label: label, action: action)
                .accessibilityIdentifier(id ?? "")
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

/// A bare icon button for a top bar: a 24 pt glyph in a 44 pt target. Pushed screens keep the
/// system's back button: replacing it switches off the swipe from the left edge.
struct BarIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel(label)
    }
}

/// A tip at the top of a list, with one action and ✕, which hides it for good (`dismissedKey` in
/// the app's defaults).
struct TipCard: View {
    let title: String
    let message: String
    let action: String
    let onAction: () -> Void
    @AppStorage private var dismissed: Bool

    init(title: String, message: String, action: String, dismissedKey: String, onAction: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.action = action
        self.onAction = onAction
        _dismissed = AppStorage(wrappedValue: false, dismissedKey)
    }

    var body: some View {
        if !dismissed {
            NoticeCard(title, message: message, onDismiss: { withAnimation { dismissed = true } }) {
                Button(action, action: onAction)
                    .buttonStyle(.murmur(.secondary, size: .compact))
            }
        }
    }
}

/// "Delete word" at the bottom of an editor: ink and bold with the bin, since red means the
/// microphone is open.
struct DeleteButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "trash")
                .font(.murmur(.body, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// What is wrong with a field, under it: ink and bold with a mark, not red.
struct FieldError: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.circle")
                .font(.murmur(.footnote, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
    }
}

/// A row that leads somewhere: its title, then › for a screen or ↗ for a page in Safari, with a
/// line above it.
struct LinkRow: View {
    let title: String
    var isExternal = false

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.murmur(.body))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Image(systemName: isExternal ? "arrow.up.right" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.third)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        .contentShape(.rect)
    }
}

/// An account's picture: its initial in an outlined circle, or a person when it has no name.
struct Avatar: View {
    let initial: Character?
    let size: CGFloat

    var body: some View {
        Group {
            if let initial {
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.4, weight: .semibold))
            } else {
                Image(systemName: "person")
                    .font(.system(size: size * 0.4, weight: .medium))
            }
        }
        .foregroundStyle(Theme.ink)
        .frame(width: size, height: size)
        .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 1.5) }
        .accessibilityHidden(true)
    }
}

/// How an account is named in the menu and on Account.
struct AccountIdentity {
    /// The part of the email before the @; "Your account" behind one of Apple's relay addresses;
    /// "Guest" when nobody is signed in.
    let name: String
    /// The email when it names the account, else whether someone is signed in.
    let detail: String
    /// The name's first letter, when the email names the account.
    let initial: Character?

    @MainActor
    init(_ account: AccountModel?) {
        let signedIn = account?.isSignedIn == true
        if signedIn, let email = account?.email, let local = email.split(separator: "@").first,
           !email.hasSuffix("privaterelay.appleid.com") {
            name = String(local)
            detail = email
            initial = local.first
        } else {
            name = signedIn ? "Your account" : "Guest"
            detail = signedIn ? "Signed in" : "Not signed in"
            initial = nil
        }
    }
}
