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
        case useBuiltInMic, aiCleanupEnabled, dictationLocale, transcriberEngine
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

    /// BCP-47 identifier of the dictation language, or nil for the device language.
    public var dictationLocale: String? {
        get { defaults.string(forKey: Key.dictationLocale.rawValue) }
        set { defaults.set(newValue, forKey: Key.dictationLocale.rawValue) }
    }

    /// Debug: which on-device recognizer to use (see the Phase 1b spike).
    public var transcriberEngine: String? {
        get { defaults.string(forKey: Key.transcriberEngine.rawValue) }
        set { defaults.set(newValue, forKey: Key.transcriberEngine.rawValue) }
    }

    private func bool(_ key: Key, default value: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? value
    }

    private func enumValue<T: RawRepresentable>(_ key: Key) -> T? where T.RawValue == String {
        defaults.string(forKey: key.rawValue).flatMap(T.init(rawValue:))
    }
}
