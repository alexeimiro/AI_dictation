import AppKit
import ApplicationServices
import AVFoundation

/// The two permissions Murmur for Mac needs: the microphone, and Accessibility, which lets it
/// hear the shortcut in any app and type the text there.
@MainActor
enum MacPermissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompt, which offers to open System Settings.
    static func promptForAccessibility() {
        // kAXTrustedCheckOptionPrompt's value; the global itself isn't concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// What the 🌐/fn key does on its own (Keyboard settings). Anything but "Do Nothing" fires on
    /// each push-to-talk release too: an input-source switch, the emoji picker, Apple's dictation.
    static var globeKeyAction: GlobeKeyAction {
        let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int
        return GlobeKeyAction(rawValue: value ?? 1) ?? .changeInputSource
    }

    enum GlobeKeyAction: Int {
        case doNothing = 0
        case changeInputSource = 1
        case showEmoji = 2
        case startDictation = 3
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
