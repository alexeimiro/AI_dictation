import SwiftUI

/// "You are logged out": the whole keyboard while nobody is signed in to Murmur, as the app last
/// said (`SharedSettings.signedOut`). Log in opens Murmur's sign-in. Like the rest of the keyboard
/// it sits on the system's own panel; on Face ID iPhones iOS draws the globe below it, and on the
/// others the view controller adds one in the corner.
struct SignedOutPage: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Text(verbatim: "❗ You are logged out")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.primary)
                Text("You must be logged in to use Murmur")
                    .font(.system(size: 15))
                    .foregroundStyle(KeyboardChrome.muted)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            // One element without the emoji, which VoiceOver would read out.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("You are logged out. You must be logged in to use Murmur.")
            .accessibilityAddTraits(.isHeader)
            Button(action: model.actions.logIn) {
                Text("Log in")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(KeyboardChrome.primaryGlyph)
                    .frame(width: 140, height: 44)
                    .background(KeyboardChrome.primary, in: Capsule(style: .circular))
                    .contentShape(Capsule(style: .circular))
            }
            .buttonStyle(.keyboardPress)
            .accessibilityHint("Opens Murmur to sign in")
            .padding(.top, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
