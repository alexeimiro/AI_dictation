import MurmurUI
import SwiftUI

/// "Talk to Support", "Report an issue" and "Share feedback": a message to `issue_reports`,
/// with the app and iOS versions attached.
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
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(AccountService.SupportMessage.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if kind == .issue {
                    Section {
                        Picker("Request type", selection: $topic) {
                            ForEach(Self.topics, id: \.self) { Text($0) }
                        }
                    }
                }
                Section {
                    TextField(kind == .issue ? "Describe your issue…" : "What do you like, and what would you change?",
                              text: $message, axis: .vertical)
                        .lineLimit(6...12)
                        .focused($focused)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        FieldError(message: error)
                        Text("Sent with your app and iOS versions, never your dictations.")
                    }
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Spacer()
                            if sending { ProgressView() } else { Text("Send message").font(.ui(17, .medium)) }
                            Spacer()
                        }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Talk to Support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .alert("Thanks — message sent", isPresented: $sent) {
                Button("OK") { dismiss() }
            } message: {
                Text("We read every message.")
            }
        }
        .tint(Palette.ink)
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
