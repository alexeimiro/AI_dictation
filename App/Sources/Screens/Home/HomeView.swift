import MurmurCore
import MurmurUI
import SwiftData
import SwiftUI

/// Home: the session switch, the keyboard setup checklist until it's done, and the history by day.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse) private var records: [TranscriptRecord]
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                SessionCard()
                if !model.setup.isComplete, records.isEmpty {
                    SetupChecklistCard()
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))

            if records.isEmpty {
                Section {
                    emptyState
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(DayBucketing.group(records.map(\.snapshot))) { group in
                    Section {
                        ForEach(group.transcripts) { transcript in
                            row(transcript)
                        }
                    } header: {
                        Text(Self.title(for: group.day))
                            .font(.ui(13, .semibold, relativeTo: .footnote))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Wordmark(height: 22) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.router.open(.settings) } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .toast($toast)
        .task { model.history.reconcileInsertions(payloads: model.transport.payloads) }
        .refreshable {
            model.setup.refresh()
            model.history.reconcileInsertions(payloads: model.transport.payloads)
        }
    }

    private func row(_ transcript: Transcript) -> some View {
        let state = transcript.insertState(now: Date(), claimed: model.transport.payloads.isClaimed(transcript.id))
        return TranscriptRow(transcript: transcript, insertState: state)
            .contentShape(.rect)
            .onTapGesture { copy(transcript) }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { copy(transcript) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .tint(Palette.ink)
                if transcript.canRegenerate {
                    Button { regenerate(transcript) } label: {
                        Label(transcript.status == .cleaned ? "Regenerate" : "Retry", systemImage: "arrow.clockwise")
                    }
                    .tint(Palette.accent)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { model.history.delete(transcript.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button { model.router.open(.transcript(transcript.id)) } label: { Label("Details", systemImage: "info.circle") }
                Button { copy(transcript) } label: { Label("Copy", systemImage: "doc.on.doc") }
                if transcript.isInsertable {
                    Button { insertViaKeyboard(transcript) } label: { Label("Insert via keyboard", systemImage: "keyboard") }
                }
                if transcript.canRegenerate {
                    Button { regenerate(transcript) } label: {
                        Label(transcript.status == .cleaned ? "Regenerate" : "Retry", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) { model.history.delete(transcript.id) } label: { Label("Delete", systemImage: "trash") }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 28))
                .foregroundStyle(Palette.lockGray)
            Text("No dictations yet")
                .font(.ui(17, .medium))
                .foregroundStyle(Palette.text)
            Text("Open Notes, switch to the Murmur keyboard and tap the mic.")
                .font(.ui(14))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: Actions

    private func copy(_ transcript: Transcript) {
        guard !transcript.displayText.isEmpty else { return }
        UIPasteboard.general.string = transcript.displayText
        toast = "Transcript copied to clipboard"
    }

    private func regenerate(_ transcript: Transcript) {
        Task {
            if let error = await model.regenerate(transcript.id) {
                toast = error
            } else {
                toast = transcript.status == .cleaned ? "Regenerated" : "Cleaned up"
            }
        }
    }

    private func insertViaKeyboard(_ transcript: Transcript) {
        toast = model.insertViaKeyboard(transcript.id)
            ? "Switch to the Murmur keyboard and tap “Insert last dictation”"
            : "Couldn't hand this to the keyboard"
    }

    static func title(for day: Date, now: Date = Date()) -> String {
        switch DayBucketing.relativeDay(for: day, now: now) {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .other: day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
    }
}

/// The session switch with its status, start progress and failure message.
struct SessionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusText)
                    .font(.ui(17, .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                if model.session.phase == .starting {
                    ProgressView()
                }
                Toggle("Murmur is on", isOn: Binding(
                    get: { model.session.isLive },
                    set: { isOn in
                        if isOn { Task { await model.session.start() } } else { model.session.stop() }
                    }))
                .labelsHidden()
                .tint(Palette.toggleGreen)
            }
            if let detail = model.session.startDetail {
                Text(detail)
                    .font(.ui(13))
                    .foregroundStyle(Palette.textSecondary)
            }
            if case .failed(let message) = model.session.phase {
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(Palette.danger)
                Button("Try again") { Task { await model.session.start() } }
                    .font(.ui(15, .medium))
                    .foregroundStyle(Palette.ink)
            }
            if model.session.phase == .needsReconnect {
                Button("Reconnect") { model.session.appDidBecomeActive() }
                    .font(.ui(15, .medium))
                    .foregroundStyle(Palette.ink)
            }
        }
        .padding(16)
        .background(Palette.paper, in: .rect(cornerRadius: Metrics.cardRadius))
    }

    private var statusText: String {
        switch model.session.phase {
        case .off: "Murmur is off"
        case .starting: "Turning on…"
        case .ready: "Murmur is on"
        case .recording: "Listening"
        case .processing: "Cleaning up"
        case .needsReconnect: "Needs reconnect"
        case .failed: "Couldn't start"
        }
    }

    private var statusColor: Color {
        switch model.session.phase {
        case .ready: Palette.toggleGreen
        case .recording: .red
        case .processing, .starting: Palette.accent
        case .failed, .needsReconnect: Palette.danger
        case .off: Palette.lockGray
        }
    }
}

/// Keyboard setup steps; hidden once setup is complete or the first dictation arrived.
struct SetupChecklistCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up the keyboard")
                .font(.ui(15, .semibold))
                .foregroundStyle(Palette.text)
            checkRow("Keyboard added", ok: model.setup.keyboardAdded)
            checkRow("Allow Full Access", ok: model.setup.fullAccessConfirmed)
            checkRow("Microphone", ok: model.setup.microphone == .granted)
            HStack {
                if model.setup.microphone == .undetermined {
                    Button("Allow microphone") { Task { await model.setup.requestMicrophone() } }
                }
                Button("Open Settings") { model.setup.openSettings() }
            }
            .font(.ui(15, .medium))
            .foregroundStyle(Palette.ink)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.paper, in: .rect(cornerRadius: Metrics.cardRadius))
    }

    private func checkRow(_ title: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Palette.toggleGreen : Palette.lockGray)
            Text(title)
                .font(.ui(15))
                .foregroundStyle(Palette.text)
        }
    }
}
