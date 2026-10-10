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

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
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
        .fullScreenCover(isPresented: $model.showSwipeBack) {
            SwipeBackView()
        }
        .confirmationDialog("Turn on Murmur?", isPresented: $model.confirmUntrustedStart,
                            titleVisibility: .visible) {
            Button("Turn On") { model.startSessionFromKeyboard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A link asked Murmur to start listening.")
        }
    }
}
