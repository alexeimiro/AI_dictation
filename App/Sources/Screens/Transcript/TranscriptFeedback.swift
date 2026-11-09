import MurmurCore
import MurmurUI
import SwiftUI

/// The ratings given on this iPhone, so a transcript shows its 👍 or 👎 again. App-only defaults,
/// the newest few hundred kept.
@MainActor
enum TranscriptRatings {
    private static let key = "transcriptRatings"
    static let limit = 300

    static func rating(for id: UUID, defaults: UserDefaults = .standard) -> Int? {
        stored(defaults)[id.uuidString]?.rating
    }

    static func set(_ rating: Int, for id: UUID, now: Date = Date(), defaults: UserDefaults = .standard) {
        var all = stored(defaults)
        all[id.uuidString] = Entry(rating: rating, at: now)
        if all.count > limit {
            let oldest = all.sorted { $0.value.at < $1.value.at }.prefix(all.count - limit).map(\.key)
            oldest.forEach { all[$0] = nil }
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    private struct Entry: Codable {
        var rating: Int
        var at: Date
    }

    private static func stored(_ defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}

/// "How was this dictation?" with 👍 and 👎 (which asks what went wrong), as on Wispr Flow's
/// transcripts. Ratings go to the `feedback` table.
struct TranscriptFeedbackRow: View {
    let transcript: Transcript
    @Binding var toast: String?
    @Environment(AppModel.self) private var model
    @State private var rating: Int?
    @State private var explaining = false

    var body: some View {
        HStack(spacing: 10) {
            Text("How was this dictation?")
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.text)
            Spacer(minLength: 8)
            thumb(1, symbol: "hand.thumbsup", label: "Good")
            thumb(-1, symbol: "hand.thumbsdown", label: "Not good")
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(Palette.paper, in: .rect(cornerRadius: Metrics.cardRadius))
        .onAppear { rating = TranscriptRatings.rating(for: transcript.id) }
        .sheet(isPresented: $explaining) {
            FeedbackSheet(transcript: transcript) { sent in
                if sent {
                    rating = -1
                    toast = "Thanks, that helps us improve"
                }
            }
        }
    }

    private func thumb(_ value: Int, symbol: String, label: String) -> some View {
        let chosen = rating == value
        return Button {
            if value > 0 { send(value) } else { explaining = true }
        } label: {
            Image(systemName: chosen ? symbol + ".fill" : symbol)
                .font(.system(size: 19))
                .foregroundStyle(chosen ? Palette.tabSelectedLabel : Palette.textSecondary)
                .frame(width: 44, height: 44)
        }
        .disabled(rating != nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func send(_ value: Int) {
        rating = value
        Task {
            do {
                try await model.accountService.send(AccountService.DictationFeedback(
                    dictationId: transcript.id, rating: value, comment: nil, rawText: nil, cleanedText: nil))
                TranscriptRatings.set(value, for: transcript.id)
                toast = "Thanks for the feedback"
            } catch {
                rating = nil
                toast = error.localizedDescription
            }
        }
    }
}

/// 👎: what went wrong, a note, and, for someone sharing dictations, the text itself.
private struct FeedbackSheet: View {
    let transcript: Transcript
    let onDone: (Bool) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reasons: Set<Reason> = []
    @State private var note = ""
    @State private var includeText = true
    @State private var sending = false
    @State private var error: String?

    enum Reason: String, CaseIterable, Identifiable {
        case wrongWords = "Wrong words"
        case missedWords = "Missed words"
        case formatting = "Formatting"
        case language = "Wrong language"
        case slow = "Too slow"
        case other = "Something else"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What went wrong?") {
                    ForEach(Reason.allCases) { reason in
                        Button {
                            if reasons.contains(reason) { reasons.remove(reason) } else { reasons.insert(reason) }
                        } label: {
                            HStack {
                                Text(reason.rawValue).font(.ui(17)).foregroundStyle(Palette.text)
                                Spacer()
                                if reasons.contains(reason) {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.tabSelectedLabel)
                                }
                            }
                        }
                        .accessibilityAddTraits(reasons.contains(reason) ? .isSelected : [])
                    }
                }
                Section {
                    TextField("Tell us more (optional)", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.ui(17))
                }
                if model.dataSharing {
                    Section {
                        Toggle("Include this dictation's text", isOn: $includeText)
                            .tint(Palette.toggleGreen)
                    } footer: {
                        Text("You chose to help improve \(Brand.name), so we can look at what you said and what we wrote.")
                    }
                }
                if let error {
                    Section { FieldError(message: error) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .navigationTitle("Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDone(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .disabled(sending || (reasons.isEmpty && note.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        .presentationDetents([.large])
    }

    private func send() {
        sending = true
        error = nil
        let shareText = model.dataSharing && includeText
        let feedback = AccountService.DictationFeedback(
            dictationId: transcript.id, rating: -1,
            comment: Self.comment(reasons: reasons, note: note),
            rawText: shareText ? String(transcript.rawText.prefix(20_000)) : nil,
            cleanedText: shareText ? transcript.cleanedText.map { String($0.prefix(20_000)) } : nil)
        Task {
            do {
                try await model.accountService.send(feedback)
                TranscriptRatings.set(-1, for: transcript.id)
                onDone(true)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                sending = false
            }
        }
    }

    /// "Wrong words, Formatting: the names were spelled wrong", within the table's 2,000 characters.
    static func comment(reasons: Set<Reason>, note: String) -> String? {
        let picked = Reason.allCases.filter(reasons.contains).map(\.rawValue).joined(separator: ", ")
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = [picked, note].filter { !$0.isEmpty }.joined(separator: ": ")
        return comment.isEmpty ? nil : String(comment.prefix(2_000))
    }
}
