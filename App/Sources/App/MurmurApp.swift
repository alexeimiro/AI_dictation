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
        // A code from an invite link, used once signed in.
        .alert("Your invite", isPresented: Binding(get: { model.inviteMessage != nil && !held },
                                                   set: { if !$0 { model.inviteMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.inviteMessage ?? "")
        }
        // Home's signed-out card, Settings' Sign in… and onboarding's offer page open it.
        .sheet(item: $model.signInSheet, onDismiss: { signInSheetOnScreen = false }) { start in
            SignInAgainView(start: start)
                .onAppear { signInSheetOnScreen = true }
        }
        // After a reinstall, signing in brings back the account's style.
        .onChange(of: model.account?.isSignedIn ?? false) { _, signedIn in
            if signedIn { model.syncStyle() }
        }
    }
}

/// The five places the menu leads to (Home, Notes, Dictionary, Snippets, Style), each with its own
/// stack, and the menu over them. A `TabView` whose bar never shows keeps each place's stack and
/// scroll position while another is on screen.
struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var router = model.router
        TabView(selection: $router.tab) {
            Tab(value: MainTab.home) {
                TabStack(tab: .home) { HomeView() }
            }
            Tab(value: MainTab.scratchpad) {
                TabStack(tab: .scratchpad) { ScratchpadView() }
            }
            Tab(value: MainTab.dictionary) {
                TabStack(tab: .dictionary) { DictionaryView() }
            }
            Tab(value: MainTab.snippets) {
                TabStack(tab: .snippets) { SnippetsView() }
            }
            Tab(value: MainTab.style) {
                TabStack(tab: .style) { StyleView() }
            }
        }
        .tint(Theme.ink)
        .overlay { MenuDrawer() }
        .fullScreenCover(isPresented: Binding(get: { model.showsPaywall }, set: { model.showsPaywall = $0 })) {
            PaywallView()
        }
    }
}

/// One place's navigation stack, bound to its path in the router. The tab bar stays hidden on its
/// root and on everything pushed onto it: the menu is the only way between places.
private struct TabStack<Root: View>: View {
    @Environment(AppModel.self) private var model
    let tab: MainTab
    @ViewBuilder let root: () -> Root

    var body: some View {
        let router = model.router
        NavigationStack(path: Binding(get: { router.paths[tab] ?? [] }, set: { router.paths[tab] = $0 })) {
            root()
                .toolbarVisibility(.hidden, for: .tabBar)
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                        .toolbarVisibility(.hidden, for: .tabBar)
                }
        }
        .tint(Theme.ink)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .settings: SettingsView()
        case .languages: LanguagesView()
        case .debug: DebugView()
        case .transcript(let id): TranscriptDetailView(id: id)
        case .account: AccountView()
        case .referral: ReferralView()
        case .note(let id): NoteEditorView(id: id)
        }
    }
}
