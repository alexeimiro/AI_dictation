import MurmurCore
import MurmurUI
import SwiftUI

/// References 06–07: "Start typing 4x faster with your voice", Google and Apple first, then
/// "More options" for email. Wispr Flow's Microsoft and SSO aren't offered.
struct SignInView: View {
    let expanded: Bool
    @Environment(AppModel.self) private var model
    @State private var busy: AuthMethod?
    @State private var error: String?

    var body: some View {
        let auth = model.onboardingServices.auth
        VStack(spacing: 0) {
            Wordmark(height: 35)
                .padding(.top, 33.3)
            SerifTitle("Start typing 4x faster with your voice", accent: "4x faster", size: 33,
                       color: Palette.ink, tracking: -0.85, lineHeight: 37)
                .padding(.horizontal, 60)
                .padding(.top, 165.6)
            VStack(spacing: 15) {
                // Provider marks other than Apple's need the providers' official assets; until
                // they're added, these buttons are text only.
                providerButton(.google, title: "Continue with Google", style: .outline) { EmptyView() }
                providerButton(.apple, title: "Continue with Apple", style: .ink) {
                    Image(systemName: "apple.logo").font(.system(size: 21)).accessibilityHidden(true)
                }
                if expanded {
                    Button("Continue with Email") { model.onboarding.send(.showEmailSignIn) }
                        .buttonStyle(.pill(.subtle))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, Metrics.authMargin)
            .padding(.top, 50.8)
            .animation(.smooth(duration: 0.35), value: expanded)
            if !expanded {
                Button("More options") { model.onboarding.send(.showSignInOptions) }
                    .buttonStyle(.quiet(size: 19, weight: .medium))
                    .padding(.top, 21.8)
            }
            if let error {
                Text(error)
                    .font(.ui(14))
                    .foregroundStyle(Palette.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 12)
            }
            if !auth.isAvailable {
                Button("Continue without an account") { model.onboarding.send(.authenticated(.localOnly)) }
                    .buttonStyle(.quiet(size: 16, weight: .medium))
                    .padding(.top, 8)
            }
            LegalFootnote()
                .padding(.horizontal, 46.5)
                .padding(.top, expanded ? 14 : 23.7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.paper)
        .overlay(alignment: .topLeading) {
            if expanded {
                CircleBackButton { model.onboarding.send(.back) }
                    .padding(.leading, 16)
                    .padding(.top, -1)
            }
        }
        .task {
            // A session from an earlier install (kept in the Keychain) skips this screen.
            if auth.hasAccount { model.onboarding.send(.authenticated(.existingSession)) }
        }
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
            .font(.ui(12))
            .foregroundStyle(Palette.fineprint)
            .multilineTextAlignment(.center)
            .lineSpacing(1.7)
            .tint(Palette.ink)
    }

    private var attributed: AttributedString {
        var text = AttributedString("By continuing, you acknowledge that you have read and agreed to our ")
        text += link("Terms of Service", url: Brand.termsURL)
        text += AttributedString(" and ")
        text += link("Privacy Policy", url: Brand.privacyURL)
        text += AttributedString(".")
        return text
    }

    private func link(_ title: String, url: URL?) -> AttributedString {
        var part = AttributedString(title)
        part.underlineStyle = .single
        part.foregroundColor = Palette.ink
        part.link = url
        return part
    }
}
