@preconcurrency import AVFoundation
import AppKit
import AuthenticationServices
import Foundation
import MurmurCore
import os
import Supabase
import SwiftUI

/// Everything Murmur for Mac runs: the account (the same Supabase project as the iPhone), the
/// history and library stores, the dictation engine, the fn shortcut, the floating bar, and the
/// window's navigation.
@MainActor
@Observable
final class MacAppModel {
    enum Page: String, CaseIterable, Identifiable {
        case home, notes, dictionary, snippets, style, insights
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "Home"
            case .notes: "Notes"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .style: "Style"
            case .insights: "Insights"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .notes: "doc.text"
            case .dictionary: "book.closed"
            case .snippets: "bolt"
            case .style: "pencil"
            case .insights: "chart.bar"
            }
        }
    }

    enum Sheet: Identifiable, Equatable {
        case word(DictionaryEntry?)
        case snippet(SnippetDefinition?)
        case paywall

        var id: String {
            switch self {
            case .word(let entry): "word-\(entry?.id.uuidString ?? "new")"
            case .snippet(let snippet): "snippet-\(snippet?.id.uuidString ?? "new")"
            case .paywall: "paywall"
            }
        }
    }

    let backend: Backend?
    let history: HistoryStore
    let library: LibraryStore
    let engine: DictationEngine
    let apps: DictationAppLog
    let accountService: AccountService?
    /// The project's functions (`paddle-checkout` here; dictation goes through the engine).
    @ObservationIgnored let functions: EdgeFunctionClient?
    /// Sample content and no shortcut or bar: screenshots of the window (`-mac-fixtures`).
    let usesFixtures: Bool
    @ObservationIgnored let hotkey = HotkeyMonitor()
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let librarySync: LibrarySync?
    @ObservationIgnored private let styleSync: StyleSync?
    @ObservationIgnored private var flowBar: FlowBarController?
    @ObservationIgnored private var permissionPoll: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "App")

    /// "Murmur is on" in the menu-bar menu: off, the shortcut does nothing and the bar hides.
    var enabled = UserDefaults.standard.object(forKey: "macEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "macEnabled")
            if enabled { startHotkeyWhenTrusted() } else { hotkey.stop() }
        }
    }
    /// Opens a window by id; taken from a view, which is where SwiftUI hands it out.
    @ObservationIgnored var openWindowAction: OpenWindowAction?
    /// The note the quick-note window shows.
    var quickNoteID: UUID?

    // Navigation
    var page: Page = .home
    var sheet: Sheet?
    var selectedNoteID: UUID?

    // Account
    private(set) var quota: AccountService.Quota?
    private(set) var referrals: AccountService.Referrals?

    // Permissions
    private(set) var accessibilityGranted = MacPermissions.accessibilityGranted
    private(set) var microphone = MacPermissions.microphone
    private(set) var globeKeyAction = MacPermissions.globeKeyAction

    // Sign-in
    var email = ""
    var code = ""
    private(set) var codeSentTo: String?
    private(set) var signInBusy = false
    private(set) var signInError: String?

    /// The style every dictation is written in, synced with the account like the iPhone's.
    var defaultStyle: StylePreset = SharedSettings.shared.defaultStyle {
        didSet {
            guard defaultStyle != oldValue else { return }
            SharedSettings.shared.defaultStyle = defaultStyle
            Task { await styleSync?.sync(onboardingComplete: true) }
        }
    }

    // Onboarding
    var onboardingComplete = UserDefaults.standard.bool(forKey: "macOnboardingComplete") {
        didSet { UserDefaults.standard.set(onboardingComplete, forKey: "macOnboardingComplete") }
    }
    /// The practice reply box's text (onboarding's "Try it here").
    var practiceText = ""
    /// While onboarding's "Hold fn to talk" step is on screen, the key only lights the keycap.
    var shortcutTestActive = false
    private(set) var shortcutHeld = false
    private(set) var shortcutTried = false

    // Cards the user put away
    var homeIntroDismissed = UserDefaults.standard.bool(forKey: "macHomeIntroDismissed") {
        didSet { UserDefaults.standard.set(homeIntroDismissed, forKey: "macHomeIntroDismissed") }
    }
    var dictionaryIntroDismissed = UserDefaults.standard.bool(forKey: "macDictionaryIntroDismissed") {
        didSet { UserDefaults.standard.set(dictionaryIntroDismissed, forKey: "macDictionaryIntroDismissed") }
    }
    var snippetsIntroDismissed = UserDefaults.standard.bool(forKey: "macSnippetsIntroDismissed") {
        didSet { UserDefaults.standard.set(snippetsIntroDismissed, forKey: "macSnippetsIntroDismissed") }
    }

    init(fixtures: Bool = MacLaunchOptions.current.fixtures) {
        usesFixtures = fixtures
        let settings = SharedSettings.shared
        Self.applyLanguageDefaults(settings)
        let backend = fixtures ? nil : Backend.fromInfoPlist()
        self.backend = backend
        history = HistoryStore.open(inMemory: fixtures)
        library = LibraryStore.open(inMemory: fixtures)
        apps = DictationAppLog(url: fixtures ? nil : DictationAppLog.defaultURL)
        let functions = backend.map { EdgeFunctionClient(backend: $0) }
        self.functions = functions
        let pipeline = DictationPipeline(cleanup: CleanupClient(functions: functions))
        self.pipeline = pipeline
        let account = backend?.account
        engine = DictationEngine(pipeline: pipeline, functions: functions, backend: backend, history: history,
                                 isSignedIn: { account?.isSignedIn ?? false },
                                 consent: { await MacConsent.ensure() })
        if let backend {
            librarySync = LibrarySync(library: library, remote: SupabaseLibraryRemote(backend: backend),
                                      isEnabled: { account?.isSignedIn ?? false })
            let trial = TrialClaim(functions: functions, currentUser: { backend.client.auth.currentSession?.user.id })
            let service = AccountService(backend: backend, functions: functions, trial: trial)
            accountService = service
            styleSync = StyleSync(remote: service, local: { settings.defaultStyle },
                                  apply: { settings.defaultStyle = $0 }, isEnabled: { account?.isSignedIn ?? false })
        } else {
            librarySync = nil
            styleSync = nil
            accountService = nil
        }
        if fixtures {
            MacFixtures.seed(history: history, library: library, apps: apps)
            quota = MacFixtures.quota
            page = MacLaunchOptions.current.page ?? .home
            selectedNoteID = library.notes.first?.id
        }
        library.onLocalChange = { [weak self] _, _, _ in self?.librarySync?.syncSoon() }
        engine.hasPro = { [weak self] in self?.quota.map { $0.isPro || $0.onTrial } }
        engine.onDelivered = { [weak self] id, app, bundleID, copied in
            self?.apps.record(id, app: app, bundleID: bundleID, copied: copied)
        }
    }

    var account: AccountModel? { backend?.account }
    var isSignedIn: Bool { usesFixtures || (backend?.account.isSignedIn ?? false) }
    var accountEmail: String? {
        if usesFixtures { return MacFixtures.email }
        return backend?.account.email ?? backend?.client.auth.currentUser?.email
    }

    /// The first name to greet: the account's name if it has one, else the email's first part.
    var displayName: String {
        if usesFixtures { return MacFixtures.name }
        let full = backend?.client.auth.currentUser?.userMetadata["full_name"]?.stringValue
            ?? backend?.client.auth.currentUser?.userMetadata["name"]?.stringValue
        if let first = full?.split(separator: " ").first, !first.isEmpty { return String(first) }
        return accountEmail?.split(separator: "@").first.map(String.init) ?? ""
    }

    /// After launch: the shortcut, the bar, and the account's library, style and plan.
    func start() {
        guard !usesFixtures else { return }
        flowBar = FlowBarController(
            engine: engine, isEnabled: { [weak self] in self?.enabled ?? true },
            onTap: { [weak self] in
                self?.feedLibraryToPipeline()
                self?.engine.begin(handsFree: true)
            },
            onNoticeAction: { [weak self] notice in self?.act(on: notice) })
        hotkey.onEvent = { [weak self] event in self?.handle(event) }
        engine.onEndedOutsideShortcut = { [weak self] in self?.hotkey.reset() }
        if enabled { startHotkeyWhenTrusted() }
        Task {
            await engine.prepare()
            await syncAccountData()
        }
    }

    private func handle(_ event: HotkeyMonitor.Event) {
        if shortcutTestActive {
            switch event {
            case .pushToTalkBegan, .handsFreeBegan: shortcutHeld = true
            case .pushToTalkEnded, .pushToTalkAbandoned, .handsFreeEnded, .cancelled:
                if shortcutHeld { shortcutTried = true }
                shortcutHeld = false
            case .pasteLast, .quickNote: break
            case .commandBegan: shortcutHeld = true
            case .commandEnded:
                shortcutHeld = false
                shortcutTried = true
            }
            return
        }
        switch event {
        case .pushToTalkBegan:
            feedLibraryToPipeline()
            engine.begin(handsFree: false)
        case .pushToTalkEnded:
            engine.end(commit: true)
        case .pushToTalkAbandoned, .cancelled:
            engine.end(commit: false)
        case .handsFreeBegan:
            feedLibraryToPipeline()
            if engine.isListening {
                engine.switchToHandsFree()
            } else {
                engine.begin(handsFree: true)
            }
        case .handsFreeEnded:
            engine.end(commit: true)
        case .pasteLast:
            Task { await engine.pasteLast() }
        case .quickNote:
            openQuickNote()
        case .commandBegan:
            if engine.isListening { engine.end(commit: false) }
            engine.beginCommand()
        case .commandEnded:
            engine.end(commit: true)
        }
    }

    private func feedLibraryToPipeline() {
        pipeline.dictionary = library.dictionaryTerms
        pipeline.snippets = library.snippets
    }

    func syncAccountData() async {
        guard isSignedIn, !usesFixtures else { return }
        await librarySync?.sync(full: false)
        await styleSync?.sync(onboardingComplete: true)
        defaultStyle = SharedSettings.shared.defaultStyle
        feedLibraryToPipeline()
        await refreshAccount()
    }

    /// The plan, trial and this week's words (`my_quota`), and the invite code.
    func refreshAccount() async {
        guard let accountService, isSignedIn else { return }
        quota = (try? await accountService.quota()) ?? quota
        referrals = (try? await accountService.referrals()) ?? referrals
    }

    // MARK: Pro on the web

    enum CheckoutFailure: Error { case notOpenYet, signedOut, unavailable }

    /// A Paddle checkout for the signed-in account (`paddle-checkout`); its link opens in the browser.
    func checkoutURL(annual: Bool) async throws(CheckoutFailure) -> URL {
        guard let functions, isSignedIn else { throw .signedOut }
        guard let body = try? JSONEncoder().encode(["plan": annual ? "annual" : "monthly"]) else { throw .unavailable }
        do {
            let reply = try await functions.send("paddle-checkout", payload: body, contentType: "application/json", timeout: 20)
            struct Reply: Decodable { let url: String }
            guard let url = (try? JSONDecoder().decode(Reply.self, from: reply.data)).flatMap({ URL(string: $0.url) })
            else { throw CheckoutFailure.unavailable }
            return url
        } catch EdgeFunctionError.httpError(code: 404), EdgeFunctionError.httpError(code: 503) {
            // Not deployed, or Paddle not set up yet.
            throw .notOpenYet
        } catch EdgeFunctionError.httpError(code: 401) {
            throw .signedOut
        } catch {
            throw .unavailable
        }
    }

    // MARK: Library

    func saveWord(_ entry: DictionaryEntry?, term: String, misspelling: String?) throws(LibraryError) {
        _ = try library.saveEntry(id: entry?.id, term: term, misspelling: misspelling)
        feedLibraryToPipeline()
    }

    func deleteWord(_ entry: DictionaryEntry) {
        library.deleteEntry(entry.id)
        feedLibraryToPipeline()
    }

    func saveSnippet(_ snippet: SnippetDefinition?, trigger: String, expansion: String) throws(LibraryError) {
        _ = try library.saveSnippet(id: snippet?.id, trigger: trigger, expansion: expansion)
        feedLibraryToPipeline()
    }

    func deleteSnippet(_ snippet: SnippetDefinition) {
        library.deleteSnippet(snippet.id)
        feedLibraryToPipeline()
    }

    func newNote() {
        let note = library.createNote()
        selectedNoteID = note.id
        page = .notes
    }

    /// The quick-note window with a new note (⌥⌘N, the menu), or with `note` from Notes.
    func openQuickNote(_ note: Note? = nil) {
        quickNoteID = note?.id ?? library.createNote().id
        openWindowAction?(id: "quicknote")
        NSApp.activate()
    }

    func openMainWindow(page: Page? = nil) {
        if let page { self.page = page }
        openWindowAction?(id: onboardingComplete ? "main" : "onboarding")
        NSApp.activate()
    }

    /// The button on a notice card.
    private func act(on notice: DictationEngine.Notice) {
        engine.dismissNotice()
        switch notice.kind {
        case .signedOut: openMainWindow()
        case .limitReached, .proRequired:
            openMainWindow()
            sheet = .paywall
        case .microphone: MacPermissions.openMicrophoneSettings()
        case .accessibility: MacPermissions.openAccessibilitySettings()
        default: break
        }
    }

    func deleteTranscript(_ transcript: Transcript) {
        history.delete(transcript.id)
        apps.remove(transcript.id)
    }

    /// The keycap on onboarding's shortcut step, held with the mouse instead of the key.
    func pressTestKey(_ down: Bool) {
        if down {
            shortcutHeld = true
        } else if shortcutHeld {
            shortcutHeld = false
            shortcutTried = true
        }
    }

    func resetShortcutTest() {
        shortcutHeld = false
        shortcutTried = false
    }

    // MARK: Permissions

    /// The tap needs Accessibility; until it's granted, check every second and start it then.
    private func startHotkeyWhenTrusted() {
        refreshPermissions()
        if hotkey.start() { return }
        permissionPoll?.cancel()
        permissionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.refreshPermissions()
                if self.accessibilityGranted, self.hotkey.start() { return }
            }
        }
    }

    func refreshPermissions() {
        accessibilityGranted = MacPermissions.accessibilityGranted
        microphone = MacPermissions.microphone
        globeKeyAction = MacPermissions.globeKeyAction
    }

    func requestMicrophone() async {
        _ = await MacPermissions.requestMicrophone()
        refreshPermissions()
        await engine.prepare()
    }

    func requestAccessibility() {
        MacPermissions.promptForAccessibility()
        startHotkeyWhenTrusted()
    }

    // MARK: Sign-in

    func signInWithGoogle() async {
        guard let backend else { return }
        signInBusy = true
        signInError = nil
        defer { signInBusy = false }
        do {
            let web = WebSignIn()
            try await backend.client.auth.signInWithOAuth(provider: .google, redirectTo: Self.callbackURL) { url in
                try await web.run(url, callbackScheme: Brand.urlScheme)
            }
            backend.didSignIn()
            await syncAccountData()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            logger.error("Google sign-in failed: \(error.localizedDescription, privacy: .public)")
            signInError = "Couldn't sign in with Google: \(error.localizedDescription)"
        }
    }

    func signInWithApple() async {
        guard let backend else { return }
        signInBusy = true
        signInError = nil
        defer { signInBusy = false }
        do {
            let apple = try await AppleSignIn().run()
            try await backend.client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: apple.idToken, nonce: apple.nonce))
            backend.didSignIn()
            if let name = apple.fullName {
                // Apple sends the name only on the first sign-in.
                _ = try? await backend.client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
            }
            await syncAccountData()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            logger.error("Apple sign-in failed: \(error.localizedDescription, privacy: .public)")
            signInError = "Couldn't sign in with Apple: \(error.localizedDescription)"
        }
    }

    func sendEmailCode() async {
        guard let backend else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else {
            signInError = "Enter your email address."
            return
        }
        signInBusy = true
        signInError = nil
        defer { signInBusy = false }
        do {
            try await backend.client.auth.signInWithOTP(email: address, redirectTo: Self.callbackURL)
            codeSentTo = address
        } catch {
            signInError = "Couldn't send the code: \(error.localizedDescription)"
        }
    }

    func verifyEmailCode() async {
        guard let backend, let address = codeSentTo else { return }
        signInBusy = true
        signInError = nil
        defer { signInBusy = false }
        do {
            try await backend.client.auth.verifyOTP(
                email: address, token: code.trimmingCharacters(in: .whitespaces), type: .email)
            backend.didSignIn()
            codeSentTo = nil
            code = ""
            await syncAccountData()
        } catch {
            signInError = "That code didn't work. Check it, or send a new one."
        }
    }

    func cancelEmailCode() {
        codeSentTo = nil
        code = ""
        signInError = nil
    }

    func signOut() async {
        await backend?.signOut()
        MacConsent.withdraw()
        quota = nil
        referrals = nil
    }

    /// The scheme and path the iPhone uses; the project already allows them as a redirect.
    static let callbackURL = URL(string: "\(Brand.urlScheme)://auth-callback")!

    // MARK: Defaults

    /// The iPhone's default for a new install: Auto-detect among the Mac's own languages, as
    /// language codes ("en", "ru"; not "en-TR", which the first engine build stored).
    private static func applyLanguageDefaults(_ settings: SharedSettings) {
        let stored = settings.dictationLanguages
        let regional = !stored.isEmpty && stored.allSatisfy { $0.contains("-") }
        guard stored.isEmpty || regional else { return }
        var codes: [String] = []
        for preferred in Locale.preferredLanguages {
            guard let code = Locale(identifier: preferred).language.languageCode?.identifier,
                  !codes.contains(code) else { continue }
            codes.append(code)
            if codes.count == 3 { break }
        }
        settings.dictationLanguages = codes.isEmpty ? ["en"] : codes
    }
}
