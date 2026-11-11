import MurmurUI
import SwiftUI

/// "Contact support", "Report an issue" and "Leave feedback": a message to `issue_reports`, with
/// the app and iOS versions attached.
struct SupportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AccountService.SupportMessage.Kind
    @State private var topic = Self.topics[0]
    @State private var message = ""
    @State private var sending = false
    @State private var error: String?
    @State private var sent = false
    @FocusState private var focused: Bool

    static let topics = ["Dictation", "Keyboard", "Translation", "Account and plan", "Something else"]

    init(kind: AccountService.SupportMessage.Kind) {
        _kind = State(initialValue: kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Contact support", confirmTitle: "Send",
                        canConfirm: !(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending),
                        cancel: { dismiss() }, confirm: { Task { await send() } })
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Picker("Type", selection: $kind) {
                        ForEach(AccountService.SupportMessage.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if kind == .issue {
                        HStack {
                            Text("Request type")
                                .font(.murmur(.body))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 8)
                            Picker("Request type", selection: $topic) {
                                ForEach(Self.topics, id: \.self) { Text($0) }
                            }
                            .tint(Theme.second)
                        }
                        .frame(minHeight: 52)
                        .overlay(alignment: .top) { Hairline() }
                        .overlay(alignment: .bottom) { Hairline() }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(kind == .issue ? "Describe your issue…" : "What do you like, and what would you change?",
                                  text: $message,
                                  prompt: Text(kind == .issue ? "Describe your issue…" : "What do you like, and what would you change?")
                                      .foregroundStyle(Theme.third),
                                  axis: .vertical)
                            .lineLimit(6...12)
                            .font(.murmur(.body))
                            .foregroundStyle(Theme.ink)
                            .focused($focused)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(Theme.fill, in: .rect(cornerRadius: 16))
                        FieldError(message: error)
                        Text("Sent with your app and iOS versions, never your dictations.")
                            .font(.murmur(.footnote))
                            .foregroundStyle(Theme.third)
                    }
                    if sending {
                        ProgressView()
                            .tint(Theme.ink)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.canvas)
        .presentationBackground(Theme.canvas)
        .tint(Theme.ink)
        .onAppear { focused = true }
        .alert("Thanks — message sent", isPresented: $sent) {
            Button("OK") { dismiss() }
        } message: {
            Text("We read every message.")
        }
        .presentationDetents([.large])
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await model.accountService.send(.init(kind: kind, topic: kind == .issue ? topic : nil, message: message))
            sent = true
        } catch {
            self.error = "Couldn't send: \(error.localizedDescription)"
        }
    }
}
