import MurmurUI
import SwiftUI

@main
struct MurmurApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(model.history.container)
                .onOpenURL { model.handle($0) }
                .onChange(of: scenePhase) { _, newPhase in
                    model.scenePhaseChanged(newPhase)
                }
        }
    }
}

/// Onboarding until it is finished, then Home. The two never share a navigation stack.
struct RootView: View {
    @Environment(AppModel.self) private var model
    /// From the sign-in sheet's appearing until its dismissal has finished.
    @State private var signInSheetOnScreen = false

    var body: some View {
        @Bindable var model = model
        // UIKit presents one thing at a time: what comes after the sign-in sheet (AppModel closes
        // it first) waits until it has gone, or it would never show.
        let held = model.signInSheet != nil || signInSheetOnScreen
        ZStack {
            if model.onboarding.isComplete {
                MainTabs()
                    .transition(.opacity)
            } else {
                OnboardingRootView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.onboarding.isComplete)
        .fullScreenCover(isPresented: Binding(get: { model.showSwipeBack && !held },
                                              set: { model.showSwipeBack = $0 })) {
            SwipeBackView()
        }
        .confirmationDialog("Turn on Murmur?",
                            isPresented: Binding(get: { model.confirmUntrustedStart && !held },
                                                 set: { model.confirmUntrustedStart = $0 }),
                            titleVisibility: .visible) {
            Button("Turn On") { model.startSessionFromKeyboard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A link asked Murmur to start listening.")
        }
        // Home's signed-out card, Settings' Sign in… and onboarding's offer page open it.
        .sheet(item: $model.signInSheet, onDismiss: { signInSheetOnScreen = false }) { start in
            SignInAgainView(start: start)
                .onAppear { signInSheetOnScreen = true }
        }
    }
}

/// The tab bar (Home, Dictionary, Snippets, Style, Scratchpad), each tab with its own stack, and
/// the side menu over them.
struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var router = model.router
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: MainTab.home) {
                TabStack(tab: .home) { HomeView() }
            }
            Tab("Dictionary", systemImage: "character.book.closed", value: MainTab.dictionary) {
                TabStack(tab: .dictionary) { DictionaryView() }
            }
            Tab("Snippets", systemImage: "scissors", value: MainTab.snippets) {
                TabStack(tab: .snippets) { SnippetsView() }
            }
            Tab("Style", systemImage: "textformat.size", value: MainTab.style) {
                TabStack(tab: .style) { StyleView() }
            }
            Tab("Scratchpad", systemImage: "note.text", value: MainTab.scratchpad) {
                TabStack(tab: .scratchpad) { ScratchpadView() }
            }
        }
        .tint(Palette.tabSelectedLabel)
        .overlay { MenuDrawer() }
    }
}

/// One tab's navigation stack, bound to its path in the router.
private struct TabStack<Root: View>: View {
    @Environment(AppModel.self) private var model
    let tab: MainTab
    @ViewBuilder let root: () -> Root

    var body: some View {
        let router = model.router
        NavigationStack(path: Binding(get: { router.paths[tab] ?? [] }, set: { router.paths[tab] = $0 })) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .settings: SettingsView()
                    case .languages: LanguagesView()
                    case .debug: DebugView()
                    case .transcript(let id): TranscriptDetailView(id: id)
                    case .account: AccountView()
                    case .note(let id): NoteEditorView(id: id)
                    }
                }
        }
        .tint(Palette.ink)
    }
}
