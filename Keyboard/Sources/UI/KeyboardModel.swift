import MurmurCore
import Observation
import SwiftUI

/// A page that takes the place of the pad or the keys under the toolbar.
enum KeyboardOverlay {
    /// The writing styles, from the style pill.
    case style
    /// ☰: translation, the keyboard's settings, and the way to Murmur's letters and Settings.
    case menu
}

/// Observable state behind the SwiftUI parts of the keyboard (toolbar, voice pad, listening panel,
/// overlays).
@MainActor
@Observable
final class KeyboardModel {
    var phase: KeyboardSessionClient.Phase = .idle
    var sessionStatus: SessionStatus = .off
    var pendingResult: DictationResult?
    var hasFullAccess = false
    /// Nobody is signed in to Murmur (`SharedSettings.signedOut`, read only with Full Access): the
    /// keyboard is "You are logged out" and nothing else, once any dictation under way is done.
    var signedOut = false
    /// The app's Default style, which the style pill changes too.
    var style: StylePreset = .verbatim
    var primaryLanguage = DictationLanguage.englishUS
    /// Set only when a verified secondary language exists; shows the language pill.
    var secondaryLanguage: DictationLanguage?
    var languageOverride: DictationLanguage?
    /// The languages picked in the app's Settings › Languages (none: Auto-detect), first in the
    /// Speak and Type in menus.
    var spokenLanguages: [DictationLanguage] = []
    var translationEnabled = false
    var targetLanguage = DictationLanguage.englishUS
    var recentLanguages: [DictationLanguage] = []
    var overlay: KeyboardOverlay?
    /// Recent mic levels for the waveform, oldest first.
    var levels: [Double] = Array(repeating: 0.06, count: 30)
    /// Debug builds: the extension's memory, shown in the toolbar.
    var debugMemory: String?
    /// The voice keyboard is up: its toolbar has Delete where the key layouts have the mic.
    var showsVoicePad = false
    /// Landscape: a shorter toolbar and a smaller talk button.
    var compactHeight = false
    /// Words in the last dictation, while it can still be undone.
    var undoableWords: Int?
    /// A vibration will say when the text is ready, so the pad's hint can promise it.
    var announcesReady = false
    /// The ☰ menu's switches, mirrored from `SharedSettings` when the keyboard appears.
    var keyboardFeedback = true
    var readyHaptic = true
    var interactionSounds = true
    var appearance = KeyboardAppearancePreference.automatic
    /// The ☰ menu's "Add to dictionary": the selected word, or the one before the cursor.
    var dictionaryCandidate: String?
    /// The word just added, for the row's confirmation.
    var addedToDictionary: String?

    @ObservationIgnored var actions = Actions()

    struct Actions {
        var mic: () -> Void = {}
        var stop: () -> Void = {}
        var cancel: () -> Void = {}
        var insertPending: () -> Void = {}
        var dismissPending: () -> Void = {}
        var dismissNotice: () -> Void = {}
        var openApp: () -> Void = {}
        /// The limit card's way to Murmur Pro's plans in the app.
        var openPro: () -> Void = {}
        /// "You are logged out"'s Log in: Murmur's sign-in.
        var logIn: () -> Void = {}
        var setStyle: (StylePreset) -> Void = { _ in }
        var setLanguage: (DictationLanguage?) -> Void = { _ in }
        var showOverlay: (KeyboardOverlay) -> Void = { _ in }
        var hideOverlay: () -> Void = {}
        /// The menu's ABC: the keyboard's own letters.
        var showLetters: () -> Void = {}
        var setTranslationEnabled: (Bool) -> Void = { _ in }
        var setTargetLanguage: (DictationLanguage) -> Void = { _ in }
        var swapLanguages: () -> Void = {}
        var setKeyboardFeedback: (Bool) -> Void = { _ in }
        var setReadyHaptic: (Bool) -> Void = { _ in }
        var setInteractionSounds: (Bool) -> Void = { _ in }
        var setAppearance: (KeyboardAppearancePreference) -> Void = { _ in }
        var addToDictionary: (String) -> Void = { _ in }
        var deleteDown: () -> Void = {}
        var deleteUp: () -> Void = {}
        var deleteWord: () -> Void = {}
        var returnKey: () -> Void = {}
        var undo: () -> Void = {}
        var moveCursor: (Int) -> Void = { _ in }
    }

    var isCapturing: Bool {
        switch phase {
        case .listening, .processing: true
        default: false
        }
    }

    var isProcessing: Bool {
        if case .processing = phase { true } else { false }
    }

    /// Session options are captured when dictation starts, so keep them stable until that run ends.
    var locksSessionOptions: Bool {
        switch phase {
        case .openingApp, .starting, .listening, .processing: true
        default: false
        }
    }

    var isTransitioning: Bool {
        switch phase {
        case .openingApp, .starting, .processing: true
        default: false
        }
    }

    var listeningSince: Date? {
        if case .listening(_, let since) = phase { since } else { nil }
    }

    var effectiveLanguage: DictationLanguage { languageOverride ?? primaryLanguage }

    /// The app runs a session, so the mic dictates without opening it first.
    var isSessionLive: Bool { sessionStatus.isLive }

    var languageChoices: [DictationLanguage] {
        let preferred = spokenLanguages + [primaryLanguage] + (secondaryLanguage.map { [$0] } ?? [])
            + recentLanguages + DictationLanguage.cloudLanguagesByName
        return [DictationLanguage.automatic] + preferred.uniqued(by: \DictationLanguage.languageCode)
    }

    var targetLanguageChoices: [DictationLanguage] {
        (recentLanguages + spokenLanguages + [primaryLanguage] + DictationLanguage.cloudLanguagesByName)
            .filter { !$0.isAutomatic && $0.languageCode != effectiveLanguage.languageCode }
            .uniqued(by: \DictationLanguage.languageCode)
    }

    /// The first line under the talk button while a dictation runs.
    var captionTitle: String {
        if isProcessing { return translationEnabled ? "Translating…" : "Writing…" }
        return "Listening"
    }

    /// The second line: what this dictation will do. The options are locked while it runs, so
    /// they are the ones it started with.
    var captionDetail: String {
        if isProcessing, announcesReady { return "You’ll feel a tap when it’s ready" }
        guard translationEnabled else { return style.title }
        if effectiveLanguage.isAutomatic { return "Into \(targetLanguage.localizedName)" }
        return "\(effectiveLanguage.localizedName) → \(targetLanguage.localizedName)"
    }

    func update(from client: KeyboardSessionClient) {
        phase = client.phase
        sessionStatus = client.sessionStatus
        pendingResult = client.pendingResult
        if case .listening = client.phase {
            levels.removeFirst()
            levels.append(min(1, max(0.06, client.level)))
        } else if levels.contains(where: { $0 > 0.06 }) {
            levels = Array(repeating: 0.06, count: levels.count)
        }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by keyPath: KeyPath<Element, Key>) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
