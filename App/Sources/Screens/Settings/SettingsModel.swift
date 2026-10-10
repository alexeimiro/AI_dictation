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

    @ObservationIgnored private let settings: SharedSettings
    @ObservationIgnored var onRetentionChange: (() -> Void)?

    init(settings: SharedSettings = .shared) {
        self.settings = settings
        disableAfter = settings.disableAfter
        keyboardLayout = settings.keyboardLayout
        keyboardFeedback = settings.keyboardFeedback
        interactionSounds = settings.interactionSounds
        defaultStyle = settings.defaultStyle
        useBuiltInMic = settings.useBuiltInMic
        aiCleanupEnabled = settings.aiCleanupEnabled
        liveActivities = settings.liveActivities
        transcriptRetention = settings.transcriptRetention
        transcriberEngine = TranscriberEngine.current
    }
}
