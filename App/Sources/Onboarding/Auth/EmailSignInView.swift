import MurmurUI
import SwiftUI

/// "Continue with your email", then a six-digit code from the email (or its link, handled by the
/// `murmur://auth-callback` deep link).
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
        OnboardingPage(top: .back(goBack)) {
            OnboardingTitle(sentTo == nil ? OnboardingCopy.Email.title : OnboardingCopy.Email.sentTitle,
                            line: sentTo.map(OnboardingCopy.Email.sentLine(to:)))
                .padding(.top, 14)
            field
                .padding(.top, 24)
            FieldError(message: error)
                .padding(.top, 10)
            Button {
                submit()
            } label: {
                // Disabled, and so grey, while it is busy.
                if busy { ProgressView().tint(Theme.ink) } else { Text(OnboardingCopy.continue) }
            }
            .buttonStyle(.murmur(.primary))
            .disabled(!canSubmit || busy)
            .padding(.top, 24)
            if sentTo != nil {
                Button(OnboardingCopy.Email.resend) { resend() }
                    .buttonStyle(.textOnly)
                    .disabled(busy)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .onAppear { focused = true }
        .onChange(of: sentTo) { focused = true }
    }

    /// From the code step, back to the address; from the address, out of this page.
    private func goBack() {
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

    @ViewBuilder
    private var field: some View {
        Group {
            if sentTo == nil {
                TextField("", text: $email,
                          prompt: Text(OnboardingCopy.Email.addressPrompt).foregroundStyle(Theme.third))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
            } else {
                TextField("", text: $code,
                          prompt: Text(OnboardingCopy.Email.codePrompt).foregroundStyle(Theme.third))
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .onChange(of: code) { _, newValue in
                        code = String(newValue.filter(\.isNumber).prefix(6))
                    }
            }
        }
        .font(.murmur(.body))
        .foregroundStyle(Theme.ink)
        .tint(Theme.ink)
        .focused($focused)
        .onSubmit(submit)
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(Theme.fill, in: .rect(cornerRadius: 16))
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
