import Foundation

/// When an unused session turns the microphone off. Two countdowns run, only while the app is in
/// the background, and the earlier one counts:
///
/// - "Turn off after" runs while the keyboard is off screen, from whichever came last: the end of
///   the last dictation, the app leaving the screen, or the keyboard leaving it. Typing on the
///   keyboard therefore keeps the session on. "Never" has no such countdown.
/// - A locked iPhone can't show the keyboard, so there the microphone goes off `lockTimeout` after
///   the lock, whatever "Turn off after" says, "Never" included. A dictation that ended after the
///   lock, or a keyboard that was on screen after it, starts that minute again.
public enum IdleStop {
    /// How long after its last heartbeat a keyboard that never said it was hidden still counts as
    /// on screen. It writes one every `KeyboardSessionClient.visibilityInterval`.
    public static let keyboardGrace: TimeInterval = 12

    /// How long an unused session keeps the microphone on in a locked iPhone.
    public static let lockTimeout: TimeInterval = 60

    /// When to turn the microphone off, or nil while nothing counts down: the app is in the
    /// foreground, or "Turn off after" is Never and the iPhone isn't locked.
    ///
    /// `timeout`: "Turn off after", nil for Never. `lockedSince`: when the iPhone was found
    /// locked, nil while it isn't.
    public static func date(timeout: TimeInterval?, idleSince: Date, backgroundSince: Date?,
                            keyboard: KeyboardStatus?, lockedSince: Date? = nil,
                            lockTimeout: TimeInterval = IdleStop.lockTimeout) -> Date? {
        // In front, the session never counts down, whatever is believed about the lock.
        guard let backgroundSince else { return nil }
        var start = max(idleSince, backgroundSince)
        if let keyboard { start = max(start, keyboard.inactiveSince) }
        let byTimeout = timeout.map { start.addingTimeInterval($0) }
        let byLock = lockedSince.map { max(start, $0).addingTimeInterval(lockTimeout) }
        switch (byTimeout, byLock) {
        case let (byTimeout?, byLock?): return min(byTimeout, byLock)
        case let (byTimeout?, nil): return byTimeout
        case let (nil, byLock?): return byLock
        case (nil, nil): return nil
        }
    }
}
