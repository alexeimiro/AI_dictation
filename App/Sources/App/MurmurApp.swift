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
                MainStack()
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

/// Home and the screens pushed on top of it.
struct MainStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var router = model.router
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .settings: SettingsView()
                    case .languages: LanguagesView()
                    case .debug: DebugView()
                    case .transcript(let id): TranscriptDetailView(id: id)
                    }
                }
        }
        .tint(Palette.ink)
    }
}
