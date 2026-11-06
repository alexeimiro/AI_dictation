import MurmurCore
import Observation
import SwiftUI

/// Observable state behind the SwiftUI parts of the keyboard (toolbar, listening panel).
@MainActor
@Observable
final class KeyboardModel {
    var phase: KeyboardSessionClient.Phase = .idle
    var sessionStatus: SessionStatus = .off
    var pendingResult: DictationResult?
    var hasFullAccess = false
    var styleOverride: StylePreset?
    var defaultStyle: StylePreset = .casual
    var primaryLanguage = DictationLanguage.englishUS
    /// Set only when a verified secondary language exists; shows the language pill.
    var secondaryLanguage: DictationLanguage?
    var languageOverride: DictationLanguage?
    var translationEnabled = false
    var targetLanguage = DictationLanguage.englishUS
    var recentLanguages: [DictationLanguage] = []
    var showsLanguageSelector = false
    /// Recent mic levels for the waveform, oldest first.
    var levels: [Double] = Array(repeating: 0.06, count: 30)
    /// The voice layout's pad is up; the toolbar drops its mic, since the pad has the big one.
    var showsVoicePad = false
    /// The field's return key title ("return", "send", …), for the pad's return button.
    var returnTitle = "return"
    /// Words in the last dictation, while it can still be undone.
    var undoableWords: Int?
    /// A vibration will say when the text is ready, so the pad's hint can promise it.
    var announcesReady = false

    @ObservationIgnored var actions = Actions()

    struct Actions {
        var mic: () -> Void = {}
        var stop: () -> Void = {}
        var cancel: () -> Void = {}
        var insertPending: () -> Void = {}
        var dismissPending: () -> Void = {}
        var dismissNotice: () -> Void = {}
        var openApp: () -> Void = {}
        var setStyle: (StylePreset?) -> Void = { _ in }
        var setLanguage: (DictationLanguage?) -> Void = { _ in }
        var showLanguageSelector: () -> Void = {}
        var hideLanguageSelector: () -> Void = {}
        var setTranslationEnabled: (Bool) -> Void = { _ in }
        var setTargetLanguage: (DictationLanguage) -> Void = { _ in }
        var swapLanguages: () -> Void = {}
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

    var effectiveStyle: StylePreset { styleOverride ?? defaultStyle }

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

    /// Kept compact enough for the keyboard while making it clear which language the recognizer
    /// is listening for. In translation mode the output language is shown too, so a user can
    /// catch a reversed language pair before finishing the dictation.
    var recognitionDirection: String {
        translationEnabled
            ? "\(effectiveLanguage.shortCode) → \(targetLanguage.shortCode)"
            : effectiveLanguage.shortCode
    }

    var idleHint: String {
        guard translationEnabled else { return "Speak to type" }
        return "Speak \(effectiveLanguage.localizedName) → Type in \(targetLanguage.localizedName)"
    }

    /// Every language OpenAI's speech-to-text and GPT translation support (the Whisper language
    /// list). Recognition reaches them through the cloud even when no on-device speech model is
    /// installed. English stays first: it is the fallback target. Menus show `menuLanguages`.
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
