import Foundation

/// "Turn off after": how long an idle session keeps the microphone ready.
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

    /// Whether the microphone comes back after a call or Siri took it: always with Never, with a
    /// timed option only after an interruption shorter than it, and never with Immediately.
    public func resumesAfterInterruption(lasting duration: TimeInterval) -> Bool {
        switch self {
        case .never: true
        case .immediately: false
        case .oneHour, .fifteenMinutes, .fiveMinutes: duration < (idleTimeout ?? 0)
        }
    }
}

public enum KeyboardLayoutPreference: String, Codable, Sendable, CaseIterable {
    /// Numbers-first layout with a dictation row.
    case numbers
    case qwerty
    /// The voice keyboard (the default): a big talk button, the translate row, space and return.
    /// It can't dictate without Full Access, so the keyboard shows Numbers first until then.
    case voice
}

/// The keyboard's colours: the text field's keyboard appearance, or always light or dark.
public enum KeyboardAppearancePreference: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic
    case light
    case dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
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
        case disableAfter, keyboardLayout, keyboardFullQwerty, keyboardFeedback, readyHaptic, interactionSounds
        case defaultStyle
        case useBuiltInMic, transcriberEngine, liveActivities, transcriptRetention, autoReturn, keepScreenAwake
        case translateInOneRequest, lowDataMode, smartFormatting, keepRecordings, autoOpenNote, aiConsentVersion
        case signedOut
        case primaryLanguage, secondaryLanguage, dictationLanguages, verifiedEngines
        case translationEnabled, translationSourceLanguage, translationTargetLanguage, recentTranslationLanguages
        case lastDetectedLanguage, autoDetectDefaultApplied, keyboardAppearance
        case debugKeyboardPeakFootprint, debugKeyboardDemo, debugKeyboardDemoUntil
        /// Phase 1 single-language setting, migrated into `primaryLanguage`.
        case dictationLocale
    }

    public var disableAfter: DisableAfter {
        get { enumValue(.disableAfter) ?? .fiveMinutes }
        set { defaults.set(newValue.rawValue, forKey: Key.disableAfter.rawValue) }
    }

    public var keyboardLayout: KeyboardLayoutPreference {
        get { enumValue(.keyboardLayout) ?? .voice }
        set { defaults.set(newValue.rawValue, forKey: Key.keyboardLayout.rawValue) }
    }

    /// ABC shows the keyboard's own letters instead of switching to the next keyboard for typing
    /// letters ("Show full QWERTY keyboard"). Off by default.
    public var keyboardFullQwerty: Bool {
        get { bool(.keyboardFullQwerty, default: false) }
        set { defaults.set(newValue, forKey: Key.keyboardFullQwerty.rawValue) }
    }

    /// Set from the keyboard's ☰ menu or the app's Settings.
    public var keyboardAppearance: KeyboardAppearancePreference {
        get { enumValue(.keyboardAppearance) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: Key.keyboardAppearance.rawValue) }
    }

    /// Haptics on key presses (requires Full Access).
    public var keyboardFeedback: Bool {
        get { bool(.keyboardFeedback, default: true) }
        set { defaults.set(newValue, forKey: Key.keyboardFeedback.rawValue) }
    }

    /// A vibration when a dictation's text is ready, so nobody has to watch the screen (requires
    /// Full Access).
    public var readyHaptic: Bool {
        get { bool(.readyHaptic, default: true) }
        set { defaults.set(newValue, forKey: Key.readyHaptic.rawValue) }
    }

    /// Start/stop sounds ("Turning off audio").
    public var interactionSounds: Bool {
        get { bool(.interactionSounds, default: true) }
        set { defaults.set(newValue, forKey: Key.interactionSounds.rawValue) }
    }

    /// Word for word until the user picks Improve my grammar; a style removed in November 2026
    /// reads as Word for word (`StylePreset(stored:)`).
    public var defaultStyle: StylePreset {
        get { defaults.string(forKey: Key.defaultStyle.rawValue).map(StylePreset.init(stored:)) ?? .verbatim }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultStyle.rawValue) }
    }

    /// Prefer the iPhone mic over Bluetooth headsets (keeps AirPods in high-quality mode).
    public var useBuiltInMic: Bool {
        get { bool(.useBuiltInMic, default: true) }
        set { defaults.set(newValue, forKey: Key.useBuiltInMic.rawValue) }
    }

    /// Show the session in a Live Activity (Lock Screen / Dynamic Island). App-only.
    public var liveActivities: Bool {
        get { bool(.liveActivities, default: true) }
        set { defaults.set(newValue, forKey: Key.liveActivities.rawValue) }
    }

    /// After the keyboard opens the app, send the user back to the app they were typing in.
    /// App-only; a switch in Settings, since it relies on a UIKit detail that can change.
    public var autoReturn: Bool {
        get { bool(.autoReturn, default: true) }
        set { defaults.set(newValue, forKey: Key.autoReturn.rawValue) }
    }

    /// The keyboard holds off Auto-Lock while a dictation listens. A switch in Settings, since it
    /// relies on the extension's idle timer, which iOS doesn't document for keyboards.
    public var keepScreenAwake: Bool {
        get { bool(.keepScreenAwake, default: true) }
        set { defaults.set(newValue, forKey: Key.keepScreenAwake.rawValue) }
    }

    /// Translate, or improve the grammar of, a cloud dictation in one `dictate` request instead of
    /// `transcribe` then `cleanup`. App-only; a Debug switch, to compare the two in one build.
    public var translateInOneRequest: Bool {
        get { bool(.translateInOneRequest, default: true) }
        set { defaults.set(newValue, forKey: Key.translateInOneRequest.rawValue) }
    }

    /// "Low data mode": dictations upload half the audio bitrate and skip the warm-up requests
    /// while the user speaks. App-only. iOS's own Low Data Mode does the same while it's on.
    public var lowDataMode: Bool {
        get { bool(.lowDataMode, default: false) }
        set { defaults.set(newValue, forKey: Key.lowDataMode.rawValue) }
    }

    /// "Smart formatting": a Word for word dictation drops "um" and "uh", and spoken commands
    /// ("new line", "comma", "at gmail dot com") become what they say. Off, it goes in as
    /// recognized, with only the dictionary and snippets applied. App-only.
    public var smartFormatting: Bool {
        get { bool(.smartFormatting, default: true) }
        set { defaults.set(newValue, forKey: Key.smartFormatting.rawValue) }
    }

    /// Keep each dictation's audio on this iPhone, for playback on its transcript. App-only.
    public var keepRecordings: Bool {
        get { bool(.keepRecordings, default: true) }
        set { defaults.set(newValue, forKey: Key.keepRecordings.rawValue) }
    }

    /// "Auto open note": opening Murmur starts a new note. App-only.
    public var autoOpenNote: Bool {
        get { bool(.autoOpenNote, default: false) }
        set { defaults.set(newValue, forKey: Key.autoOpenNote.rawValue) }
    }

    /// Which wording of "your recordings go to OpenAI and Anthropic" the user agreed to; 0 until
    /// they have, and again after they take it back. The app starts no session below its current
    /// version (`AIConsent`). App-only.
    public var aiConsentVersion: Int {
        get { defaults.integer(forKey: Key.aiConsentVersion.rawValue) }
        set { defaults.set(newValue, forKey: Key.aiConsentVersion.rawValue) }
    }

    /// Nobody is signed in to Murmur, as the app last said: the keyboard then shows only "You are
    /// logged out" and a way to the app's sign-in. Written by the app at launch, whenever the
    /// account changes and whenever it comes to the front. False until the app says so, so an
    /// update keeps the keyboard working until Murmur next runs, which is before any dictation.
    public var signedOut: Bool {
        get { bool(.signedOut, default: false) }
        set { defaults.set(newValue, forKey: Key.signedOut.rawValue) }
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

    /// The languages the user speaks, from Settings › Languages, as BCP-47 tags in the order
    /// picked. Empty means Auto-detect: the cloud listens for any language. Otherwise a dictation
    /// whose Speak language is Auto is recognized as one of these.
    public var dictationLanguages: [String] {
        get { defaults.stringArray(forKey: Key.dictationLanguages.rawValue) ?? [] }
        set {
            let tags = newValue.map(DictationLanguage.normalize).uniqued(by: { DictationLanguage(tag: $0).languageCode })
            if tags.isEmpty {
                defaults.removeObject(forKey: Key.dictationLanguages.rawValue)
            } else {
                defaults.set(tags, forKey: Key.dictationLanguages.rawValue)
            }
        }
    }

    /// Translation is deliberately independent from the writing style.
    public var translationEnabled: Bool {
        get { bool(.translationEnabled, default: false) }
        set { defaults.set(newValue, forKey: Key.translationEnabled.rawValue) }
    }

    /// The source selected from the keyboard. `und` requests cloud language auto-detection.
    public var translationSourceLanguage: String? {
        get { defaults.string(forKey: Key.translationSourceLanguage.rawValue) }
        set { setString(newValue.map(DictationLanguage.normalize), for: .translationSourceLanguage) }
    }

    /// Set once the keyboard first ran with Auto-detect as the default Speak language (November
    /// 2026). A source saved before then was the old default, not the user's pick, and is dropped.
    public var autoDetectDefaultApplied: Bool {
        get { bool(.autoDetectDefaultApplied, default: false) }
        set { defaults.set(newValue, forKey: Key.autoDetectDefaultApplied.rawValue) }
    }

    /// The language that translated text is inserted in.
    public var translationTargetLanguage: String? {
        get { defaults.string(forKey: Key.translationTargetLanguage.rawValue) }
        set { setString(newValue.map(DictationLanguage.normalize), for: .translationTargetLanguage) }
    }

    /// The language the last Auto-detect dictation turned out to be in (BCP-47), so the on-device
    /// fallback can guess it when the cloud doesn't answer. App-only.
    public var lastDetectedLanguage: String? {
        get { defaults.string(forKey: Key.lastDetectedLanguage.rawValue) }
        set { setString(newValue.map(DictationLanguage.normalize), for: .lastDetectedLanguage) }
    }

    /// Most-recently-used source/target tags, newest first.
    public var recentTranslationLanguages: [String] {
        get {
            guard let data = defaults.data(forKey: Key.recentTranslationLanguages.rawValue) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            let tags = Array(newValue.map(DictationLanguage.normalize).uniqued().prefix(6))
            if let data = try? JSONEncoder().encode(tags) {
                defaults.set(data, forKey: Key.recentTranslationLanguages.rawValue)
            }
        }
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

    /// Debug: the keyboard's largest memory footprint so far, in bytes. Debug builds of the
    /// keyboard raise it; the app's Debug screen shows it and resets it to 0.
    public var debugKeyboardPeakFootprint: Int {
        get { defaults.integer(forKey: Key.debugKeyboardPeakFootprint.rawValue) }
        set { defaults.set(newValue, forKey: Key.debugKeyboardPeakFootprint.rawValue) }
    }

    /// Debug: a state Debug builds of the keyboard show instead of the live one (`KeyboardDemo`),
    /// set by the app's `-keyboard-demo` argument or its Debug screen. It lapses after
    /// `keyboardDemoLifetime`, so a forgotten demo can't freeze the keyboard on a phone.
    public var debugKeyboardDemo: KeyboardDemo? {
        get {
            guard let until = defaults.object(forKey: Key.debugKeyboardDemoUntil.rawValue) as? Date,
                  until > Date() else { return nil }
            return defaults.string(forKey: Key.debugKeyboardDemo.rawValue).flatMap(KeyboardDemo.init)
        }
        set {
            setString(newValue?.value, for: .debugKeyboardDemo)
            if newValue != nil {
                defaults.set(Date().addingTimeInterval(Self.keyboardDemoLifetime),
                             forKey: Key.debugKeyboardDemoUntil.rawValue)
            } else {
                defaults.removeObject(forKey: Key.debugKeyboardDemoUntil.rawValue)
            }
        }
    }

    public static let keyboardDemoLifetime: TimeInterval = 15 * 60

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

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }

    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}
