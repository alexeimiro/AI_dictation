import MurmurUI
import StoreKit
import SwiftUI

/// Who's signed in, their plan and stats, support, and signing out or deleting the account.
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var support: AccountService.SupportMessage.Kind?
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var working = false
    @State private var error: String?
    @State private var managing = false

    var body: some View {
        let stats = model.history.lifetimeStats()
        let account = model.account
        let identity = AccountIdentity(account)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Avatar(initial: identity.initial, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(verbatim: identity.name)
                                .font(.murmur(.title2))
                                .tracking(-0.4)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if let quota = model.quota { Chip(quota.chip()) }
                        }
                        Text(verbatim: identity.detail)
                            .font(.murmur(.subhead))
                            .foregroundStyle(Theme.second)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.screen("account"))

                HStack(spacing: 12) {
                    stat(stats.words.formatted(), "words dictated")
                    if let wpm = stats.wordsPerMinute {
                        stat("\(wpm)", "words a minute")
                    }
                }
                .padding(.top, 22)

                if let usage = model.quota?.usage() {
                    VStack(alignment: .leading, spacing: 8) {
                        Meter(total: usage.total, filled: usage.filled)
                            .accessibilityHidden(true)
                        Text(verbatim: "\(usage.title): \(usage.detail)")
                            .font(.murmur(.footnote))
                            .monospacedDigit()
                            .foregroundStyle(Theme.third)
                    }
                    .padding(.top, 18)
                }

                if account?.isSignedIn != true {
                    header("Account")
                    Button { model.signInSheet = .options } label: { LinkRow(title: "Sign in…") }
                    Text("Sign in to keep your plan when you change iPhones.")
                        .font(.murmur(.footnote))
                        .foregroundStyle(Theme.third)
                }

                header("Plan")
                if model.pro.isSubscribed {
                    Button { managing = true } label: { LinkRow(title: "Manage subscription") }
                } else {
                    Button { model.showsPaywall = true } label: { LinkRow(title: "Upgrade to Pro") }
                }

                header("Get in touch")
                Button { support = .issue } label: { LinkRow(title: "Report an issue") }
                Button { support = .feedback } label: { LinkRow(title: "Leave feedback") }

                if let privacy = Self.privacyURL {
                    header("Data and privacy")
                    Link(destination: privacy) { LinkRow(title: "View privacy policy", isExternal: true) }
                }

                if account?.isSignedIn == true {
                    VStack(spacing: 4) {
                        Button { confirmSignOut = true } label: {
                            Text("Sign out").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.murmur(.secondary, size: .compact))
                        // Ink, not red: red means the microphone is open.
                        Button { confirmDelete = true } label: {
                            Text("Delete account")
                                .font(.murmur(.subhead, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(.rect)
                        }
                        FieldError(message: error)
                    }
                    .padding(.top, 36)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(Theme.canvas)
        .tint(Theme.ink)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(working)
        .overlay { if working { ProgressView() } }
        .onAppear { model.refreshQuota() }
        .manageSubscriptionsSheet(isPresented: $managing)
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
            Text("Your dictation history, dictionary, snippets and notes are deleted from this iPhone. The dictionary, snippets and notes stay in your account for when you sign in again.")
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

    private func header(_ title: String) -> some View {
        SectionLabel(title)
            .padding(.top, 24)
            .padding(.bottom, 6)
    }

    /// A number with what it counts, on a soft card.
    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.murmur(.title2))
                .tracking(-0.4)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text(caption)
                .font(.murmur(.footnote))
                .foregroundStyle(Theme.second)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    static var privacyURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "MurmurPrivacyURL") as? String)
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
}
