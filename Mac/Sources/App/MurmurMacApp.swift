import AppKit
import MurmurBrand
import SwiftUI

@main
struct MurmurMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var delegate

    /// The first launch shows onboarding; later ones the main window.
    private let onboarded = UserDefaults.standard.bool(forKey: "macOnboardingComplete")

    var body: some Scene {
        Window("Murmur", id: "main") {
            MainWindow(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(Mac.Metric.windowSize)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(onboarded ? .presented : .suppressed)

        Settings {
            SettingsWindow(model: delegate.model)
        }

        Window("Welcome to Murmur", id: "onboarding") {
            OnboardingWindow(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(onboarded ? .suppressed : .presented)

        Window("Quick note", id: "quicknote") {
            QuickNoteWindow(model: delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 420, height: 360)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra {
            MenuBarMenu(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
    }
}

/// Starts the engine at launch, so the shortcut and the bar work without a window open.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let model = MacAppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if model.usesFixtures {
            FixtureWindows.present(model, options: .current)
            return
        }
        #endif
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The Dock icon clicked with no window open: onboarding until it's done, then the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        model.openMainWindow()
        return false
    }
}
