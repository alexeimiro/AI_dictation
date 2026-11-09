import MurmurCore
import Observation
import SwiftUI

/// A page that takes the place of the pad or the keys under the toolbar, as Wispr Flow's menu does.
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
    /// The app's Default style, which the style pill changes too.
    var style: StylePreset = .verbatim
    var primaryLanguage = DictationLanguage.englishUS
    /// Set only when a verified secondary language exists; shows the language pill.
    var secondaryLanguage: DictationLanguage?
    var languageOverride: DictationLanguage?
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

    @ObservationIgnored var actions = Actions()

    struct Actions {
        var mic: () -> Void = {}
        var stop: () -> Void = {}
        var cancel: () -> Void = {}
        var insertPending: () -> Void = {}
        var dismissPending: () -> Void = {}
        var dismissNotice: () -> Void = {}
        var openApp: () -> Void = {}
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
        let preferred = [primaryLanguage] + (secondaryLanguage.map { [$0] } ?? [])
            + recentLanguages + Self.menuLanguages
        return [DictationLanguage.automatic] + preferred.uniqued(by: \DictationLanguage.languageCode)
    }

    var targetLanguageChoices: [DictationLanguage] {
        (recentLanguages + [primaryLanguage] + Self.menuLanguages)
            .filter { !$0.isAutomatic && $0.languageCode != effectiveLanguage.languageCode }
            .uniqued(by: \DictationLanguage.languageCode)
    }

    /// The first line under the dots while a dictation runs, Wispr's "Listening".
    var captionTitle: String {
        if isProcessing { return translationEnabled ? "Translating…" : "Transcribing…" }
        return "Listening"
    }

    /// The second line: where Wispr names the microphone, what this dictation will do. The options
    /// are locked while it runs, so they are the ones it started with.
    var captionDetail: String {
        if isProcessing, announcesReady { return "We'll tap when it's ready" }
        guard translationEnabled else { return style.title }
        if effectiveLanguage.isAutomatic { return "Into \(targetLanguage.localizedName)" }
        return "\(effectiveLanguage.localizedName) → \(targetLanguage.localizedName)"
    }

    /// Every language OpenAI's speech-to-text and GPT translation support (the Whisper language
    /// list). Recognition reaches them through the cloud even when no on-device speech model is
    /// installed. Menus show `menuLanguages`.
    static let commonLanguages: [DictationLanguage] = [
        "en-US", "af-ZA", "ar-SA", "hy-AM", "az-AZ", "be-BY", "bs-BA", "bg-BG", "ca-ES", "zh-CN",
        "hr-HR", "cs-CZ", "da-DK", "nl-NL", "et-EE", "fi-FI", "fr-FR", "gl-ES", "de-DE", "el-GR",
        "he-IL", "hi-IN", "hu-HU", "is-IS", "id-ID", "it-IT", "ja-JP", "kn-IN", "kk-KZ", "ko-KR",
        "lv-LV", "lt-LT", "mk-MK", "ms-MY", "mr-IN", "mi-NZ", "ne-NP", "nb-NO", "fa-IR", "pl-PL",
        "pt-BR", "ro-RO", "ru-RU", "sr-RS", "sk-SK", "sl-SI", "es-ES", "sw-KE", "sv-SE", "tl-PH",
        "ta-IN", "th-TH", "tr-TR", "uk-UA", "ur-PK", "vi-VN", "cy-GB",
    ].map(DictationLanguage.init(tag:))

    /// `commonLanguages` in alphabetical order of their names in the UI language.
    static let menuLanguages: [DictationLanguage] = commonLanguages.sorted {
        $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
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
