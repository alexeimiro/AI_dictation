import MurmurUI
import SwiftUI

/// Who's signed in, their plan and stats, support, and signing out or deleting the account.
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var support: AccountService.SupportMessage.Kind?
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        let stats = model.history.lifetimeStats()
        let account = model.account
        List {
            Section {
                VStack(spacing: 12) {
                    AccountHeader()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 18) {
                        Label("\(stats.words.formatted()) words", systemImage: "text.word.spacing")
                        if let wpm = stats.wordsPerMinute {
                            Label("\(wpm) WPM", systemImage: "speedometer")
                        }
                    }
                    .font(.ui(15))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PlanUsage(quota: model.quota)
                }
                .padding(.vertical, 8)
                if account?.isSignedIn != true {
                    Button("Sign in…") { model.signInSheet = .options }
                        .font(.ui(17, .medium))
                }
            } footer: {
                if account?.isSignedIn != true {
                    Text("Sign in to keep your plan when you change iPhones.")
                }
            }

            Section("Get in touch") {
                Button("Report an issue") { support = .issue }
                Button("Leave feedback") { support = .feedback }
            }

            if let privacy = Self.privacyURL {
                Section("Data and privacy") {
                    Link(destination: privacy) {
                        Label("View privacy policy", systemImage: "arrow.up.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                }
            }

            if account?.isSignedIn == true {
                Section {
                    Button("Sign out") { confirmSignOut = true }
                        .frame(maxWidth: .infinity)
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                } footer: {
                    FieldError(message: error)
                }
            }
        }
        .font(.ui(17))
        .tint(Palette.ink)
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .disabled(working)
        .overlay { if working { ProgressView() } }
        .onAppear { model.refreshQuota() }
        .sheet(item: $support) { kind in
            SupportSheet(kind: kind)
        }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                working = true
                Task {
                    await model.signOut()
                    working = false
                }
            }
        } message: {
            Text("Your dictation history, dictionary, snippets and notes on this iPhone are deleted.")
        }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Delete Account", role: .destructive) {
                working = true
                Task {
                    error = await model.deleteAccount()
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account and everything stored with it are deleted, here and on our servers. This can't be undone. An App Store subscription isn't cancelled: manage it in Settings › Apple Account › Subscriptions.")
        }
    }

    static var privacyURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "MurmurPrivacyURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}

/// The title first, the icon after it ("View privacy policy ↗").
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
                .font(.system(size: 13))
        }
    }
}
