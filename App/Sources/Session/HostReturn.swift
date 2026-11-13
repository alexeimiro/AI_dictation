import Foundation
import MurmurCore
import Observation
import os
import UIKit

/// Sends the user back to the app they were typing in after the keyboard opened Murmur. iOS has
/// no API for it (Apple DTS; FB22247647), so it takes two steps:
/// - UIKit keeps a record of the app that last showed a keyboard (`KeyboardHostObserver`). That
///   is an implementation detail, not API: if UIKit changes, the app is unknown and Home says how
///   to swipe back (`ReturnHint`).
/// - That app is reopened by its URL scheme, which is public API, so only apps whose bare scheme
///   brings them back as they were are listed (`HostAppCatalog`).
@MainActor
@Observable
final class HostReturn {
    /// What happened the last time, for Settings › Debug.
    private(set) var lastOutcome: String?

    @ObservationIgnored private let observer = KeyboardHostObserver()
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Return")

    /// False once an iOS update removes what the observer reads; then it's always the swipe.
    var isAvailable: Bool { observer.isAttached }

    /// Waits until dictation `requestId` is recording, however long the start takes (a question, a
    /// permission alert, a slow audio route), then reopens the app the keyboard was used in.
    /// `shouldContinue` turns false once a newer link or a shortcut has taken over. The rules are
    /// `ReturnPlan`'s.
    func returnToHost(requestId: UUID, linkAt: Date, session: SessionController,
                      shouldContinue: () -> Bool) async -> ReturnOutcome {
        var plan = ReturnPlan(requestId: requestId, autoReturn: SharedSettings.shared.autoReturn)
        lastOutcome = "Waiting for the microphone…"
        while true {
            let presence = shouldContinue() ? ReturnPresence(UIApplication.shared.applicationState) : .gone
            let host = observer.log.recent(since: linkAt.addingTimeInterval(-KeyboardHostLog.lookBack))
            switch plan.next(phase: session.phase, presence: presence, host: host,
                             sinceLink: Date().timeIntervalSince(linkAt)) {
            case .wait:
                try? await Task.sleep(for: .milliseconds(50))
            case .open(let entry):
                let opened = await UIApplication.shared.open(entry.url)
                if opened { session.didReturnToHost(for: requestId) }
                return record(opened ? .returned(app: entry.name) : .couldNotOpen(app: entry.name),
                              plan: plan, linkAt: linkAt)
            case .stop(let outcome):
                return record(outcome, plan: plan, linkAt: linkAt)
            }
        }
    }

    private func record(_ outcome: ReturnOutcome, plan: ReturnPlan, linkAt: Date) -> ReturnOutcome {
        let decided = Int((Date().timeIntervalSince(linkAt) * 1000).rounded())
        let recording = plan.recordingAt.map { "recording at \(Int(($0 * 1000).rounded())) ms" } ?? "never recording"
        let times = "decided \(decided) ms after the link, \(recording)"
        lastOutcome = "\(outcome.summary) (\(times))"
        // The reason and the times are the same for everyone, so a release build logs them too.
        // App names say which apps someone types in: public only in development builds.
        #if DEBUG
        logger.info("Auto-return: \(outcome.code, privacy: .public), \(times, privacy: .public); \(outcome.summary, privacy: .public)")
        #else
        logger.info("Auto-return: \(outcome.code, privacy: .public), \(times, privacy: .public); \(outcome.summary, privacy: .private)")
        #endif
        return outcome
    }

    /// The user swiped back by hand, and the keyboard reported itself in their app. `word` says
    /// what became of the dictation they were owed (`AppModel.keyboardStatusChanged`):
    /// "listeningAgain" when it was started again because the session had dropped their recording.
    func noteOwedDictation(_ word: String, sinceLink: TimeInterval) {
        let milliseconds = Int((sinceLink * 1000).rounded())
        lastOutcome = (lastOutcome.map { "\($0); " } ?? "") + "\(word) \(milliseconds) ms after the link"
        logger.info("Auto-return: \(word, privacy: .public), \(milliseconds) ms after the link, when the keyboard was back")
    }
}

/// Where Murmur is while a return is under way.
enum ReturnPresence: Equatable {
    /// On screen and taking touches.
    case active
    /// On screen under an alert or the app switcher; it may be active again in a moment.
    case inactive
    /// The user left Murmur, or a newer link or a shortcut took over.
    case gone

    init(_ state: UIApplication.State) {
        switch state {
        case .active: self = .active
        case .inactive: self = .inactive
        default: self = .gone
        }
    }
}

/// How a return ended: for the line on Home, the Debug screen and the log.
enum ReturnOutcome: Equatable {
    /// The app was reopened.
    case returned(app: String)
    /// "Return to the app automatically" is off. `host`: the app's bundle ID, if it was learned.
    case turnedOff(host: String?)
    /// UIKit never said which app the keyboard was in.
    case notLearned
    /// The app is known but has no URL that brings it back as it was.
    case notListed(host: String)
    /// iOS refused the app's URL.
    case couldNotOpen(app: String)
    /// The microphone is on, but that dictation isn't recording: it was dropped, or it ended.
    case notRecording(host: String?)
    /// The session didn't start, or was turned off.
    case sessionOff
    /// The user left Murmur first, or a newer link or a shortcut took over.
    case left

    /// One word for the log. It names no app, so every build may print it.
    var code: String {
        switch self {
        case .returned: "returned"
        case .turnedOff: "turnedOff"
        case .notLearned: "notLearned"
        case .notListed: "notListed"
        case .couldNotOpen: "couldNotOpen"
        case .notRecording: "notRecording"
        case .sessionOff: "sessionOff"
        case .left: "left"
        }
    }

    /// The Debug screen's sentence.
    var summary: String {
        switch self {
        case .returned(let app): "\(app): back"
        case .turnedOff: "Turned off"
        case .notLearned: "Didn't learn which app it was"
        case .notListed(let host): "Not in the list: \(host)"
        case .couldNotOpen(let app): "\(app): couldn't open it"
        case .notRecording: "The microphone is on, but that dictation isn't recording"
        case .sessionOff: "The session isn't on"
        case .left: "Murmur was left first, or a newer start took over"
        }
    }

    /// What Home says when the user has to go back by hand; nil when they are back already, or
    /// have nothing to go back for.
    var hint: ReturnHint? {
        switch self {
        case .returned, .sessionOff, .left: nil
        case .notLearned: ReturnHint(appName: nil)
        case .couldNotOpen(let app): ReturnHint(appName: app)
        case .notListed(let host): ReturnHint(appName: HostAppCatalog.name(forBundleID: host))
        case .turnedOff(let host), .notRecording(let host):
            ReturnHint(appName: host.flatMap(HostAppCatalog.name(forBundleID:)))
        }
    }
}

/// The line under Home's session bar after the keyboard opened Murmur and Murmur couldn't take
/// the user back: the swipe that does it.
struct ReturnHint: Equatable {
    /// The app to go back to, when its name is known.
    var appName: String?

    var text: String {
        "Swipe right along the bottom edge to go back to \(appName ?? "your app")"
    }
}

/// Decides each step of a return from what is known at that moment. It has no UIKit and no clock
/// of its own, so the rules can be tested.
struct ReturnPlan {
    enum Step: Equatable {
        case wait
        case open(HostAppCatalog.Entry)
        case stop(ReturnOutcome)
    }

    /// UIKit names the app about a second after the keyboard's link. This long after it, it won't.
    static let hostWindow: TimeInterval = 3
    /// After a start that took longer than `hostWindow`, the app still gets this long to be named.
    static let hostWindowAfterRecording: TimeInterval = 1.5
    /// A session that is on without the dictation may be between two recordings of it: after some
    /// starts the audio route is rebuilt, and the dictation begins again.
    static let recordingGrace: TimeInterval = 1.5

    let requestId: UUID
    /// The setting "Return to the app automatically". Off, the app is still learned, for the hint.
    let autoReturn: Bool
    /// When the dictation was first seen recording, in seconds after the link.
    private(set) var recordingAt: TimeInterval?
    /// Since when the session has been on without the dictation.
    private var withoutDictationSince: TimeInterval?

    init(requestId: UUID, autoReturn: Bool) {
        self.requestId = requestId
        self.autoReturn = autoReturn
    }

    /// `host`: the bundle ID UIKit reported for this link, if any. `sinceLink`: seconds since the
    /// keyboard's link arrived.
    mutating func next(phase: SessionController.Phase, presence: ReturnPresence, host: String?,
                       sinceLink: TimeInterval) -> Step {
        guard presence != .gone else { return .stop(.left) }
        switch phase {
        case .starting:
            // The start decides how long this takes; the request itself expires in the session.
            withoutDictationSince = nil
            return .wait
        case .off, .failed:
            return .stop(.sessionOff)
        case .recording(requestId):
            withoutDictationSince = nil
            let recordingAt = recordingAt ?? sinceLink
            self.recordingAt = recordingAt
            guard let host else {
                let deadline = max(Self.hostWindow, recordingAt + Self.hostWindowAfterRecording)
                guard sinceLink >= deadline else { return .wait }
                return .stop(autoReturn ? .notLearned : .turnedOff(host: nil))
            }
            guard autoReturn else { return .stop(.turnedOff(host: host)) }
            guard let entry = HostAppCatalog.entry(forBundleID: host) else { return .stop(.notListed(host: host)) }
            // An app can only be opened from the front: under an alert, wait for it to go.
            return presence == .active ? .open(entry) : .wait
        case .ready, .recording, .processing, .needsReconnect:
            let since = withoutDictationSince ?? sinceLink
            withoutDictationSince = since
            return sinceLink - since < Self.recordingGrace ? .wait : .stop(.notRecording(host: host))
        }
    }
}

/// The app UIKit last reported as showing a keyboard. Separate from the observer, so the rules
/// about which reports count can be tested.
struct KeyboardHostLog {
    /// A report up to this much older than the keyboard's link still names the app it came from:
    /// it often arrives first, especially when the link launches Murmur.
    static let lookBack: TimeInterval = 5

    private(set) var latest: (bundleID: String, seenAt: Date)?
    /// Murmur and its extensions show keyboards too; they are never the app to go back to.
    let ownBundleID: String?

    mutating func record(_ bundleID: String, at date: Date) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let ownBundleID, trimmed == ownBundleID || trimmed.hasPrefix(ownBundleID + ".") { return }
        latest = (trimmed, date)
    }

    func recent(since date: Date) -> String? {
        guard let latest, latest.seenAt >= date else { return nil }
        return latest.bundleID
    }
}

/// Watches `currentState` on UIKit's `_UIRemoteKeyboards`, whose `sourceBundleIdentifier` names
/// the app that last showed a keyboard. Every step is checked first, because asking an object for
/// a key it doesn't have raises an Objective-C exception that Swift can't catch.
private final class KeyboardHostObserver: NSObject, @unchecked Sendable {
    private static let stateKey = "currentState"
    private static let sourceKey = "sourceBundleIdentifier"

    private let lock = NSLock()
    private var _log = KeyboardHostLog(ownBundleID: Bundle.main.bundleIdentifier)
    private let remoteKeyboards: NSObject?

    var log: KeyboardHostLog { lock.withLock { _log } }
    var isAttached: Bool { remoteKeyboards != nil }

    override init() {
        remoteKeyboards = Self.sharedRemoteKeyboards()
        super.init()
        remoteKeyboards?.addObserver(self, forKeyPath: Self.stateKey, options: [.initial, .new], context: nil)
    }

    deinit {
        remoteKeyboards?.removeObserver(self, forKeyPath: Self.stateKey)
    }

    private static func sharedRemoteKeyboards() -> NSObject? {
        let shared = NSSelectorFromString("sharedRemoteKeyboards")
        guard let type = NSClassFromString("_UIRemoteKeyboards") as? NSObject.Type, type.responds(to: shared),
              let instance = type.perform(shared)?.takeUnretainedValue() as? NSObject,
              instance.responds(to: NSSelectorFromString(stateKey)) else { return nil }
        return instance
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard let state = change?[.newKey] as? NSObject,
              state.responds(to: NSSelectorFromString(Self.sourceKey)),
              let bundleID = state.value(forKey: Self.sourceKey) as? String else { return }
        lock.withLock { _log.record(bundleID, at: Date()) }
    }
}

/// Apps Murmur can send the user back to, by a URL scheme that just brings them to the front.
/// Apps whose scheme opens something new (Safari's starts a search) aren't listed; for those, and
/// any app not here, Home says how to swipe back.
enum HostAppCatalog {
    struct Entry: Equatable {
        let name: String
        let url: URL
    }

    static func entry(forBundleID bundleID: String) -> Entry? {
        if let entry = entries[bundleID] { return entry }
        return entries.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
    }

    /// What to call an app in "go back to …": a listed app's name, or that of an app named below.
    static func name(forBundleID bundleID: String) -> String? {
        entry(forBundleID: bundleID)?.name
            ?? unlistedNames.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
    }

    /// Apps Murmur can't reopen as they were, but can at least name.
    private static let unlistedNames = ["com.apple.mobilesafari": "Safari"]

    private static let entries: [String: Entry] = [
        "com.apple.mobilenotes": Entry(name: "Notes", url: URL(string: "mobilenotes://")!),
        // Not `sms:` or `messages://`: both put a New Message sheet over the conversation.
        "com.apple.MobileSMS": Entry(name: "Messages", url: URL(string: "ichat://")!),
        "com.apple.mobilemail": Entry(name: "Mail", url: URL(string: "message://")!),
        "net.whatsapp.WhatsApp": Entry(name: "WhatsApp", url: URL(string: "whatsapp://")!),
        "ph.telegra.Telegraph": Entry(name: "Telegram", url: URL(string: "tg://")!),
        "com.facebook.Messenger": Entry(name: "Messenger", url: URL(string: "fb-messenger://")!),
        "com.tinyspeck.chatlyio": Entry(name: "Slack", url: URL(string: "slack://")!),
        "com.microsoft.skype.teams": Entry(name: "Teams", url: URL(string: "msteams://")!),
        "com.hammerandchisel.discord": Entry(name: "Discord", url: URL(string: "discord://")!),
        "com.google.Gmail": Entry(name: "Gmail", url: URL(string: "googlegmail://")!),
        "com.microsoft.Office.Outlook": Entry(name: "Outlook", url: URL(string: "ms-outlook://")!),
        "notion.id": Entry(name: "Notion", url: URL(string: "notion://")!),
        "md.obsidian": Entry(name: "Obsidian", url: URL(string: "obsidian://")!),
        "com.evernote.iPhone.Evernote": Entry(name: "Evernote", url: URL(string: "evernote://")!),
        "com.linkedin.LinkedIn": Entry(name: "LinkedIn", url: URL(string: "linkedin://")!),
        "com.openai.chat": Entry(name: "ChatGPT", url: URL(string: "chatgpt://")!),
        "com.anthropic.claude": Entry(name: "Claude", url: URL(string: "claude://")!),
        "ai.perplexity.app": Entry(name: "Perplexity", url: URL(string: "perplexity-app://")!),
        "com.burbn.instagram": Entry(name: "Instagram", url: URL(string: "instagram://")!),
        "com.facebook.Facebook": Entry(name: "Facebook", url: URL(string: "fb://")!),
        "com.reddit.Reddit": Entry(name: "Reddit", url: URL(string: "reddit://")!),
        "com.skype.skype": Entry(name: "Skype", url: URL(string: "skype://")!),
        "us.zoom.videomeetings": Entry(name: "Zoom", url: URL(string: "zoomus://")!),
        "com.google.chrome.ios": Entry(name: "Chrome", url: URL(string: "googlechrome://")!),
    ]
}
