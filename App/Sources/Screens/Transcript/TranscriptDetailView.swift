import MurmurCore
import MurmurUI
import SwiftUI

/// "Transcript information": cleaned vs raw text, stats, and the retry / insert actions.
struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var toast: String?
    @State private var busy = false

    var body: some View {
        let _ = model.history.revision
        Group {
            if let transcript = model.history.snapshot(id) {
                content(transcript)
            } else {
                ContentUnavailableView("Transcript deleted", systemImage: "trash")
            }
        }
        .background(Palette.canvas)
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
    }

    private func content(_ transcript: Transcript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.ui(13))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    if let language = transcript.language {
                        StatusBadge(DictationLanguage(tag: language).localizedName, tone: .neutral)
                    }
                    StatusBadge(statusTitle(transcript.status), tone: statusTone(transcript.status))
                }

                card {
                    Text(verbatim: transcript.displayText.isEmpty ? (transcript.errorReason ?? "Nothing was recognized.") : transcript.displayText)
                        .font(.transcript())
                        .foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let reason = transcript.errorReason, !transcript.displayText.isEmpty {
                        Text(reason)
                            .font(.ui(13))
                            .foregroundStyle(Palette.danger)
                    }
                }

                if transcript.cleanedText != nil, !transcript.rawText.isEmpty {
                    DisclosureGroup("Raw transcript") {
                        Text(verbatim: transcript.rawText)
                            .font(.transcript(.subheadline))
                            .foregroundStyle(Palette.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.ui(15, .medium))
                    .foregroundStyle(Palette.text)
                    .padding(16)
                    .background(Palette.paper, in: .rect(cornerRadius: Metrics.cardRadius))
                }

                card {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        stat("Duration", TranscriptRow.duration(transcript.metrics.audioSeconds))
                        stat("Words", "\(transcript.metrics.words)")
                        stat("Words / min", "\(transcript.metrics.wpm)")
                        stat("Recognition", transcript.metrics.asrMs.map { "\($0) ms" } ?? "—")
                        stat("Cleanup", transcript.metrics.cleanupMs.map { "\($0) ms" } ?? "—")
                        stat("Total", transcript.metrics.totalMs.map { "\($0) ms" } ?? "—")
                        stat("Model", transcript.cleanupModel ?? "—")
                        stat("Style", transcript.style.title)
                    }
                }

                VStack(spacing: 12) {
                    Button { copy(transcript) } label: { Text("Copy") }
                        .buttonStyle(.pill(.ink))
                        .disabled(transcript.displayText.isEmpty)
                    if transcript.canRegenerate {
                        Button {
                            regenerate(transcript)
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Text(transcript.status == .cleaned ? "Regenerate" : "Retry cleanup")
                            }
                        }
                        .buttonStyle(.pill(.lavender))
                        .disabled(busy)
                    }
                    if transcript.isInsertable {
                        Button { insertViaKeyboard(transcript) } label: { Text("Insert via keyboard") }
                            .buttonStyle(.pill(.outline))
                    }
                    Button(role: .destructive) {
                        model.history.delete(transcript.id)
                        dismiss()
                    } label: {
                        Text("Delete")
                            .font(.ui(16, .medium))
                            .foregroundStyle(Palette.danger)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.paper, in: .rect(cornerRadius: Metrics.cardRadius))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.ui(12)).foregroundStyle(Palette.textSecondary)
            Text(verbatim: value).font(.ui(15, .medium)).foregroundStyle(Palette.text)
        }
    }

    private func statusTitle(_ status: TranscriptStatus) -> String {
        switch status {
        case .cleaned: "Cleaned"
        case .raw: "Not cleaned"
        case .failed: "Failed"
        case .empty: "Nothing heard"
        case .limitReached: "Limit reached"
        case .processing: "Processing"
        }
    }

    private func statusTone(_ status: TranscriptStatus) -> StatusBadge.Tone {
        switch status {
        case .cleaned: .success
        case .raw, .limitReached: .accent
        case .failed, .empty: .danger
        case .processing: .neutral
        }
    }

    private func copy(_ transcript: Transcript) {
        UIPasteboard.general.string = transcript.displayText
        toast = "Transcript copied to clipboard"
    }

    private func regenerate(_ transcript: Transcript) {
        busy = true
        Task {
            let error = await model.regenerate(transcript.id)
            busy = false
            toast = error ?? "Done"
        }
    }

    private func insertViaKeyboard(_ transcript: Transcript) {
        toast = model.insertViaKeyboard(transcript.id)
            ? "Switch to the Murmur keyboard and tap “Insert last dictation”"
            : "Couldn't hand this to the keyboard"
    }
}
