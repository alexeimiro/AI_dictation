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
    var debugMemory: String?
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

    var listeningSince: Date? {
        if case .listening(_, let since) = phase { since } else { nil }
    }

    var effectiveStyle: StylePreset { styleOverride ?? defaultStyle }

    var effectiveLanguage: DictationLanguage { languageOverride ?? primaryLanguage }

    var languageChoices: [DictationLanguage] {
        let preferred = [primaryLanguage] + (secondaryLanguage.map { [$0] } ?? [])
            + recentLanguages + Self.commonLanguages
        return [DictationLanguage.automatic] + preferred.uniqued(by: \DictationLanguage.languageCode)
    }

    var targetLanguageChoices: [DictationLanguage] {
        (recentLanguages + Self.commonLanguages + [primaryLanguage])
            .filter { !$0.isAutomatic && $0.languageCode != effectiveLanguage.languageCode }
            .uniqued(by: \DictationLanguage.languageCode)
    }

    var languagePillTitle: String {
        translationEnabled ? "\(effectiveLanguage.shortCode) → \(targetLanguage.shortCode)" : effectiveLanguage.shortCode
    }

    var idleHint: String {
        guard translationEnabled else { return "Speak to type" }
        return "Speak \(effectiveLanguage.localizedName) → Type in \(targetLanguage.localizedName)"
    }

    /// A compact, useful target list. Recognition can use these through the cloud even when an
    /// on-device speech model is not installed.
    static let commonLanguages: [DictationLanguage] = [
        "en-US", "ru-RU", "tr-TR", "de-DE", "es-ES", "fr-FR", "it-IT", "pt-BR",
        "pl-PL", "uk-UA", "zh-CN", "ja-JP", "ko-KR", "ar-SA", "hi-IN",
    ].map(DictationLanguage.init(tag:))

    func update(from client: KeyboardSessionClient) {
        phase = client.phase
        sessionStatus = client.sessionStatus
        pendingResult = client.pendingResult
        if case .listening = client.phase {
            levels.removeFirst()
            levels.append(max(0.06, client.level))
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
