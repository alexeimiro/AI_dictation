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
    /// Recent mic levels for the waveform, oldest first.
    var levels: [Double] = Array(repeating: 0.06, count: 30)
    var debugMemory: String?

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
    }

    var isCapturing: Bool {
        switch phase {
        case .listening, .processing: true
        default: false
        }
    }

    var listeningSince: Date? {
        if case .listening(_, let since) = phase { since } else { nil }
    }

    var effectiveStyle: StylePreset { styleOverride ?? defaultStyle }

    var effectiveLanguage: DictationLanguage { languageOverride ?? primaryLanguage }

    var languageChoices: [DictationLanguage] {
        [primaryLanguage] + (secondaryLanguage.map { [$0] } ?? [])
    }

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
