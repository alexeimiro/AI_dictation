import MurmurUI
import SwiftUI

/// Reference 08: "Continue with your email", then a six-digit code from the email (or its link,
/// handled by the `murmur://auth-callback` deep link).
struct EmailSignInView: View {
    /// Back from the address step, and a finished sign-in. Nil is onboarding's: its back and
    /// `.authenticated(.email)` events.
    private let onBack: (() -> Void)?
    private let onSignedIn: (() -> Void)?
    @Environment(AppModel.self) private var model
    @State private var email = ""
    @State private var code = ""
    @State private var sentTo: String?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(onBack: (() -> Void)? = nil, onSignedIn: (() -> Void)? = nil) {
        self.onBack = onBack
        self.onSignedIn = onSignedIn
    }

    var body: some View {
        VStack(spacing: 0) {
            SerifTitle(sentTo == nil ? "Continue with your email" : "Check your email", size: 33,
                       color: Palette.ink, tracking: 0)
                .padding(.top, 73.3)
            if let sentTo {
                Text("Enter the 6-digit code we sent to \(sentTo), or open the link in that email on this iPhone.")
                    .font(.ui(16))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 10)
            }
            field
                .padding(.top, sentTo == nil ? 36 : 24)
            if let error {
                Text(error)
                    .font(.ui(14))
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
            Button {
                submit()
            } label: {
                if busy { ProgressView().tint(.white) } else { Text("Continue") }
            }
            .buttonStyle(.pill(.ink))
            .disabled(!canSubmit || busy)
            .padding(.top, error == nil ? 54 : 24)
            if sentTo != nil {
                Button("Send a new code") { resend() }
                    .buttonStyle(.quiet(size: 15, weight: .medium))
                    .padding(.top, 12)
                    .disabled(busy)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.authMargin)
        .background(Palette.paper)
        .overlay(alignment: .topLeading) {
            CircleBackButton {
                if sentTo != nil {
                    sentTo = nil
                    code = ""
                    error = nil
                } else if let onBack {
                    onBack()
                } else {
                    model.onboarding.send(.back)
                }
            }
            .padding(.leading, 16)
            .padding(.top, -1)
        }
        .onAppear { focused = true }
        .onChange(of: sentTo) { focused = true }
    }

    @ViewBuilder
    private var field: some View {
        Group {
            if sentTo == nil {
                TextField("", text: $email, prompt: Text("Email address").foregroundStyle(Color(hex: 0xBDBCC1)))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
            } else {
                TextField("", text: $code, prompt: Text("123456").foregroundStyle(Color(hex: 0xBDBCC1)))
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .onChange(of: code) { _, newValue in
                        code = String(newValue.filter(\.isNumber).prefix(6))
                    }
            }
        }
        .font(.ui(19))
        .foregroundStyle(Palette.text)
        .tint(Color(hex: 0x0A84FF))
        .focused($focused)
        .onSubmit(submit)
        .padding(.horizontal, 17)
        .frame(height: 54)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                .stroke(Palette.ink, lineWidth: Metrics.borderWidth)
        }
    }

    private var canSubmit: Bool {
        sentTo == nil ? Self.isValidEmail(email) : code.count == 6
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        if let sentTo { verify(sentTo) } else { send(email.trimmingCharacters(in: .whitespaces)) }
    }

    private func send(_ address: String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do throws(OnboardingAuthError) {
                try await model.onboardingServices.auth.sendEmailCode(to: address)
                sentTo = address
            } catch {
                self.error = error.message
            }
        }
    }

    private func resend() {
        guard let sentTo else { return }
        code = ""
        send(sentTo)
    }

    private func verify(_ address: String) {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do throws(OnboardingAuthError) {
                try await model.onboardingServices.auth.verifyEmailCode(code, email: address)
                if let onSignedIn { onSignedIn() } else { model.onboarding.send(.authenticated(.email)) }
            } catch {
                self.error = error.message
            }
        }
    }

    /// Something@domain.tld, without spaces; the server does the real check.
    static func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), let at = trimmed.firstIndex(of: "@") else { return false }
        let local = trimmed[..<at]
        let domain = trimmed[trimmed.index(after: at)...]
        guard !local.isEmpty, let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain[domain.index(after: dot)...].count >= 2 && !domain.contains("@")
    }
}
