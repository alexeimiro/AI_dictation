import AppKit
import CoreGraphics
import os

/// The dictation shortcut, heard whichever app is in front, through a session event tap (which
/// needs Accessibility, the permission Murmur asks for anyway to type the text). The key is fn
/// unless the user picked another (`MacSettings.trigger`).
///
/// - Hold the key: push-to-talk. It records from the press and writes on release.
/// - Double-tap it: hands-free (unless switched off). It records until it's pressed again.
/// - ⌃⌘V: paste the last dictation again (unless switched off).
/// - A press shorter than `tapMax`, or one with another key in it (fn+arrow, fn+Delete), is no
///   dictation: what it recorded is thrown away.
/// - Esc while recording cancels.
///
/// The fn key is never swallowed, so macOS still sees it; onboarding asks the user to set
/// "Press 🌐 key to" to "Do Nothing" when it would switch the input source on every dictation.
@MainActor
final class HotkeyMonitor {
    enum Event: Equatable {
        case pushToTalkBegan
        case pushToTalkEnded
        /// The press was a tap or a key combination: not a dictation.
        case pushToTalkAbandoned
        case handsFreeBegan
        case handsFreeEnded
        case cancelled
        /// ⌃⌘V: type the last dictation again.
        case pasteLast
        /// ⌥⌘N: a new quick note.
        case quickNote
        /// The key held with ⌃: Command mode, until it's let go.
        case commandBegan
        case commandEnded
    }

    /// A press shorter than this is a tap.
    static let tapMax: TimeInterval = 0.25
    /// The second press of a double tap comes within this of the first one's release.
    static let doubleTapGap: TimeInterval = 0.4

    var onEvent: ((Event) -> Void)?
    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let logger = Logger(subsystem: "Murmur", category: "Hotkey")

    private var fnDown = false
    private var fnDownAt: TimeInterval = 0
    private var lastTapUpAt: TimeInterval = -1
    private var otherKeyDuringPress = false
    private var pushToTalk = false
    private var command = false
    private var handsFree = false
    /// The release that belongs to a press that started or stopped hands-free.
    private var ignoreRelease = false

    /// Installs the tap; false while Murmur isn't trusted for Accessibility.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            logger.notice("No event tap: Accessibility isn't granted yet")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        logger.info("Listening for the fn key")
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
        reset()
    }

    /// The dictation ended some other way (the bar's ✕ or ✓, an error): forget the press state.
    func reset() {
        pushToTalk = false
        handsFree = false
        command = false
        ignoreRelease = fnDown
    }

    /// Returns true to swallow the event.
    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown:
            let settings = MacSettings.shared
            if settings.pasteLastShortcut, keyCode == Self.vKey, !pushToTalk, !handsFree,
               flags.contains([.maskControl, .maskCommand]), flags.isDisjoint(with: [.maskShift, .maskAlternate]) {
                onEvent?(.pasteLast)
                return true
            }
            if keyCode == Self.nKey, !pushToTalk, !handsFree,
               flags.contains([.maskAlternate, .maskCommand]), flags.isDisjoint(with: [.maskShift, .maskControl]) {
                onEvent?(.quickNote)
                return true
            }
            if keyCode == Self.escape, pushToTalk || handsFree || command {
                pushToTalk = false
                handsFree = false
                command = false
                ignoreRelease = fnDown
                onEvent?(.cancelled)
                return true
            }
            if fnDown, pushToTalk {
                // fn+arrow, fn+Delete…: the user meant the key, not a dictation.
                otherKeyDuringPress = true
                pushToTalk = false
                ignoreRelease = true
                onEvent?(.pushToTalkAbandoned)
            }
            return false
        case .flagsChanged:
            let trigger = MacSettings.shared.trigger
            // ⌃ pressed just after the key: the press becomes Command mode.
            if Self.controlKeys.contains(keyCode), keyCode != trigger.keyCode, flags.contains(.maskControl),
               pushToTalk, !command, ProcessInfo.processInfo.systemUptime - fnDownAt < 0.5 {
                pushToTalk = false
                command = true
                onEvent?(.commandBegan)
                return false
            }
            guard keyCode == trigger.keyCode else { return false }
            let down = flags.rawValue & trigger.deviceMask != 0
            let now = ProcessInfo.processInfo.systemUptime
            if down, !fnDown {
                fnDown = true
                fnDownAt = now
                otherKeyDuringPress = false
                pressed(at: now, control: trigger != .rightControl && flags.contains(.maskControl))
            } else if !down, fnDown {
                fnDown = false
                released(at: now)
            }
            return false
        default:
            return false
        }
    }

    private func pressed(at now: TimeInterval, control: Bool) {
        if control, !handsFree {
            command = true
            onEvent?(.commandBegan)
            return
        }
        if handsFree {
            handsFree = false
            ignoreRelease = true
            onEvent?(.handsFreeEnded)
            return
        }
        if MacSettings.shared.handsFree, lastTapUpAt >= 0, now - lastTapUpAt < Self.doubleTapGap {
            lastTapUpAt = -1
            handsFree = true
            ignoreRelease = true
            onEvent?(.handsFreeBegan)
            return
        }
        pushToTalk = true
        onEvent?(.pushToTalkBegan)
    }

    private func released(at now: TimeInterval) {
        if command {
            command = false
            onEvent?(.commandEnded)
            return
        }
        if ignoreRelease {
            ignoreRelease = false
            return
        }
        guard pushToTalk else { return }
        pushToTalk = false
        let held = now - fnDownAt
        if held < Self.tapMax, !otherKeyDuringPress {
            lastTapUpAt = now
            onEvent?(.pushToTalkAbandoned)
        } else if otherKeyDuringPress {
            onEvent?(.pushToTalkAbandoned)
        } else {
            onEvent?(.pushToTalkEnded)
        }
    }

    private static let escape: Int64 = 53
    private static let controlKeys: Set<Int64> = [59, 62]
    private static let vKey: Int64 = 9
    private static let nKey: Int64 = 45
}

/// The tap's C callback: the tap's run-loop source is on the main run loop, so this runs there.
private func hotkeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    // Only plain values cross into the main actor; the event itself stays here.
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, keyCode: keyCode, flags: flags) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
