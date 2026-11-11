import Foundation
import MurmurCore
import Observation
import SwiftUI

/// Root state shared through the environment.
@MainActor
@Observable
final class AppModel {
    let transport: IPCTransport
    let session: SessionController
    let setup: SetupStatus
    let assets: SpeechAssetManager
    let languages: LanguageSettingsModel
    let history: HistoryStore
    /// The personal dictionary, snippets and notes.
    let library: LibraryStore
    /// The mic in a note.
    let noteDictation: NoteDictation
    /// The library on every device signed in to the account; nil without a backend, and in
    /// screenshot runs.
    let librarySync: LibrarySync?
    let styleSync: StyleSync?
    /// Each dictation's timings, for the Debug screen.
    let timingsLog: TimingsLog
    let settings = SettingsModel()
    let pipeline: DictationPipeline
    let onboarding: OnboardingStore
    let onboardingServices: OnboardingServices
    /// Holds practice dictations until onboarding completes; passes everything else to history.
    let practiceBuffer: PracticeTranscriptBuffer
    let practice: any PracticeDictationClient

    /// "Murmur is on — swipe back" after the keyboard opened us.
    var showSwipeBack = false
    /// Takes the user back to the app the keyboard opened us from. Created at launch, so the
    /// first word from UIKit about that app isn't missed.
    let hostReturn = HostReturn()
    /// A start link arrived without a valid one-time token (e.g. from a web page).
    var confirmUntrustedStart = false
    /// The account the backend signs in with, for the signed-out card and the sign-in sheet; nil
    /// without a backend.
    let account: AccountModel?
    /// The plan, support messages and account deletion.
    let accountService: AccountService
    /// The plan and this week's words, refreshed when the app becomes active; nil until the
    /// first answer, and without a backend.
    var quota: AccountService.Quota?
    /// "Improve Murmur for everyone": onboarding's data choice, as Settings changed it since.
    private(set) var dataSharing = false
    /// Murmur Pro on the App Store.
    let pro: ProStore
    /// Murmur Pro's plans are on screen.
    var showsPaywall = false
    /// The "Sign in again" sheet while it's up, and where it opened. RootView presents it, so it
    /// also opens during onboarding; the swipe-back screen and the start dialog close it first.
    var signInSheet: SignInAgainView.Start?
    let router = Router()
    /// `-route <name>` and `-fixtures` launch arguments (screenshot runs).
    let launchOptions: LaunchOptions
    var launchRoute: LaunchRoute? { launchOptions.route }
    /// When the app last became active; nil while inactive or in the background.
    @ObservationIgnored private var activeSince: Date?
    /// Until the app is next on screen after a launch or the background: Auto open note's moment.
    @ObservationIgnored private var returningFromBackground = true
    /// When a link (the keyboard's, a sign-in) or a shortcut last opened the app; Auto open note
    /// leaves those where they lead.
    @ObservationIgnored private var routedAt: Date?
    @ObservationIgnored private var autoNoteTask: Task<Void, Never>?
    @ObservationIgnored private var dictionaryObservation: IPCObservation?
    private let backend: Backend?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let container = SharedContainer.appGroup() ?? .temporary()
        let transport = DarwinIPCTransport(container: container)
        self.transport = transport
        let launchOptions = LaunchOptions(arguments: arguments)
        self.launchOptions = launchOptions
        #if DEBUG
        // Also clears a demo an earlier launch or the Debug screen left on.
        SharedSettings.shared.debugKeyboardDemo = launchOptions.keyboardDemo
        #endif
        let history = HistoryStore.open(inMemory: launchOptions.useFixtures || launchOptions.isOnboardingScreenshot)
        self.history = history
        if launchOptions.useFixtures, !launchOptions.emptyHistory { HistoryFixtures.seed(history) }
        if launchOptions.onboardingStep == .complete { OnboardingFixtures.seedCompletedHistory(history) }
        let library = LibraryStore.open(inMemory: launchOptions.useFixtures || launchOptions.isOnboardingScreenshot)
        self.library = library
        if launchOptions.useFixtures, !launchOptions.emptyLibrary { LibraryFixtures.seed(library) }
        let backend = Self.makeBackend(launchOptions: launchOptions)
        self.backend = backend
        account = backend?.account
        signInSheet = launchOptions.accountSheet
        let functions = backend.map { EdgeFunctionClient(backend: $0) }
        let cleanup = CleanupClient(functions: functions)
        let pipeline = DictationPipeline(cleanup: cleanup)
        self.pipeline = pipeline
        accountService = AccountService(backend: backend, functions: functions)
        if let backend, !launchOptions.useFixtures, !launchOptions.usesOnboardingFixtures {
            let account = backend.account
            librarySync = LibrarySync(library: library, remote: SupabaseLibraryRemote(backend: backend),
                                      isEnabled: { account.isSignedIn })
            styleSync = StyleSync(remote: accountService, local: { SharedSettings.shared.defaultStyle },
                                  apply: { SharedSettings.shared.defaultStyle = $0 }, isEnabled: { account.isSignedIn })
        } else {
            librarySync = nil
            styleSync = nil
        }
        pro = ProStore(functions: functions, accountToken: { backend?.client.auth.currentUser?.id })
        if launchOptions.useFixtures { quota = launchOptions.quotaFixture ?? .fixture }
        let assets = SpeechAssetManager()
        self.assets = assets
        let practiceBuffer = PracticeTranscriptBuffer(
            history: history, fileURL: launchOptions.usesOnboardingFixtures ? nil : PracticeTranscriptBuffer.defaultFileURL)
        self.practiceBuffer = practiceBuffer
        let timingsLog = TimingsLog()
        self.timingsLog = timingsLog
        let dictate = DictateClient(functions: functions)
        let session = SessionController(transport: transport, pipeline: pipeline, assets: assets, history: practiceBuffer,
                                        recordings: history.recordings,
                                        transcription: TranscriptionClient(functions: functions), dictate: dictate,
                                        warmup: backend.map { BackendWarmup(session: $0, dictate: dictate) },
                                        timingsLog: timingsLog)
        self.session = session
        noteDictation = NoteDictation(session: session, library: library)
        self.languages = LanguageSettingsModel(assets: assets, session: session)
        self.setup = SetupStatus(payloads: transport.payloads)
        if launchOptions.usesOnboardingFixtures {
            onboardingServices = .fixtures(
                offer: OnboardingFixtures.offer(variant: launchOptions.onboardingVariant), account: account)
            practice = ScriptedPracticeClient(
                state: OnboardingFixtures.practiceState(step: launchOptions.onboardingStep,
                                                        variant: launchOptions.onboardingVariant))
        } else {
            onboardingServices = .production(backend: backend)
            practice = SessionPracticeClient(session: session, buffer: practiceBuffer)
        }
        onboarding = Self.makeOnboardingStore(
            launchOptions: launchOptions,
            legacyInstall: !history.isEmpty || transport.payloads.readKeyboardStatus() != nil)
        LiveActivityActions.session = session
        #if DEBUG
        if let phase = launchOptions.sessionFixture { session.pinForScreenshots(phase) }
        #endif
        settings.onRetentionChange = { [weak self] in self?.history.applyRetention() }
        onboarding.onComplete = { [weak self] record in self?.onboardingDidComplete(record) }
        if !launchOptions.usesOnboardingFixtures {
            setup.onChange = { [weak self] in self?.forwardSetupStatus() }
            forwardSetupStatus()
        }
        onboarding.resumePendingCompletion()
        router.tab = Router.initialTab(for: launchOptions.route)
        router.path = Router.initialPath(for: launchOptions.route)
        if launchOptions.route == .menu { router.isMenuOpen = true }
        feedLibraryToPipeline()
        library.onChange = { [weak self] in self?.feedLibraryToPipeline() }
        if launchOptions.route == .swipeBack { showSwipeBack = true }
        if launchOptions.route == .transcript, let first = history.recent(limit: 1).first {
            router.path = [.transcript(first.id)]
        }
        if launchOptions.route == .note, let newest = library.notes.first {
            router.paths[.scratchpad] = [.note(newest.id)]
            #if DEBUG
            // With `-session-fixture listening|writing`, the note's own mic shows that state.
            noteDictation.pinForScreenshots(note: newest.id, phase: session.phase)
            #endif
        }
        history.applyRetention()
        recoverInterruptedDictations()
        session.inAppResultHandler = { [weak self] result in self?.noteDictation.deliver(result) }
        library.onLocalChange = { [weak self] kind, id, deleted in
            self?.librarySync?.noteLocalChange(kind, id, deleted: deleted)
        }
        dictionaryObservation = transport.observe(.dictionaryAdded) { [weak self] in
            MainActor.assumeIsolated { self?.importKeyboardAdditions() }
        }
        importKeyboardAdditions()
        dataSharing = UserDefaults.standard.object(forKey: Self.dataSharingKey) as? Bool
            ?? (onboarding.answers.dataChoice?.choice == .improveModel)
        pro.onSynced = { [weak self] in self?.refreshQuota() }
        if !launchOptions.useFixtures && !launchOptions.usesOnboardingFixtures { pro.start() }
        if launchOptions.route == .paywall { showsPaywall = true }
        LiveActivityActions.model = self
        // Learns whether iOS's Low Data Mode is on before the first dictation.
        _ = NetworkConditions.shared
    }

    /// The configured backend; in screenshot runs with `-account-state` (DEBUG), one faking it.
    private static func makeBackend(launchOptions: LaunchOptions) -> Backend? {
        #if DEBUG
        if let state = launchOptions.accountState { return Backend.faking(state) }
        #endif
        return Backend.fromInfoPlist()
    }

    /// The persisted checkpoint, or a throwaway one for screenshot routes and UI tests.
    private static func makeOnboardingStore(launchOptions: LaunchOptions, legacyInstall: Bool) -> OnboardingStore {
        if let step = launchOptions.onboardingStep {
            let record = OnboardingFixtures.record(
                step: step, variant: launchOptions.onboardingVariant, permissions: launchOptions.permissionFixtures)
            return OnboardingStore(persistence: InMemoryOnboardingPersistence(record))
        }
        if launchOptions.route != nil || launchOptions.useFixtures {
            var done = OnboardingRecord()
            done.step = .complete
            done.historySeeded = true
            return OnboardingStore(persistence: InMemoryOnboardingPersistence(done))
        }
        if launchOptions.onboardingFixtures {
            // UI tests: a separate suite, so the journey can be terminated and resumed.
            let persistence = DefaultsOnboardingPersistence(defaults: UserDefaults(suiteName: "murmur.uitests.onboarding"))
            if launchOptions.resetOnboarding { persistence.clear() }
            return OnboardingStore(persistence: persistence)
        }
        let persistence = DefaultsOnboardingPersistence()
        if launchOptions.resetOnboarding { persistence.clear() }
        return OnboardingStore(persistence: persistence, legacyInstall: legacyInstall && !launchOptions.resetOnboarding)
    }

    /// Keeps the onboarding checkpoint in step with what the user changed in Settings.
    private func forwardSetupStatus() {
        guard !onboarding.isComplete else { return }
        // A keyboard that has reported Full Access has necessarily been added, even when the
        // input-mode check (best effort) misses it.
        onboarding.send(.keyboardStatusChanged(
            added: setup.keyboardAdded || setup.fullAccessConfirmed, fullAccess: setup.fullAccessConfirmed))
        onboarding.send(.permissionChanged(.microphone, PermissionState(setup.microphone)))
    }

    private func refreshNotificationPermission() {
        guard !onboarding.isComplete, !launchOptions.usesOnboardingFixtures else { return }
        Task {
            let state = await onboardingServices.notifications.status()
            onboarding.send(.permissionChanged(.notifications, state))
        }
    }

    // MARK: Onboarding actions (faked under -onboarding-fixtures, so tests never leave the app)

    /// "Go to Settings" on the keyboard setup screen.
    func openKeyboardSettings() {
        if launchOptions.usesOnboardingFixtures {
            onboarding.send(.keyboardStatusChanged(added: true, fullAccess: true))
        } else {
            setup.openSettings()
        }
    }

    /// The system microphone prompt (shown once; later calls report the decision).
    func requestMicrophone() async -> PermissionState {
        if launchOptions.usesOnboardingFixtures {
            let state = PermissionState.granted
            onboarding.send(.permissionChanged(.microphone, state))
            return state
        }
        await setup.requestMicrophone()
        return PermissionState(setup.microphone)
    }

    func requestNotifications() async -> PermissionState {
        let state = await onboardingServices.notifications.request()
        onboarding.send(.permissionChanged(.notifications, state))
        return state
    }

    /// After the final screen: practice takes go to history (once), answers to the profile.
    private func onboardingDidComplete(_ record: OnboardingRecord) {
        practiceBuffer.activeExercise = nil
        practiceBuffer.flushToHistory()
        onboarding.markHistorySeeded()
        librarySync?.syncSoon()
        syncStyle()
        let answers = record.answers
        Task { await onboardingServices.profile.sync(answers) }
        redeemPendingInvite()
    }

    /// Dictations whose cleanup never finished keep their raw transcript; a recent one is
    /// offered to the keyboard again, which makes "Your dictation will be saved in Murmur" true.
    private func recoverInterruptedDictations() {
        let now = Date()
        for transcript in history.recoverInterrupted(now: now)
        where transcript.isInsertable && now.timeIntervalSince(transcript.createdAt) < 600 {
            history.republish(transcript.id, payloads: transport.payloads, transport: transport, now: now)
        }
    }

    /// Words added from the keyboard's ☰ menu, into the dictionary and so the next dictation. One
    /// already there is skipped.
    func importKeyboardAdditions() {
        for addition in transport.payloads.takeDictionaryAdditions() {
            _ = try? library.saveEntry(term: addition.term, misspelling: nil)
        }
    }

    /// Each dictation spells the dictionary's words and expands its snippets. The recognizer's
    /// keywords come from the same list when the next session's transcriber is prepared.
    private func feedLibraryToPipeline() {
        pipeline.dictionary = library.dictionaryTerms
        pipeline.snippets = library.snippets
    }

    // MARK: Invites

    private static let pendingInviteKey = "pendingInviteCode"

    /// A friend's code from an invite link, kept until there's an account to give the month to.
    private(set) var pendingInvite = UserDefaults.standard.string(forKey: AppModel.pendingInviteKey)
    /// What a code from an invite link did, for the alert.
    var inviteMessage: String?
    @ObservationIgnored private var redeemingInvite = false

    /// `murmur://invite?code=…`: the code is used now when signed in, else after sign-in.
    func receiveInvite(_ code: String) {
        guard let code = AccountService.normalizedCode(code) else { return }
        pendingInvite = code
        UserDefaults.standard.set(code, forKey: Self.pendingInviteKey)
        redeemPendingInvite()
    }

    /// Uses a code from an invite link once the account is signed in; offline, it waits for the
    /// next time Murmur comes to the front.
    func redeemPendingInvite() {
        guard let code = pendingInvite, !redeemingInvite, onboarding.isComplete, account?.isSignedIn == true,
              !launchOptions.useFixtures, launchOptions.accountState == nil else { return }
        redeemingInvite = true
        Task {
            defer { redeemingInvite = false }
            guard let outcome = try? await accountService.redeem(code: code), outcome != .signInRequired else { return }
            forgetPendingInvite()
            inviteMessage = outcome.message
            if outcome == .ok { refreshQuota() }
        }
    }

    private func forgetPendingInvite() {
        pendingInvite = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingInviteKey)
    }

    /// Sends a style changed on this iPhone, or takes the account's (`StyleSync`): at a sign-in,
    /// when Murmur comes to the front, and when the Style tab changes it.
    func syncStyle() {
        guard let styleSync else { return }
        Task {
            await styleSync.sync(onboardingComplete: onboarding.isComplete)
            settings.reloadFromKeyboard()
        }
    }

    // MARK: Account

    private static let dataSharingKey = "dataSharing"

    /// Settings' "Improve Murmur for everyone", saved to the profile. Returns a message when the
    /// server didn't take it; the switch then goes back.
    func setDataSharing(_ on: Bool) async -> String? {
        let previous = dataSharing
        dataSharing = on
        do {
            try await accountService.setDataSharing(on)
            UserDefaults.standard.set(on, forKey: Self.dataSharingKey)
            return nil
        } catch {
            dataSharing = previous
            return error.localizedDescription
        }
    }

    func refreshQuota() {
        guard !launchOptions.useFixtures, launchOptions.accountState == nil, onboarding.isComplete else { return }
        Task {
            do {
                if let quota = try await accountService.quota() { self.quota = quota }
            } catch {
                // Offline or signed out: the menu keeps the last answer.
            }
        }
    }

    /// Sign out: this iPhone forgets the account and its data, and onboarding starts over.
    func signOut() async {
        await accountService.signOut()
        resetAfterAccountEnded()
    }

    /// Deletes the account on the server, then everything on this iPhone. Returns a message when
    /// the server couldn't delete it (nothing local is touched then).
    func deleteAccount() async -> String? {
        // Signed in with Apple: Apple confirms first, and its code lets the server revoke the
        // sign-in. Cancelling keeps the account.
        var appleCode: String?
        if account?.state?.account.provider == "apple" {
            do {
                let credential = try await AppleSignInCoordinator().signIn(
                    hashedNonce: SupabaseOnboardingAuth.sha256(SupabaseOnboardingAuth.randomNonce()))
                appleCode = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
            } catch .cancelled {
                return "Your account wasn't deleted."
            } catch {
                // Apple can't be asked (Sign in with Apple is off in this build): delete anyway.
            }
        }
        do {
            try await accountService.deleteAccount(appleAuthorizationCode: appleCode)
        } catch {
            return error.localizedDescription
        }
        await accountService.signOut()
        resetAfterAccountEnded()
        return nil
    }

    private func resetAfterAccountEnded() {
        session.stop()
        // Before the library goes: what's deleted here stays in the account.
        librarySync?.reset()
        styleSync?.reset()
        UserDefaults.standard.removeObject(forKey: Self.dataSharingKey)
        dataSharing = false
        forgetPendingInvite()
        deleteAllHistory()
        library.deleteAll()
        quota = nil
        router.isMenuOpen = false
        router.paths = [:]
        router.tab = .home
        onboarding.restart()
    }

    /// Re-runs the cleanup on a stored transcript. Returns a message when it failed.
    func regenerate(_ id: UUID) async -> String? {
        guard let transcript = history.snapshot(id) else { return "Transcript not found" }
        do {
            let updated = try await pipeline.recleanup(transcript)
            history.upsert(updated)
            return nil
        } catch {
            switch error {
            case .notConfigured: return "Cleanup isn't configured on this build"
            case .limitReached: return "Dictation limit reached"
            case .rateLimited: return "Too many requests; try again in a minute"
            case .unavailable(let reason): return "Cleanup unavailable: \(reason)"
            case .signedOut: return "You're signed out. Sign in again on Home"
            }
        }
    }

    /// "Continue without an account" on the sign-in sheet.
    func continueAsGuest() {
        backend?.continueAsGuest()
    }

    /// How the current access token is signed (Debug); nil without a backend or a session.
    var tokenSigning: String? {
        backend?.tokenSigning
    }

    /// Deletes every transcript, and the timings logged with them.
    func deleteAllHistory() {
        history.deleteAll()
        timingsLog.clear()
    }

    // MARK: Action Button, Control Center and Shortcuts

    /// `DictateIntent` without opening Murmur: stops the dictation in progress, or with Murmur on
    /// and its keyboard on screen, starts one the keyboard types out (after the one being
    /// processed). False when Murmur has to open (`openNewNote(dictating:)`).
    func toggleDictationFromShortcut() -> Bool {
        guard onboarding.isComplete else { return false }
        switch session.phase {
        case .recording:
            session.endDictation(commit: true)
            return true
        case .ready, .processing:
            return session.keyboardIsOnScreen && session.beginDictationForKeyboard()
        default:
            return false
        }
    }

    /// Notes, on a new note: `DictateIntent` when the keyboard isn't on screen, "New Murmur
    /// Note", and Auto open note. `dictating` records into it straight away.
    func openNewNote(dictating: Bool) {
        guard onboarding.isComplete else { return }
        routedAt = Date()
        autoNoteTask?.cancel()
        showSwipeBack = false
        signInSheet = nil
        router.isMenuOpen = false
        router.tab = .scratchpad
        let id: UUID
        if case .note(let open)? = router.paths[.scratchpad]?.last, library.note(open)?.isEmpty == true {
            id = open
        } else {
            id = library.createNote().id
            router.paths[.scratchpad] = [.note(id)]
        }
        if dictating { Task { await noteDictation.start(into: id) } }
    }

    /// Auto open note: a new note when Murmur comes on screen by itself, not when a link or a
    /// shortcut opened it (they say where to go, and arrive just after).
    private func scheduleAutoOpenNote() {
        guard settings.autoOpenNote, onboarding.isComplete, launchOptions.route == nil, !launchOptions.useFixtures
        else { return }
        autoNoteTask?.cancel()
        autoNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, !showSwipeBack, signInSheet == nil else { return }
            if let routedAt, Date().timeIntervalSince(routedAt) < 3 { return }
            openNewNote(dictating: false)
        }
    }

    /// Offers a transcript to the keyboard as "Insert last dictation".
    func insertViaKeyboard(_ id: UUID) -> Bool {
        history.republish(id, payloads: transport.payloads, transport: transport)
    }

    func handle(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        routedAt = Date()
        autoNoteTask?.cancel()
        switch link {
        case .startSession(let token):
            if !onboarding.isComplete {
                setup.refresh()
                onboarding.send(.sessionLinkOpened)
                // Without the microphone there is no session to start; onboarding now shows
                // the missing step instead.
                guard setup.microphone == .granted else { return }
            }
            if let token, let launch = transport.payloads.consumeLaunchToken(token, maxAge: 20, now: Date()) {
                startSessionFromKeyboard(showSwipeBack: openedByAnotherApp, request: launch.requestId)
            } else {
                // The dialog can't open over the sign-in sheet: RootView holds it until that's gone.
                signInSheet = nil
                confirmUntrustedStart = true
            }
        case .pro:
            showSwipeBack = false
            guard onboarding.isComplete else { return }
            signInSheet = nil
            router.isMenuOpen = false
            showsPaywall = true
        case .invite(let code):
            showSwipeBack = false
            router.isMenuOpen = false
            receiveInvite(code)
        case .openSettings:
            showSwipeBack = false
            guard onboarding.isComplete else { return }
            // Settings would open under it, out of sight.
            signInSheet = nil
            router.isMenuOpen = false
            router.popToRoot()
            router.open(.settings)
        case .authCallback(let url):
            Task {
                // The link in the sign-in email (Supabase's default emails carry only the link):
                // signing in this way finishes "Continue with your email" too.
                if await onboardingServices.auth.handleCallback(url) {
                    onboarding.send(.authenticated(.email))
                }
            }
        }
    }

    /// The keyboard opened us to start a session. The dictation it asked for (`request`, proven by
    /// the one-time token) records as soon as the microphone is on. When the keyboard was used in
    /// another app, Murmur sends the user back there, or shows "swipe back" if it can't; when it
    /// was used inside Murmur itself there's nowhere to go back to.
    func startSessionFromKeyboard(showSwipeBack: Bool = true, request: UUID? = nil) {
        // Swipe-back can't open over the sign-in sheet: RootView holds it until that's gone. Used
        // inside Murmur, the keyboard may be typing into the sheet, so it stays.
        if showSwipeBack { signInSheet = nil }
        self.showSwipeBack = showSwipeBack
        let linkAt = Date()
        let pending = transport.payloads.readPendingStart().flatMap { $0.requestId == request ? $0 : nil }
        Task {
            await session.start(beginning: pending)
            guard showSwipeBack, let request else { return }
            await hostReturn.returnToHost(requestId: request, linkAt: linkAt, session: session) { [weak self] in
                self?.showSwipeBack == true
            }
        }
    }

    /// True unless the app had already been active for a while when the link arrived, which
    /// means it came from our own keyboard in one of Murmur's text fields.
    private var openedByAnotherApp: Bool {
        guard let activeSince else { return true }
        return Date().timeIntervalSince(activeSince) < 1
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if activeSince == nil { activeSince = Date() }
            if returningFromBackground {
                returningFromBackground = false
                scheduleAutoOpenNote()
            }
            setup.refresh()
            settings.reloadFromKeyboard()
            refreshNotificationPermission()
            session.appDidBecomeActive()
            history.applyRetention()
            history.reconcileInsertions(payloads: transport.payloads)
            importKeyboardAdditions()
            refreshQuota()
            redeemPendingInvite()
            librarySync?.syncSoon(after: .milliseconds(500))
            syncStyle()
        case .background:
            activeSince = nil
            returningFromBackground = true
            autoNoteTask?.cancel()
            showSwipeBack = false
            session.appDidEnterBackground()
        case .inactive:
            activeSince = nil
        default:
            break
        }
    }
}

enum DeepLink: Equatable {
    /// `murmur://session/start?t=<one-time token>` — opened by the keyboard.
    case startSession(token: String?)
    /// `murmur://settings` — the keyboard's settings button.
    case openSettings
    /// `murmur://pro` — Murmur Pro's plans, from the keyboard's limit message.
    case pro
    /// `murmur://invite?code=a1b2c3d4` — Open in Murmur, on a friend's invite page.
    case invite(code: String)
    /// `murmur://auth-callback?…` — the emailed sign-in link and OAuth redirects.
    case authCallback(URL)

    init?(url: URL) {
        guard url.scheme == Brand.urlScheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        switch (url.host, url.path) {
        case ("session", "/start"):
            self = .startSession(token: components?.queryItems?.first { $0.name == "t" }?.value)
        case ("settings", ""), ("settings", "/"):
            self = .openSettings
        case ("pro", ""), ("pro", "/"):
            self = .pro
        case ("invite", ""), ("invite", "/"):
            guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
            self = .invite(code: code)
        case ("auth-callback", _):
            self = .authCallback(url)
        default:
            return nil
        }
    }
}

/// Screens reachable with `-route <name>` for screenshot comparison.
enum LaunchRoute: String {
    case home, settings, languages, debug, transcript, swipeBack
    case dictionary, snippets, style, scratchpad, menu, account, paywall, referral
    /// The newest note, open in its editor.
    case note

    /// What the screens are called now; the names above keep working.
    private static let aliases: [String: LaunchRoute] = ["notes": .scratchpad, "invite": .referral]

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-route"), arguments.indices.contains(index + 1) else {
            return nil
        }
        let name = arguments[index + 1]
        if let route = Self.aliases[name] {
            self = route
        } else {
            self.init(rawValue: name)
        }
    }
}

/// Launch arguments: `-route <name>` opens a screen, `-fixtures` seeds an in-memory history.
///
/// Onboarding (screenshots and UI tests only):
/// - `-onboarding-step <step>` opens that screen with fixture data and services
/// - `-onboarding-variant <name>` picks one of its states (see `OnboardingFixtures`)
/// - `-permission-fixtures <list>` fixes the setup state, e.g. `keyboard,fullAccess,mic=granted`
/// - `-onboarding-fixtures` runs the whole journey on fake services with its own checkpoint
/// - `-onboarding-reset` starts the journey over
///
/// The account (screenshots and UI tests, DEBUG builds only; release builds ignore these):
/// - `-account-state signedOut|guest` fakes it, with `-account-email <address>` and
///   `-account-provider apple|google|email` if given. Signed in has no screen of its own: it's
///   Home and Settings without the account's card and section.
/// - `-account-sheet [email|guest]` opens the sign-in sheet, at the email step or asking about
///   continuing as a guest
///
/// The keyboard (screenshots, DEBUG builds only): `-keyboard-demo <state>[@<layout>]` makes the
/// keyboard show that state instead of the live one (`KeyboardDemo`); a launch without it ends
/// the demo.
///
/// The session (screenshots, DEBUG builds only): `-session-fixture
/// off|starting|on|listening|writing|failed|reconnect` pins its phase without a microphone, so
/// Home can be shot in every state.
///
/// Other states (screenshots, DEBUG builds only, with `-fixtures`): `-quota-fixture
/// trial|basic|limit|pro` picks the plan, `-history-fixture empty` leaves the history empty and
/// `-library-fixture empty` leaves out the words, snippets and notes.
struct LaunchOptions: Equatable {
    var route: LaunchRoute?
    var useFixtures = false
    var onboardingStep: OnboardingStep?
    var onboardingVariant: String?
    var permissionFixtures: PermissionSnapshot?
    var onboardingFixtures = false
    var resetOnboarding = false
    var accountState: AccountModel.State?
    var accountSheet: SignInAgainView.Start?
    var keyboardDemo: KeyboardDemo?
    var sessionFixture: SessionController.Phase?
    var quotaFixture: AccountService.Quota?
    var emptyHistory = false
    var emptyLibrary = false

    init(arguments: [String]) {
        route = LaunchRoute(arguments: arguments)
        useFixtures = arguments.contains("-fixtures")
        onboardingStep = Self.value(after: "-onboarding-step", in: arguments).flatMap(OnboardingStep.init(rawValue:))
        onboardingVariant = Self.value(after: "-onboarding-variant", in: arguments)
        permissionFixtures = Self.value(after: "-permission-fixtures", in: arguments).map(PermissionSnapshot.init(fixture:))
        onboardingFixtures = arguments.contains("-onboarding-fixtures")
        resetOnboarding = arguments.contains("-onboarding-reset")
        #if DEBUG
        accountState = Self.accountFixture(in: arguments)
        if arguments.contains("-account-sheet") {
            accountSheet = Self.value(after: "-account-sheet", in: arguments).flatMap(SignInAgainView.Start.init(rawValue:))
                ?? .options
        }
        keyboardDemo = Self.value(after: "-keyboard-demo", in: arguments).flatMap(KeyboardDemo.init)
        sessionFixture = Self.value(after: "-session-fixture", in: arguments).flatMap(SessionController.Phase.init(fixture:))
        quotaFixture = Self.value(after: "-quota-fixture", in: arguments).flatMap(AccountService.Quota.fixture(named:))
        emptyHistory = Self.value(after: "-history-fixture", in: arguments) == "empty"
        emptyLibrary = Self.value(after: "-library-fixture", in: arguments) == "empty"
        #endif
    }

    #if DEBUG
    private static func accountFixture(in arguments: [String]) -> AccountModel.State? {
        let account = AccountModel.Account(
            userID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            email: value(after: "-account-email", in: arguments),
            provider: value(after: "-account-provider", in: arguments))
        return switch value(after: "-account-state", in: arguments) {
        case "signedOut": .signedOut(account)
        case "guest": .guest(account)
        default: nil
        }
    }
    #endif

    /// A screenshot route into onboarding: nothing persists and nothing prompts.
    var isOnboardingScreenshot: Bool { onboardingStep != nil }

    /// Fake auth, offers, permissions and dictation.
    var usesOnboardingFixtures: Bool { isOnboardingScreenshot || onboardingFixtures }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
