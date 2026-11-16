#if DEBUG
import AppKit
import SwiftUI

/// Screenshot runs (`-mac-fixtures`): the asked-for surface in a plain AppKit window, put on screen
/// without activating the app, so a capture never takes the user's focus. SwiftUI doesn't open
/// its scenes for a copy launched in the background (`open -g -n`).
@MainActor
enum FixtureWindows {
    private static var windows: [NSWindow] = []

    static func present(_ model: MacAppModel, options: MacLaunchOptions) {
        if let step = options.onboardingStep {
            show(OnboardingWindow(model: model, fixtureStep: step), size: CGSize(width: 960, height: 640), title: "Welcome to Murmur")
        } else if let tab = options.settingsTab.flatMap(SettingsRouter.Tab.init(rawValue:)) {
            SettingsRouter.shared.tab = tab
            show(SettingsWindow(model: model), size: CGSize(width: 680, height: 620), title: tab.title, titled: true)
        } else if let bar = options.barState {
            model.engine.pinForScreenshot(bar)
            show(BarBackdrop(engine: model.engine, hover: bar == "hover"), size: CGSize(width: 640, height: 240), title: "Bar")
        } else if options.quickNote {
            show(QuickNoteWindow(model: model), size: CGSize(width: 420, height: 360), title: "Quick note")
        } else {
            switch options.sheet {
            case "word": model.sheet = .word(nil)
            case "word-edit": model.sheet = .word(model.library.entries.first { $0.misspelling != nil })
            case "snippet": model.sheet = .snippet(nil)
            case "paywall": model.sheet = .paywall
            default: break
            }
            show(MainWindow(model: model), size: Mac.Metric.windowSize, title: "Murmur")
        }
    }

    /// The bar over a plain desktop, for screenshots of its states.
    private struct BarBackdrop: View {
        let engine: DictationEngine
        let hover: Bool

        var body: some View {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(hex: 0xC9CED6), Color(hex: 0xE4E1DC)], startPoint: .top, endPoint: .bottom)
                FlowBarView(engine: engine, onTap: {}, onSize: { _ in }, previewHover: hover)
                    .padding(.bottom, 22)
            }
        }
    }

    private static func show<V: View>(_ view: V, size: CGSize, title: String, titled: Bool = false) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        if !titled {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        windows.append(window)
    }
}
#endif
