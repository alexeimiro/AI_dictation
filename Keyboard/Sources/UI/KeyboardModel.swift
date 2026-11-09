import MurmurCore
import Observation
import SwiftUI

/// What opens over the keyboard, under the toolbar.
enum KeyboardOverlay {
    case style
    case settings
    /// The language sheet of the key layouts; the voice keyboard has the translate row instead.
    case languages
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
    /// The voice keyboard is up: its toolbar has Delete where the key layouts have the mic and the
    /// language pill.
    var showsVoicePad = false
    /// Landscape: the voice keyboard is as tall as the key layouts, with a smaller talk button.
    var compactHeight = false
    /// The field's return key title ("return", "send", …), for the pad's return button.
    var returnTitle = "return"
    /// Words in the last dictation, while it can still be undone.
    var undoableWords: Int?
    /// A vibration will say when the text is ready, so the pad's hint can promise it.
    var announcesReady = false
    /// The settings sheet's switches, mirrored from `SharedSettings` when the keyboard appears.
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

    var languagePillTitle: String {
        translationEnabled ? "\(effectiveLanguage.shortCode) → \(targetLanguage.shortCode)" : effectiveLanguage.shortCode
    }

    var idleHint: String {
        guard translationEnabled else { return "Speak to type" }
        let spoken = effectiveLanguage.isAutomatic ? "any language" : effectiveLanguage.localizedName
        return "Speak \(spoken) → Type in \(targetLanguage.localizedName)"
    }

    /// After stop, what the dictation is waiting for. The options are locked while it runs, so they
    /// are the ones it started with.
    var stageText: String {
        let stage = translationEnabled ? "Translating to \(targetLanguage.localizedName)" : "Transcribing"
        return announcesReady ? "\(stage) · we'll tap when it's ready" : "\(stage)…"
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
