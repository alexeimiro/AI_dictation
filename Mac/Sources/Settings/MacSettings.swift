import AppKit
import CoreAudio
import MurmurCore
import ServiceManagement

/// The Mac's own settings (the shortcut, the bar, the microphone, launch at login), beside the
/// shared ones (`SharedSettings`: style, languages, sounds, AI consent).
@MainActor
@Observable
final class MacSettings {
    /// The key held to talk. Modifier keys only, so holding one never types anything.
    enum TriggerKey: String, CaseIterable, Identifiable {
        case function, rightOption, rightCommand, rightControl
        var id: String { rawValue }

        var keyCode: Int64 {
            switch self {
            case .function: 63
            case .rightOption: 61
            case .rightCommand: 54
            case .rightControl: 62
            }
        }

        /// The device-dependent flag that's set while this very key (not its left twin) is down.
        var deviceMask: UInt64 {
            switch self {
            case .function: CGEventFlags.maskSecondaryFn.rawValue
            case .rightOption: 0x40
            case .rightCommand: 0x10
            case .rightControl: 0x2000
            }
        }

        /// As the keycaps show it: "fn", "Right ⌥".
        var caps: [String] {
            switch self {
            case .function: ["fn"]
            case .rightOption: ["Right", "⌥"]
            case .rightCommand: ["Right", "⌘"]
            case .rightControl: ["Right", "⌃"]
            }
        }

        var name: String {
            switch self {
            case .function: "fn (Globe)"
            case .rightOption: "Right Option"
            case .rightCommand: "Right Command"
            case .rightControl: "Right Control"
            }
        }

        init?(keyCode: Int64) {
            guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
            self = key
        }
    }

    static let shared = MacSettings()
    private let defaults = UserDefaults.standard

    var trigger: TriggerKey {
        didSet { defaults.set(trigger.rawValue, forKey: "macTriggerKey") }
    }
    var handsFree: Bool {
        didSet { defaults.set(handsFree, forKey: "macHandsFree") }
    }
    var pasteLastShortcut: Bool {
        didSet { defaults.set(pasteLastShortcut, forKey: "macPasteLast") }
    }
    var showFloatingBar: Bool {
        didSet { defaults.set(showFloatingBar, forKey: "macShowFloatingBar") }
    }
    /// The microphone to record from (its Core Audio UID); nil follows the system's input.
    var microphoneUID: String? {
        didSet { defaults.set(microphoneUID, forKey: "macMicrophoneUID") }
    }
    var sounds: Bool {
        get { access(keyPath: \.sounds); return SharedSettings.shared.interactionSounds }
        set { withMutation(keyPath: \.sounds) { SharedSettings.shared.interactionSounds = newValue } }
    }
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private init() {
        trigger = TriggerKey(rawValue: defaults.string(forKey: "macTriggerKey") ?? "") ?? .function
        handsFree = defaults.object(forKey: "macHandsFree") as? Bool ?? true
        pasteLastShortcut = defaults.object(forKey: "macPasteLast") as? Bool ?? true
        showFloatingBar = defaults.object(forKey: "macShowFloatingBar") as? Bool ?? true
        microphoneUID = defaults.string(forKey: "macMicrophoneUID")
    }

    /// Registers or removes Murmur as a login item. False when macOS refused (the user can
    /// still add it in System Settings › General › Login Items).
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return false
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        return true
    }
}

/// The Mac's microphones, from Core Audio.
enum AudioInputs {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func device(uid: String) -> Device? { all().first { $0.uid == uid } }

    static var defaultInputName: String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let buffers = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffers.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffers) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(buffers.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
