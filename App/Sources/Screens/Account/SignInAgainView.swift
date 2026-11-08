import MurmurUI
import SwiftUI

/// "Sign in again": from Home's card, Settings or onboarding's offer page after the account was
/// signed out, or from Settings while a guest. Onboarding's sign-in look and services; it closes
/// once the account is signed in.
struct SignInAgainView: View {
    /// Where the sheet opens. Anything but `options` is for screenshot runs (`-account-sheet`).
    enum Start: String, Identifiable {
        case options
        case email
        /// Asking about "Continue without an account".
        case confirmGuest = "guest"

        var id: Self { self }
    }

    private enum Step: Hashable {
        case email
    }

    let start: Start
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step]
    @State private var busy: AuthMethod?
    @State private var error: String?
    @State private var confirmingGuest = false

    init(start: Start = .options) {
        self.start = start
        _path = State(initialValue: start == .email ? [.email] : [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            options
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Step.self) { _ in
                    EmailSignInView(onBack: { path.removeAll() }, onSignedIn: { dismiss() })
                        // Clear of the sheet's rounded top edge.
                        .safeAreaPadding(.top, 12)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        // As in onboarding: text scales up to XXXL, the accessibility sizes beyond it are capped.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onChange(of: model.account?.isSignedIn ?? false) { _, signedIn in
            // Also when the emailed link signs in, which arrives as a deep link.
            if signedIn { dismiss() }
        }
        .task {
            if start == .confirmGuest { confirmingGuest = true }
        }
    }

    private var options: some View {
        let account = model.account
        return ScrollView {
            VStack(spacing: 0) {
                Wordmark(height: 35)
                    .padding(.top, 33.3)
                SerifTitle("Sign in again", size: 33, color: Palette.ink, tracking: -0.85, lineHeight: 37)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 40)
                    .padding(.top, 52)
                Text(Self.subtitle(phrase: account?.phrase, guest: account?.isGuest == true))
                    .font(.ui(16))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 12)
                VStack(spacing: 15) {
                    providerButton(.google, title: "Continue with Google", style: .outline) { EmptyView() }
                    providerButton(.apple, title: "Continue with Apple", style: .ink) {
                        Image(systemName: "apple.logo").font(.system(size: 21))
                    }
                    Button("Continue with Email") { path.append(.email) }
                        .buttonStyle(.pill(.subtle))
                        .disabled(busy != nil)
                }
                .padding(.horizontal, Metrics.authMargin)
                .padding(.top, 40)
                if let error {
                    Text(error)
                        .font(.ui(14))
                        .foregroundStyle(Palette.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                        .padding(.top, 12)
                }
                if account?.isSignedOut == true {
                    Button("Continue without an account") { confirmingGuest = true }
                        .buttonStyle(.quiet(size: 16, weight: .medium))
                        .disabled(busy != nil)
                        // On the button: iOS 26 shows the dialog as a popover from where it's attached.
                        .confirmationDialog("Continue without an account?", isPresented: $confirmingGuest,
                                            titleVisibility: .visible) {
                            Button("Continue as a guest") {
                                model.continueAsGuest()
                                dismiss()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            // No word on which plan: a new guest's is whatever the server grants.
                            Text("Cloud dictation comes back now, as a guest without your account's plan. You can sign in again any time from Settings.")
                        }
                        .padding(.top, 14)
                }
                LegalFootnote()
                    .padding(.horizontal, 46.5)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.paper)
        .overlay(alignment: .topTrailing) {
            CloseButton { dismiss() }
                .padding(.trailing, 16)
                .padding(.top, 12)
        }
    }

    /// `phrase`: how the copy names the remembered account (`AccountModel.Account.phrase`).
    static func subtitle(phrase: String?, guest: Bool) -> String {
        let keep = guest ? "get your plan back" : "keep cloud dictation and your plan"
        guard let phrase else { return "Use the account you signed in with before to \(keep)." }
        return "You were signed in \(phrase). Use the same account to \(keep)."
    }

    private func providerButton(_ method: AuthMethod, title: String, style: PillButtonStyle.Variant,
                                @ViewBuilder icon: () -> some View) -> some View {
        let icon = icon()
        return Button {
            signIn(method)
        } label: {
            HStack(spacing: 13) {
                if busy == method {
                    ProgressView().tint(style == .ink ? .white : Palette.ink)
                } else {
                    icon
                }
                Text(title)
            }
        }
        .buttonStyle(.pill(style))
        .disabled(busy != nil)
    }

    /// As onboarding's `SignInView.signIn`; `SupabaseOnboardingAuth` has the account signed in by
    /// the time it returns.
    private func signIn(_ method: AuthMethod) {
        let auth = model.onboardingServices.auth
        busy = method
        error = nil
        Task {
            defer { busy = nil }
            do throws(OnboardingAuthError) {
                switch method {
                case .apple: try await auth.signInWithApple()
                case .google: try await auth.signInWithGoogle()
                default: return
                }
                dismiss()
            } catch {
                self.error = error.message
            }
        }
    }
}

/// `CircleBackButton`'s white circle, with a cross: closes the sheet.
private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .background(Palette.paper, in: .circle)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 2)
        }
        .accessibilityLabel("Close")
    }
}
