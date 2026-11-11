import MurmurCore
import MurmurUI
import SwiftUI

/// One dictation in full: what was written, the recording, 👍/👎, the raw text, how long each step
/// took, and the retry / insert actions.
struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var toast: String?
    @State private var busy = false
    @State private var showsRaw = false

    var body: some View {
        let _ = model.history.revision
        Group {
            if let transcript = model.history.snapshot(id) {
                content(transcript)
            } else {
                EmptyState("Transcript deleted", message: "It is no longer on this iPhone.")
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .toast($toast)
    }

    private func content(_ transcript: Transcript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The chips drop under the date when the line is too narrow for both.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        date(transcript)
                        chips(transcript)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        date(transcript)
                        HStack(spacing: 8) { chips(transcript) }
                    }
                }

                Text(verbatim: transcript.displayText.isEmpty ? (transcript.errorReason ?? "Nothing was recognized.") : transcript.displayText)
                    .accessibilityIdentifier(AccessibilityID.screen("transcript"))
                    .font(.transcript(.title3))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
                if let reason = transcript.errorReason, !transcript.displayText.isEmpty {
                    FieldError(message: reason)
                        .padding(.top, 10)
                }

                if let recording = model.history.recordings.url(for: transcript.id) {
                    RecordingPlayerRow(url: recording)
                        .padding(.top, 20)
                }

                if model.account != nil, transcript.status != .processing {
                    TranscriptFeedbackRow(transcript: transcript, toast: $toast)
                        .padding(.top, 18)
                }

                if transcript.cleanedText != nil, !transcript.rawText.isEmpty {
                    raw(transcript.rawText)
                        .padding(.top, 10)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading,
                          spacing: 14) {
                    stat("Duration", TranscriptRow.spoken(transcript.metrics.audioSeconds))
                    stat("Words", "\(transcript.metrics.words)")
                    stat("Words / min", "\(transcript.metrics.wpm)")
                    stat("Recognition", transcript.metrics.asrMs.map { "\($0) ms" } ?? "—")
                    stat("Cleanup", transcript.metrics.cleanupMs.map { "\($0) ms" } ?? "—")
                    stat("Total", transcript.metrics.totalMs.map { "\($0) ms" } ?? "—")
                    stat("Model", transcript.cleanupModel ?? "—")
                    stat("Style", transcript.style.title)
                }
                .padding(.top, 18)

                VStack(spacing: 10) {
                    Button { copy(transcript) } label: { Text("Copy") }
                        .buttonStyle(.murmur(.primary))
                        .disabled(transcript.displayText.isEmpty)
                    if transcript.canRegenerate {
                        Button {
                            regenerate(transcript)
                        } label: {
                            HStack(spacing: 10) {
                                if busy { ProgressView().tint(Theme.ink) }
                                Text(transcript.status == .cleaned ? "Regenerate" : "Retry cleanup")
                            }
                        }
                        .buttonStyle(.murmur(.secondary))
                        .disabled(busy)
                    }
                    if transcript.isInsertable {
                        Button { insertViaKeyboard(transcript) } label: { Text("Insert via keyboard") }
                            .buttonStyle(.murmur(.secondary))
                    }
                    // Ink, not red: red means the microphone is open.
                    Button {
                        model.history.delete(transcript.id)
                        dismiss()
                    } label: {
                        Text("Delete")
                            .font(.murmur(.subhead, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
    }

    private func date(_ transcript: Transcript) -> some View {
        Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.murmur(.footnote))
            .monospacedDigit()
            .foregroundStyle(Theme.third)
    }

    @ViewBuilder
    private func chips(_ transcript: Transcript) -> some View {
        if let language = transcript.language {
            StatusBadge(DictationLanguage(tag: language).localizedName, tone: .neutral)
        }
        StatusBadge(statusTitle(transcript.status), tone: statusTone(transcript.status))
    }

    /// "Raw transcript": a row that opens to show what was heard before the cleanup.
    private func raw(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { showsRaw.toggle() }
            } label: {
                HStack {
                    Text("Raw transcript")
                        .font(.murmur(.body))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.third)
                        .rotationEffect(.degrees(showsRaw ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 52)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsRaw ? "Open" : "Closed")
            if showsRaw {
                Text(verbatim: text)
                    .font(.transcript(.subheadline))
                    .foregroundStyle(Theme.second)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.murmur(.caption))
                .foregroundStyle(Theme.third)
            Text(verbatim: value)
                .font(.murmur(.subhead, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
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
        toast = "Copied"
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
            : "Couldn’t hand this to the keyboard"
    }
}
