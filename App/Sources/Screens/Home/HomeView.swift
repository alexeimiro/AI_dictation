import MurmurCore
import MurmurUI
import StoreKit
import SwiftData
import SwiftUI

/// Home: first what needs attention (a lost sign-in, a session that couldn't start, the weekly
/// limit, the keyboard's setup), then the history by day. The session's control is the bar at the
/// bottom, where the thumb is.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse) private var records: [TranscriptRecord]
    @State private var toast: String?
    @State private var tryingIt = false
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        List {
            notices
            if records.isEmpty {
                EmptyState("Nothing dictated yet",
                           message: "What you dictate shows up here. Open a text field, switch to Murmur and tap the mic.")
                    .padding(.vertical, 56)
                    .plainListRow()
            } else {
                ForEach(DayBucketing.group(records.map(\.snapshot))) { group in
                    Text(Self.title(for: group.day))
                        .font(.murmur(.footnote, weight: .semibold))
                        .foregroundStyle(Theme.third)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                        .plainListRow()
                    ForEach(group.transcripts) { transcript in
                        row(transcript)
                    }
                }
            }
        }
        .plainList()
        .toast($toast)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                SessionBar()
                // Only while the microphone is on: once it's off there is nothing to go back for.
                if let hint = model.returnHint, model.session.isLive {
                    ReturnHintLine(hint: hint)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.2), value: model.returnHint)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MenuToolbarItem()
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    Wordmark(height: 22)
                        .accessibilityIdentifier(AccessibilityID.screen("home"))
                    if let quota = model.quota { Chip(quota.chip()) }
                }
                // The logo is a mark, not text to read: it keeps its size, so it fits the bar.
                .dynamicTypeSize(...DynamicTypeSize.large)
            }
            BarActionItem(systemImage: "pencil.line", label: "New note", id: AccessibilityID.newNote) {
                model.openNewNote(dictating: false)
            }
        }
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

    /// The cards above the history, each only while it applies.
    @ViewBuilder
    private var notices: some View {
        Group {
            // Lost session, a guest from before sign-in was required, or an old install that never
            // signed in: Murmur records for none of them.
            if !model.maySignedInDictate {
                SignedOutCard(phrase: model.account?.phrase) { model.showSignIn() }
            }
            if SessionNotice.isShown(for: model.session.phase) {
                SessionNotice()
            }
            if let quota = model.quota, quota.remaining == 0, !model.pro.isSubscribed {
                LimitCard(weeklyLimit: quota.weeklyLimit) { model.showsPaywall = true }
            }
            if !model.setup.isComplete, records.isEmpty {
                SetupChecklistCard()
            } else {
                TipCard(title: "Try Murmur where you write", message: "A to-do list, a message or an email. Pick one.",
                        action: "Try it", dismissedKey: "intro.home.dismissed") { tryingIt = true }
            }
        }
        .padding(.vertical, 5)
        .plainListRow()
    }

    private func row(_ transcript: Transcript) -> some View {
        let state = transcript.insertState(now: Date(), claimed: model.transport.payloads.isClaimed(transcript.id))
        return TranscriptRow(transcript: transcript, insertState: state)
            .overlay(alignment: .top) { Hairline() }
            .contentShape(.rect)
            .onTapGesture { copy(transcript) }
            .plainListRow()
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { copy(transcript) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .tint(Theme.second)
                if transcript.canRegenerate {
                    Button { regenerate(transcript) } label: {
                        Label(transcript.status == .cleaned ? "Regenerate" : "Retry", systemImage: "arrow.clockwise")
                    }
                    .tint(Theme.third)
                }
            }
            .swipeActions(edge: .trailing) {
                // Ink, not red: red means the microphone is open.
                Button(role: .destructive) { model.history.delete(transcript.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(Theme.ink)
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
                Button { model.history.delete(transcript.id) } label: { Label("Delete", systemImage: "trash") }
            }
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
        toast = "Copied"
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
            : "Couldn’t hand this to the keyboard"
    }

    static func title(for day: Date, now: Date = Date()) -> String {
        switch DayBucketing.relativeDay(for: day, now: now) {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .other: day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
    }
}

/// Home's session control: a button that turns Murmur on, then the session's state with a button
/// that turns it off. Red shows only while the microphone is open.
struct SessionBar: View {
    @Environment(AppModel.self) private var model
    /// When the dictation being heard started, for the timer.
    @State private var listeningSince: Date?

    var body: some View {
        let phase = model.session.phase
        let isOn = model.session.isLive
        content(for: phase)
            .onChange(of: recordingID, initial: true) { _, id in
                listeningSince = id == nil ? nil : Date()
            }
            .disabled(phase == .starting)
            // One switch for VoiceOver, as it was in the top bar.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Murmur is on")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits([.isButton, .isToggle])
            .accessibilityHint(Self.title(for: phase))
            .accessibilityInputLabels(isOn ? ["Turn off Murmur", "Stop"] : ["Start Murmur", "Start"])
            .accessibilityAction { toggle() }
            .accessibilityIdentifier(AccessibilityID.sessionControl)
            .sensoryFeedback(.selection, trigger: isOn)
    }

    @ViewBuilder
    private func content(for phase: SessionController.Phase) -> some View {
        switch phase {
        case .off, .failed, .needsReconnect:
            Button(action: toggle) {
                HStack(spacing: 10) {
                    BrandMark(ring: Theme.onInk)
                        .frame(width: 22, height: 22)
                    Text("Start Murmur")
                }
            }
            .buttonStyle(.murmur(.primary))
        case .starting:
            status(Self.title(for: phase), detail: Text(model.session.startDetail ?? "Turning on the microphone"),
                   stops: false) {
                ProgressView()
            }
        case .ready:
            status(Self.title(for: phase), detail: Text("The mic is open for the keyboard")) {
                LiveDot(size: 12)
            }
        case .recording:
            status(Self.title(for: phase), detail: Text(listeningSince ?? Date(), style: .timer).monospacedDigit()) {
                LiveDot(size: 20, rings: 2)
            }
        case .processing:
            status(Self.title(for: phase), detail: Text("Turning what you said into text")) {
                ProgressView()
            }
        }
    }

    /// The bar while the session is starting or on: a marker, two lines and the stop button.
    private func status<Marker: View>(_ title: String, detail: Text, stops: Bool = true,
                                      @ViewBuilder marker: () -> Marker) -> some View {
        HStack(spacing: 14) {
            marker()
                .tint(Theme.ink)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.murmur(.callout, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                detail
                    .font(.murmur(.caption))
                    .foregroundStyle(Theme.second)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if stops {
                Button(action: toggle) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(Theme.onInk)
                        .frame(width: 12, height: 12)
                        .frame(width: 44, height: 44)
                        .background(Theme.ink, in: .circle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(Theme.fill, in: .roundCapsule)
    }

    private var recordingID: UUID? {
        if case .recording(let id) = model.session.phase { id } else { nil }
    }

    private func toggle() {
        if model.session.isLive { model.session.stop() } else { Task { await model.session.start() } }
    }

    static func title(for phase: SessionController.Phase) -> String {
        switch phase {
        case .off: "Murmur is off"
        case .starting: "Turning on…"
        case .ready: "Murmur is on"
        case .recording: "Listening"
        case .processing: "Writing…"
        case .needsReconnect: "Murmur lost the microphone"
        case .failed: "Couldn’t start"
        }
    }
}

/// After the keyboard opened Murmur and Murmur couldn't take the user back to their app: the
/// swipe that does, in one line under the session bar, next to the edge the swipe starts from.
struct ReturnHintLine: View {
    let hint: ReturnHint

    var body: some View {
        Text(hint.text)
            .font(.murmur(.footnote))
            .foregroundStyle(Theme.second)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .accessibilityIdentifier(AccessibilityID.returnHint)
    }
}

/// The session couldn't start, or lost the microphone to something else: what happened and the
/// way out.
struct SessionNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.session.phase {
        case .failed(let message):
            NoticeCard(SessionBar.title(for: model.session.phase), message: message, isAlert: true) {
                // Trying again can't work while nobody is signed in.
                if model.maySignedInDictate {
                    Button("Try again") { Task { await model.session.start() } }
                        .buttonStyle(.murmur(.secondary, size: .compact))
                } else {
                    Button("Sign in") { model.showSignIn() }
                        .buttonStyle(.murmur(.secondary, size: .compact))
                }
            }
        case .needsReconnect:
            NoticeCard(SessionBar.title(for: model.session.phase), message: "Reconnect to keep dictating.",
                       isAlert: true) {
                Button("Reconnect") { model.session.appDidBecomeActive() }
                    .buttonStyle(.murmur(.secondary, size: .compact))
            }
        case .off, .starting, .ready, .recording, .processing:
            EmptyView()
        }
    }

    /// Everything else shows in the bar at the bottom.
    static func isShown(for phase: SessionController.Phase) -> Bool {
        switch phase {
        case .failed, .needsReconnect: true
        case .off, .starting, .ready, .recording, .processing: false
        }
    }
}

/// Basic's weekly words are used up: they come back next week, or Pro has no limit.
private struct LimitCard: View {
    let weeklyLimit: Int?
    let upgrade: () -> Void

    var body: some View {
        NoticeCard("You’ve used this week’s \(weeklyLimit?.formatted() ?? "free") words",
                   message: "Dictation picks up again next week. \(Brand.name) Pro has no weekly limit.") {
            Button("See \(Brand.name) Pro", action: upgrade)
                .buttonStyle(.murmur(.primary, size: .compact))
        }
    }
}

/// The account's session was lost without the user asking: cloud dictation waits until they sign
/// in again. Also shown to a guest, and to an old install that never signed in.
struct SignedOutCard: View {
    /// How the copy names the remembered account (`AccountModel.Account.phrase`).
    let phrase: String?
    let signIn: () -> Void

    var body: some View {
        NoticeCard("You’re signed out", message: detail) {
            Button("Sign in", action: signIn)
                .buttonStyle(.murmur(.secondary, size: .compact))
        }
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
        let asksForMicrophone = model.setup.microphone == .undetermined
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish setting up")
                .font(.murmur(.headline))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 12) {
                step("Add the Murmur keyboard", done: model.setup.keyboardAdded)
                step("Allow Full Access", done: model.setup.fullAccessConfirmed)
                step("Allow the microphone", done: model.setup.microphone == .granted)
            }
            ActionRow {
                if asksForMicrophone {
                    Button("Allow microphone") { Task { await model.setup.requestMicrophone() } }
                        .buttonStyle(.murmur(.primary, size: .compact))
                }
                Button("Open Settings") { model.setup.openSettings() }
                    .buttonStyle(.murmur(asksForMicrophone ? .secondary : .primary, size: .compact))
            }
        }
        .softCard(padding: 18)
    }

    private func step(_ title: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.onInk)
                        .frame(width: 22, height: 22)
                        .background(Theme.ink, in: .circle)
                } else {
                    Circle()
                        .strokeBorder(Theme.third, lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
            }
            .accessibilityHidden(true)
            Text(title)
                .font(.murmur(.callout))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not done")
    }
}
