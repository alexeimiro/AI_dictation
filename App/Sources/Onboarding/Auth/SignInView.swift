import MurmurCore
import MurmurUI
import SwiftUI

/// "Sign in to start": Google and Apple first, then "More options" for email.
struct SignInView: View {
    let expanded: Bool
    @Environment(AppModel.self) private var model
    @State private var busy: AuthMethod?
    @State private var error: String?

    var body: some View {
        let auth = model.onboardingServices.auth
        OnboardingPage(top: expanded ? .back({ model.onboarding.send(.back) }) : .wordmark) {
            Spacer(minLength: 24)
            OnboardingTitle(OnboardingCopy.SignIn.title, line: OnboardingCopy.SignIn.line, size: .statement)
        } actions: {
            VStack(spacing: 10) {
                // Provider marks other than Apple's need the providers' official assets; until
                // they're added, these buttons are text only.
                providerButton(.google, title: OnboardingCopy.SignIn.google, kind: .secondary) { EmptyView() }
                providerButton(.apple, title: OnboardingCopy.SignIn.apple, kind: .apple) {
                    Image(systemName: "apple.logo").font(.system(size: 19)).accessibilityHidden(true)
                }
                if expanded {
                    Button(OnboardingCopy.SignIn.email) { model.onboarding.send(.showEmailSignIn) }
                        .buttonStyle(.murmur(.secondary))
                        .disabled(busy != nil)
                }
            }
            if !expanded {
                Button(OnboardingCopy.SignIn.more) { model.onboarding.send(.showSignInOptions) }
                    .buttonStyle(.textOnly)
                    .padding(.top, 4)
            }
            FieldError(message: error)
                .padding(.top, 8)
            if !auth.isAvailable {
                Button(OnboardingCopy.SignIn.withoutAccount) { model.onboarding.send(.authenticated(.localOnly)) }
                    .buttonStyle(.textOnly)
            }
            LegalFootnote()
                .padding(.horizontal, 12)
                .padding(.top, 10)
        }
        .task {
            // A session from an earlier install (kept in the Keychain) skips this screen.
            if auth.hasAccount { model.onboarding.send(.authenticated(.existingSession)) }
        }
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
                model.onboarding.send(.authenticated(method))
            } catch {
                self.error = error.message
            }
        }
    }
}

/// "By continuing, you acknowledge…" with the Terms and Privacy links when they're configured.
struct LegalFootnote: View {
    var body: some View {
        Text(attributed)
            .font(.murmur(.footnote))
            .foregroundStyle(Theme.third)
            .multilineTextAlignment(.center)
            .tint(Theme.ink)
            .frame(maxWidth: .infinity)
    }

    private var attributed: AttributedString {
        var text = AttributedString(OnboardingCopy.SignIn.legalStart)
        text += link(OnboardingCopy.SignIn.terms, url: Brand.termsURL)
        text += AttributedString(OnboardingCopy.SignIn.legalJoin)
        text += link(OnboardingCopy.SignIn.privacy, url: Brand.privacyURL)
        text += AttributedString(".")
        return text
    }

    private func link(_ title: String, url: URL?) -> AttributedString {
        var part = AttributedString(title)
        part.underlineStyle = .single
        part.foregroundColor = Theme.ink
        part.link = url
        return part
    }
}
