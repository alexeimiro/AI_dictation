import AppKit
import SwiftUI

/// The floating bar: a borderless panel at the bottom centre of the screen, above the Dock, on
/// every Space and over full-screen apps. It never takes focus, so the text still goes to the app
/// the user is typing in. The panel is only as big as what it shows, so the rest of the screen
/// stays clickable. With "Show the floating bar" off (or Murmur off) it appears only while it
/// has something to say.
@MainActor
final class FlowBarController {
    private let panel: FlowBarPanel
    private let hosting: NSHostingView<FlowBarView>
    private let engine: DictationEngine
    private let isEnabled: () -> Bool
    private var lastSize: CGSize = .zero

    init(engine: DictationEngine, isEnabled: @escaping () -> Bool, onTap: @escaping () -> Void,
         onNoticeAction: @escaping (DictationEngine.Notice) -> Void) {
        self.engine = engine
        self.isEnabled = isEnabled
        panel = FlowBarPanel()
        hosting = NSHostingView(rootView: FlowBarView(engine: engine, onTap: onTap, onSize: { _ in }))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        hosting.rootView = FlowBarView(engine: engine, onTap: onTap, onSize: { [weak self] size in
            self?.lastSize = size
            self?.place()
        }, onNoticeAction: onNoticeAction)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
        observe()
    }

    /// Re-evaluates when anything the bar's visibility depends on changes.
    private func observe() {
        withObservationTracking {
            _ = engine.phase
            _ = engine.notice
            _ = engine.justInserted
            _ = MacSettings.shared.showFloatingBar
            _ = isEnabled()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.place()
                self?.observe()
            }
        }
    }

    private var shouldShow: Bool {
        let busy = engine.phase != .idle || engine.notice != nil || engine.justInserted
        return busy || (isEnabled() && MacSettings.shared.showFloatingBar)
    }

    /// Bottom centre of the screen the pointer is on, 10 pt above the Dock (or the screen's edge).
    func place() {
        guard shouldShow else {
            panel.orderOut(nil)
            return
        }
        let size = lastSize.width > 0 ? lastSize : hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let frame = NSRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + 6,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}

/// A panel that floats above other apps' windows and never becomes key.
final class FlowBarPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 60, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
