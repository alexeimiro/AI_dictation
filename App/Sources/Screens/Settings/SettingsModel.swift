import Foundation
import MurmurCore
import Observation

/// Observable mirror of `SharedSettings` with write-through, so SwiftUI controls can bind to it.
@MainActor
@Observable
final class SettingsModel {
    var disableAfter: DisableAfter { didSet { settings.disableAfter = disableAfter } }
    var keyboardLayout: KeyboardLayoutPreference { didSet { settings.keyboardLayout = keyboardLayout } }
    var keyboardFullQwerty: Bool { didSet { settings.keyboardFullQwerty = keyboardFullQwerty } }
    var keyboardAppearance: KeyboardAppearancePreference {
        didSet { settings.keyboardAppearance = keyboardAppearance }
    }
    var keyboardFeedback: Bool { didSet { settings.keyboardFeedback = keyboardFeedback } }
    var readyHaptic: Bool { didSet { settings.readyHaptic = readyHaptic } }
    var interactionSounds: Bool { didSet { settings.interactionSounds = interactionSounds } }
    var defaultStyle: StylePreset { didSet { settings.defaultStyle = defaultStyle } }
    var useBuiltInMic: Bool { didSet { settings.useBuiltInMic = useBuiltInMic } }
    var liveActivities: Bool { didSet { settings.liveActivities = liveActivities } }
    var transcriptRetention: TranscriptRetention {
        didSet {
            settings.transcriptRetention = transcriptRetention
            onRetentionChange?()
        }
    }
    var transcriberEngine: TranscriberEngine {
        didSet { settings.transcriberEngine = transcriberEngine == .auto ? nil : transcriberEngine.rawValue }
    }
    var autoReturn: Bool { didSet { settings.autoReturn = autoReturn } }
    var keepScreenAwake: Bool { didSet { settings.keepScreenAwake = keepScreenAwake } }
    var translateInOneRequest: Bool { didSet { settings.translateInOneRequest = translateInOneRequest } }
    var lowDataMode: Bool { didSet { settings.lowDataMode = lowDataMode } }
    var smartFormatting: Bool { didSet { settings.smartFormatting = smartFormatting } }
    var keepRecordings: Bool { didSet { settings.keepRecordings = keepRecordings } }
    var autoOpenNote: Bool { didSet { settings.autoOpenNote = autoOpenNote } }
    /// Settings › Languages: the languages the user speaks, in the order picked; empty is Auto-detect.
    var dictationLanguages: [String] { didSet { settings.dictationLanguages = dictationLanguages } }

    @ObservationIgnored private let settings: SharedSettings
    @ObservationIgnored var onRetentionChange: (() -> Void)?

    init(settings: SharedSettings = .shared) {
        self.settings = settings
        disableAfter = settings.disableAfter
        keyboardLayout = settings.keyboardLayout
        keyboardFullQwerty = settings.keyboardFullQwerty
        keyboardAppearance = settings.keyboardAppearance
        keyboardFeedback = settings.keyboardFeedback
        readyHaptic = settings.readyHaptic
        interactionSounds = settings.interactionSounds
        defaultStyle = settings.defaultStyle
        useBuiltInMic = settings.useBuiltInMic
        liveActivities = settings.liveActivities
        transcriptRetention = settings.transcriptRetention
        transcriberEngine = TranscriberEngine.current
        autoReturn = settings.autoReturn
        keepScreenAwake = settings.keepScreenAwake
        translateInOneRequest = settings.translateInOneRequest
        dictationLanguages = settings.dictationLanguages
        lowDataMode = settings.lowDataMode
        smartFormatting = settings.smartFormatting
        keepRecordings = settings.keepRecordings
        autoOpenNote = settings.autoOpenNote
    }

    /// Picks `tag`, or unpicks the language it's a variant of.
    func toggleDictationLanguage(_ tag: String) {
        let code = DictationLanguage(tag: tag).languageCode
        if dictationLanguages.contains(where: { DictationLanguage(tag: $0).languageCode == code }) {
            dictationLanguages.removeAll { DictationLanguage(tag: $0).languageCode == code }
        } else {
            dictationLanguages.append(tag)
        }
    }

    /// The keyboard changes these while the app waits in the background: the style pill sets the
    /// default style, and its ☰ menu the feedback and the appearance.
    func reloadFromKeyboard() {
        if defaultStyle != settings.defaultStyle { defaultStyle = settings.defaultStyle }
        if keyboardFeedback != settings.keyboardFeedback { keyboardFeedback = settings.keyboardFeedback }
        if readyHaptic != settings.readyHaptic { readyHaptic = settings.readyHaptic }
        if interactionSounds != settings.interactionSounds { interactionSounds = settings.interactionSounds }
        if keyboardAppearance != settings.keyboardAppearance { keyboardAppearance = settings.keyboardAppearance }
    }
}
