import Foundation
import MurmurCore
import Observation

/// Observable mirror of `SharedSettings` with write-through, so SwiftUI controls can bind to it.
@MainActor
@Observable
final class SettingsModel {
    var disableAfter: DisableAfter { didSet { settings.disableAfter = disableAfter } }
    var keyboardLayout: KeyboardLayoutPreference { didSet { settings.keyboardLayout = keyboardLayout } }
    var keyboardFeedback: Bool { didSet { settings.keyboardFeedback = keyboardFeedback } }
    var readyHaptic: Bool { didSet { settings.readyHaptic = readyHaptic } }
    var interactionSounds: Bool { didSet { settings.interactionSounds = interactionSounds } }
    var defaultStyle: StylePreset { didSet { settings.defaultStyle = defaultStyle } }
    var useBuiltInMic: Bool { didSet { settings.useBuiltInMic = useBuiltInMic } }
    var aiCleanupEnabled: Bool { didSet { settings.aiCleanupEnabled = aiCleanupEnabled } }
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
    var translateInOneRequest: Bool { didSet { settings.translateInOneRequest = translateInOneRequest } }

    @ObservationIgnored private let settings: SharedSettings
    @ObservationIgnored var onRetentionChange: (() -> Void)?

    init(settings: SharedSettings = .shared) {
        self.settings = settings
        disableAfter = settings.disableAfter
        keyboardLayout = settings.keyboardLayout
        keyboardFeedback = settings.keyboardFeedback
        readyHaptic = settings.readyHaptic
        interactionSounds = settings.interactionSounds
        defaultStyle = settings.defaultStyle
        useBuiltInMic = settings.useBuiltInMic
        aiCleanupEnabled = settings.aiCleanupEnabled
        liveActivities = settings.liveActivities
        transcriptRetention = settings.transcriptRetention
        transcriberEngine = TranscriberEngine.current
        autoReturn = settings.autoReturn
        translateInOneRequest = settings.translateInOneRequest
    }

    /// The keyboard's style pill changes the default style while the app waits in the background.
    func reloadDefaultStyle() {
        if defaultStyle != settings.defaultStyle { defaultStyle = settings.defaultStyle }
    }
}
