import Foundation

/// When an unused session turns the microphone off ("Disable after"). As in Wispr Flow, the
/// countdown only runs while the app is in the background and the keyboard is off screen, and it
/// starts from whichever came last: the end of the last dictation, the app leaving the screen,
/// or the keyboard leaving it. Typing on the keyboard therefore keeps the session on.
public enum IdleStop {
    /// How long after its last heartbeat a keyboard that never said it was hidden still counts as
    /// on screen. It writes one every `KeyboardSessionClient.visibilityInterval`.
    public static let keyboardGrace: TimeInterval = 12

    /// When to turn the microphone off, or nil while the app is in the foreground (no countdown).
    public static func date(timeout: TimeInterval, idleSince: Date, backgroundSince: Date?,
                            keyboard: KeyboardStatus?) -> Date? {
        guard let backgroundSince else { return nil }
        var start = max(idleSince, backgroundSince)
        if let keyboard { start = max(start, keyboard.inactiveSince) }
        return start.addingTimeInterval(timeout)
    }
}
