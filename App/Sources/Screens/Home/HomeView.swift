import MurmurCore
import MurmurUI
import StoreKit
import SwiftData
import SwiftUI

/// Home: the signed-out card while the account's session is lost, the session's status when it
/// needs attention (the switch is in the toolbar), the keyboard setup checklist until it's done,
/// a nudge to try Murmur in another app, and the history by day.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse) private var records: [TranscriptRecord]
    @State private var toast: String?
    @State private var tryingIt = false
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        List {
            if let account = model.account, account.isSignedOut {
                Section {
                    SignedOutCard(phrase: account.phrase) { model.signInSheet = .options }
                }
            }
            if SessionCard.isShown(for: model.session.phase) {
                Section {
                    SessionCard()
                }
            }
            if !model.setup.isComplete, records.isEmpty {
                Section {
                    SetupChecklistCard()
                }
            } else {
                Section {
                    IntroCard(
                        title: "Try Murmur in any app", accent: "any app",
                        message: Text("Draft emails, send messages and jot down notes with your voice."),
                        action: "Try it now",
                        dismissedKey: "intro.home.dismissed"
                    ) { tryingIt = true }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

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
            ToolbarItem(placement: .topBarLeading) { MenuButton() }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Wordmark(height: 22)
                    if let quota = model.quota { PlanBadge(text: quota.badge) }
                }
                // The logo is a mark, not text to read: it keeps its size, so it fits the bar.
                .dynamicTypeSize(...DynamicTypeSize.large)
            }
            ToolbarItem(placement: .topBarTrailing) { SessionToggle() }
        }
        .toast($toast)
        .sheet(isPresented: $tryingIt) { TryItSheet() }
        .task {
            model.history.reconcileInsertions(payloads: model.transport.payloads)
            await askForRatingIfDue()
        }
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
                .tint(Palette.danger)
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

    /// iOS's rating prompt, a moment after Home appears, once `RatingPrompt` says it's due.
    private func askForRatingIfDue() async {
        let version = RatingPrompt.currentVersion
        guard !model.launchOptions.useFixtures,
              RatingPrompt.shouldAsk(history: model.history.recent(limit: 200), record: RatingPrompt.record(),
                                     version: version) else { return }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, model.router.tab == .home, model.router.path.isEmpty, !model.router.isMenuOpen
        else { return }
        RatingPrompt.markAsked(version: version)
        requestReview()
    }

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

/// The session switch in Home's toolbar: green while Murmur is on. Drawn by hand, since a
/// toolbar shows a `Toggle` as a text button.
struct SessionToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let isOn = model.session.isLive
        Button {
            if isOn { model.session.stop() } else { Task { await model.session.start() } }
        } label: {
            Capsule()
                .fill(isOn ? Palette.toggleGreen : Palette.progressOff)
                .frame(width: 40, height: 24)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .padding(3)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
                .animation(.snappy(duration: 0.2), value: isOn)
        }
        .disabled(model.session.phase == .starting)
        .accessibilityLabel("Murmur is on")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityHint(SessionCard.statusText(for: model.session.phase))
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// The session's status while it needs attention: starting, failed or waiting to reconnect.
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
        .padding(.vertical, 4)
        // In a List row, default-style buttons fire on a tap anywhere in the row, all of them at once.
        .buttonStyle(.borderless)
    }

    /// Off, on and listening show in the toolbar's switch alone.
    static func isShown(for phase: SessionController.Phase) -> Bool {
        switch phase {
        case .starting, .failed, .needsReconnect: true
        case .off, .ready, .recording, .processing: false
        }
    }

    private var statusText: String {
        Self.statusText(for: model.session.phase)
    }

    static func statusText(for phase: SessionController.Phase) -> String {
        switch phase {
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

/// The account's session was lost without the user asking: cloud dictation waits until they sign
/// in again (or continue as a guest, on the sheet).
struct SignedOutCard: View {
    /// How the copy names the remembered account (`AccountModel.Account.phrase`).
    let phrase: String?
    let signIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You're signed out")
                .font(.ui(15, .semibold))
                .foregroundStyle(Palette.text)
            Text(detail)
                .font(.ui(14))
                .foregroundStyle(Palette.textSecondary)
            Button("Sign in", action: signIn)
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.borderless)
        // One element for VoiceOver; activating it signs in.
        .accessibilityElement(children: .combine)
        .accessibilityAction(.default, signIn)
    }

    private var detail: String {
        guard let phrase else { return "Sign in again to keep cloud dictation and your plan." }
        return "Sign in again \(phrase) to keep cloud dictation and your plan."
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
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .buttonStyle(.borderless)
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
