import AVFoundation
import Foundation
import MurmurCore
import Observation
import UIKit

/// What the keyboard setup still needs. Re-checked whenever the app becomes active, because the
/// user flips these switches in the Settings app.
@MainActor
@Observable
final class SetupStatus {
    private(set) var keyboardAdded = false
    /// True once the keyboard has written to the App Group, which only works with Full Access.
    /// A missing value means "unknown or off".
    private(set) var fullAccessConfirmed = false
    private(set) var microphone: AVAudioApplication.recordPermission = .undetermined

    @ObservationIgnored private let payloads: IPCPayloadStore

    init(payloads: IPCPayloadStore) {
        self.payloads = payloads
        refresh()
    }

    var isComplete: Bool {
        keyboardAdded && fullAccessConfirmed && microphone == .granted
    }

    func refresh() {
        keyboardAdded = Self.isKeyboardAdded()
        fullAccessConfirmed = payloads.readKeyboardStatus()?.fullAccessAt != nil
        microphone = AVAudioApplication.shared.recordPermission
        // Turning on Full Access can relaunch the app, and the keyboard writes its status
        // asynchronously, so check again shortly after becoming active.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            self.keyboardAdded = Self.isKeyboardAdded()
            self.fullAccessConfirmed = self.payloads.readKeyboardStatus()?.fullAccessAt != nil
        }
    }

    func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
        microphone = AVAudioApplication.shared.recordPermission
    }

    /// Settings › Murmur, which has the Keyboards row (Murmur, Allow Full Access).
    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// Uses the undocumented `identifier` of active input modes — best effort only.
    private static func isKeyboardAdded() -> Bool {
        guard let appID = Bundle.main.bundleIdentifier else { return false }
        let keyboardID = appID + ".keyboard"
        let selector = NSSelectorFromString("identifier")
        return UITextInputMode.activeInputModes.contains { mode in
            guard mode.responds(to: selector) else { return false }
            return (mode.value(forKey: "identifier") as? String)?.hasPrefix(keyboardID) == true
        }
    }
}
