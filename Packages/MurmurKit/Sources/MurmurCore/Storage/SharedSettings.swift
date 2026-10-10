import Foundation

/// "Disable Murmur after" — how long an idle session keeps the microphone ready.
public enum DisableAfter: String, Codable, Sendable, CaseIterable, Identifiable {
    case never
    case oneHour
    case fifteenMinutes
    case fiveMinutes
    case immediately

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never: "Never"
        case .oneHour: "1 hour"
        case .fifteenMinutes: "15 minutes"
        case .fiveMinutes: "5 minutes"
        case .immediately: "Immediately"
        }
    }

    /// Idle time before the session ends; nil means never, 0 means right after a dictation.
    public var idleTimeout: TimeInterval? {
        switch self {
        case .never: nil
        case .oneHour: 3600
        case .fifteenMinutes: 900
        case .fiveMinutes: 300
        case .immediately: 0
        }
    }
}

public enum KeyboardLayoutPreference: String, Codable, Sendable, CaseIterable {
    /// Numbers-first layout with a dictation row (the default, like Wispr Flow).
    case numbers
    case qwerty
}

/// Which on-device recognizer passed validation for a language on this device, so the check isn't
/// repeated at every session start.
public struct VerifiedEngineRecord: Codable, Sendable, Equatable {
    /// "speech" (SpeechTranscriber) or "dictation" (DictationTranscriber).
    public var engine: String
    public var osVersion: String
    public var verifiedAt: Date

    public init(engine: String, osVersion: String, verifiedAt: Date) {
        self.engine = engine
        self.osVersion = osVersion
        self.verifiedAt = verifiedAt
    }
}

/// Settings shared between the app and the keyboard via App Group `UserDefaults`.
/// These change rarely; fast-changing state goes through `HotState` instead.
public final class SharedSettings: @unchecked Sendable {
    public static let shared = SharedSettings()

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = UserDefaults(suiteName: Brand.appGroupID)) {
        self.defaults = defaults ?? .standard
    }

    private enum Key: String {
        case disableAfter, keyboardLayout, keyboardFeedback, interactionSounds, defaultStyle
        case useBuiltInMic, aiCleanupEnabled, transcriberEngine, liveActivities, transcriptRetention
        case primaryLanguage, secondaryLanguage, verifiedEngines
        /// Phase 1 single-language setting, migrated into `primaryLanguage`.
        case dictationLocale
    }

    public var disableAfter: DisableAfter {
        get { enumValue(.disableAfter) ?? .fiveMinutes }
        set { defaults.set(newValue.rawValue, forKey: Key.disableAfter.rawValue) }
    }

    public var keyboardLayout: KeyboardLayoutPreference {
        get { enumValue(.keyboardLayout) ?? .numbers }
        set { defaults.set(newValue.rawValue, forKey: Key.keyboardLayout.rawValue) }
    }

    /// Haptics on key presses (requires Full Access).
    public var keyboardFeedback: Bool {
        get { bool(.keyboardFeedback, default: true) }
        set { defaults.set(newValue, forKey: Key.keyboardFeedback.rawValue) }
    }

    /// Start/stop sounds ("Turning off audio").
    public var interactionSounds: Bool {
        get { bool(.interactionSounds, default: true) }
        set { defaults.set(newValue, forKey: Key.interactionSounds.rawValue) }
    }

    public var defaultStyle: StylePreset {
        get { enumValue(.defaultStyle) ?? .casual }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultStyle.rawValue) }
    }

    /// Prefer the iPhone mic over Bluetooth headsets (keeps AirPods in high-quality mode).
    public var useBuiltInMic: Bool {
        get { bool(.useBuiltInMic, default: true) }
        set { defaults.set(newValue, forKey: Key.useBuiltInMic.rawValue) }
    }

    public var aiCleanupEnabled: Bool {
        get { bool(.aiCleanupEnabled, default: true) }
        set { defaults.set(newValue, forKey: Key.aiCleanupEnabled.rawValue) }
    }

    /// Show the session in a Live Activity (Lock Screen / Dynamic Island). App-only.
    public var liveActivities: Bool {
        get { bool(.liveActivities, default: true) }
        set { defaults.set(newValue, forKey: Key.liveActivities.rawValue) }
    }

    /// Auto-delete transcripts older than this. App-only; applied by the history store.
    public var transcriptRetention: TranscriptRetention {
        get { enumValue(.transcriptRetention) ?? .month }
        set { defaults.set(newValue.rawValue, forKey: Key.transcriptRetention.rawValue) }
    }

    /// BCP-47 tag of the main dictation language. Nil until one is chosen or resolved from the
    /// device's preferred languages; the app persists the resolved value so the keyboard sees it.
    public var primaryLanguage: String? {
        get {
            if let tag = defaults.string(forKey: Key.primaryLanguage.rawValue) { return tag }
            guard let legacy = defaults.string(forKey: Key.dictationLocale.rawValue) else { return nil }
            let tag = DictationLanguage.normalize(legacy)
            defaults.set(tag, forKey: Key.primaryLanguage.rawValue)
            defaults.removeObject(forKey: Key.dictationLocale.rawValue)
            return tag
        }
        set { setString(newValue.map(DictationLanguage.normalize), for: .primaryLanguage) }
    }

    /// Optional second language, switchable per dictation from the keyboard's language pill.
    public var secondaryLanguage: String? {
        get { defaults.string(forKey: Key.secondaryLanguage.rawValue) }
        set { setString(newValue.map(DictationLanguage.normalize), for: .secondaryLanguage) }
    }

    /// Per-language record of the engine that passed validation on this device, keyed by tag.
    public var verifiedEngines: [String: VerifiedEngineRecord] {
        get {
            guard let data = defaults.data(forKey: Key.verifiedEngines.rawValue) else { return [:] }
            return (try? JSONDecoder().decode([String: VerifiedEngineRecord].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.verifiedEngines.rawValue)
            } else {
                defaults.removeObject(forKey: Key.verifiedEngines.rawValue)
            }
        }
    }

    /// Debug: force an on-device recognizer; nil means automatic per language.
    public var transcriberEngine: String? {
        get { defaults.string(forKey: Key.transcriberEngine.rawValue) }
        set { setString(newValue, for: .transcriberEngine) }
    }

    private func bool(_ key: Key, default value: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? value
    }

    private func enumValue<T: RawRepresentable>(_ key: Key) -> T? where T.RawValue == String {
        defaults.string(forKey: key.rawValue).flatMap(T.init(rawValue:))
    }

    private func setString(_ value: String?, for key: Key) {
        if let value {
            defaults.set(value, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
