import MurmurUI
import SwiftUI

/// "Sign in again": from Home's card, Settings or onboarding's offer page after the account was
/// signed out, or from Settings while a guest. Onboarding's sign-in services; it closes once the
/// account is signed in.
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
        .presentationBackground(Theme.canvas)
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
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Wordmark(height: 22)
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
                    .padding(.trailing, -12)
                }
                .frame(minHeight: 44)
                Text("Sign in again")
                    .font(.murmur(.title))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 36)
                Text(Self.subtitle(phrase: account?.phrase, guest: account?.isGuest == true))
                    .font(.murmur(.callout))
                    .foregroundStyle(Theme.second)
                    .padding(.top, 10)
                VStack(spacing: 10) {
                    providerButton(.google, title: "Continue with Google", kind: .secondary) { EmptyView() }
                    providerButton(.apple, title: "Continue with Apple", kind: .apple) {
                        Image(systemName: "apple.logo").font(.system(size: 19)).accessibilityHidden(true)
                    }
                    Button("Continue with Email") { path.append(.email) }
                        .buttonStyle(.murmur(.secondary))
                        .disabled(busy != nil)
                }
                .padding(.top, 28)
                FieldError(message: error)
                    .padding(.top, 12)
                if account?.isSignedOut == true {
                    Button { confirmingGuest = true } label: {
                        Text("Continue without an account")
                            .font(.murmur(.subhead, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
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
                    .padding(.top, 8)
                }
                LegalFootnote()
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.canvas)
    }

    /// `phrase`: how the copy names the remembered account (`AccountModel.Account.phrase`).
    static func subtitle(phrase: String?, guest: Bool) -> String {
        let keep = guest ? "get your plan back" : "keep cloud dictation and your plan"
        guard let phrase else { return "Use the account you signed in with before to \(keep)." }
        return "You were signed in \(phrase). Use the same account to \(keep)."
    }

    private func providerButton(_ method: AuthMethod, title: String, kind: MurmurButtonStyle.Kind,
                                @ViewBuilder icon: () -> some View) -> some View {
        let icon = icon()
        return Button {
            signIn(method)
        } label: {
            HStack(spacing: 10) {
                if busy == method {
                    // Every button is disabled, and so grey, while one of them is busy.
                    ProgressView().tint(Theme.ink)
                } else {
                    icon
                }
                Text(title)
            }
        }
        .buttonStyle(.murmur(kind))
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
