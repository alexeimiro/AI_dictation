import UIKit

/// Keeps the screen on while a dictation listens, so Auto-Lock doesn't cut a long one. The idle
/// timer belongs to the extension's application object, reached on the responder chain as
/// `HostAppOpener` does. Whether iOS honours it for a keyboard isn't documented, so it is checked
/// on the iPhone and can be switched off in Murmur's Settings (`keepScreenAwake`).
@MainActor
enum ScreenWake {
    static func keepAwake(_ awake: Bool, from responder: UIResponder) {
        guard let application = HostAppOpener.application(from: responder),
              application.isIdleTimerDisabled != awake else { return }
        application.isIdleTimerDisabled = awake
    }
}
