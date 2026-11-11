import Foundation
import MurmurCore
import Observation
import os
import UIKit

/// Sends the user back to the app they were typing in after the keyboard opened Murmur. iOS has
/// no API for it (Apple DTS; FB22247647), so it takes two steps:
/// - UIKit keeps a record of the app that last showed a keyboard (`KeyboardHostObserver`). That
///   is an implementation detail, not API: if UIKit changes, the app is unknown and the
///   swipe-back screen stays, as before.
/// - That app is reopened by its URL scheme, which is public API, so only apps whose bare scheme
///   brings them back as they were are listed (`HostAppCatalog`).
@MainActor
@Observable
final class HostReturn {
    /// What happened the last time, for Settings › Debug.
    private(set) var lastOutcome: String?
    /// A return is being tried; the swipe-back screen holds back its hint meanwhile.
    private(set) var isPending = false

    /// How long after the keyboard's link a return may still happen. Past that, swiping back by
    /// hand is about as quick.
    static let window: TimeInterval = 3

    @ObservationIgnored private let observer = KeyboardHostObserver()
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Return")

    /// False once an iOS update removes what the observer reads; then it's always swipe-back.
    var isAvailable: Bool { observer.isAttached }

    /// Once dictation `requestId` is recording, reopens the app the keyboard was used in. Gives up
    /// when `shouldContinue` turns false (the user closed the swipe-back screen) or the app left
    /// the screen.
    func returnToHost(requestId: UUID, linkAt: Date, session: SessionController,
                      shouldContinue: () -> Bool) async {
        guard SharedSettings.shared.autoReturn else { return record("Turned off") }
        isPending = true
        defer { isPending = false }
        let linkInstant = ContinuousClock.now
        while Date().timeIntervalSince(linkAt) < Self.window {
            guard shouldContinue(), UIApplication.shared.applicationState == .active else { return }
            if case .recording(requestId) = session.phase,
               let host = observer.log.recent(since: linkAt.addingTimeInterval(-KeyboardHostLog.lookBack)) {
                guard let entry = HostAppCatalog.entry(forBundleID: host) else {
                    return record("Not in the list: \(host)")
                }
                let opened = await UIApplication.shared.open(entry.url)
                let elapsed = DictationPipeline.milliseconds(since: linkInstant)
                return record(opened ? "\(entry.name): back in \(elapsed) ms" : "\(entry.name): couldn't open it")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if case .recording(requestId) = session.phase {
            record("Didn't learn which app it was")
        } else {
            record("The microphone wasn't on in time")
        }
    }

    private func record(_ outcome: String) {
        lastOutcome = outcome
        // App names say which apps someone types in: public only in development builds.
        #if DEBUG
        logger.info("Auto-return: \(outcome, privacy: .public)")
        #else
        logger.info("Auto-return: \(outcome, privacy: .private)")
        #endif
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
/// any app not here, the swipe-back screen stays.
enum HostAppCatalog {
    struct Entry: Equatable {
        let name: String
        let url: URL
    }

    static func entry(forBundleID bundleID: String) -> Entry? {
        if let entry = entries[bundleID] { return entry }
        return entries.first { $0.key.caseInsensitiveCompare(bundleID) == .orderedSame }?.value
    }

    private static let entries: [String: Entry] = [
        "com.apple.mobilenotes": Entry(name: "Notes", url: URL(string: "mobilenotes://")!),
        "com.apple.MobileSMS": Entry(name: "Messages", url: URL(string: "sms:")!),
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
