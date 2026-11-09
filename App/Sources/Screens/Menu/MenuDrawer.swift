import MurmurUI
import SwiftUI

/// The side menu the hamburger opens over the tabs: who's signed in and their plan, then the
/// screens that aren't tabs. Swipe left or tap outside to close.
struct MenuDrawer: View {
    @Environment(AppModel.self) private var model
    @State private var support: AccountService.SupportMessage.Kind?
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        let isOpen = model.router.isMenuOpen
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.78, 340)
            ZStack(alignment: .leading) {
                if isOpen {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    panel
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(Palette.paper.ignoresSafeArea())
                        .offset(x: min(0, drag))
                        .gesture(
                            DragGesture()
                                .updating($drag) { value, state, _ in state = value.translation.width }
                                .onEnded { value in if value.translation.width < -width / 3 { close() } }
                        )
                        .transition(.move(edge: .leading))
                        .accessibilityAddTraits(.isModal)
                }
            }
        }
        // Closed, the tabs underneath get every touch.
        .allowsHitTesting(isOpen)
        .animation(.snappy(duration: 0.3), value: isOpen)
        .onChange(of: isOpen) { _, open in if open { model.refreshQuota() } }
        .sheet(item: $support) { kind in
            SupportSheet(kind: kind)
        }
    }

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AccountHeader()
                    .padding(.top, 24)
                PlanUsage(quota: model.quota)
                    .padding(.top, 20)
                Divider().padding(.vertical, 22)
                item("Talk to Support", systemImage: "bubble.left.and.text.bubble.right") {
                    support = .issue
                }
                item("Share feedback", systemImage: "hand.thumbsup") { support = .feedback }
                Divider().padding(.vertical, 22)
                item("Settings", systemImage: "gearshape") { model.router.openFromMenu(.settings) }
                item("Account", systemImage: "person.crop.circle") { model.router.openFromMenu(.account) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func item(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title).font(.ui(18))
            } icon: {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .frame(width: 28)
            }
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func close() {
        model.router.isMenuOpen = false
    }
}

/// The person icon, email (or "Guest") and the plan badge.
struct AccountHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "person.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Palette.ink)
            HStack(spacing: 8) {
                Text(name)
                    .font(.ui(24, .semibold, relativeTo: .title2))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let quota = model.quota {
                    PlanBadge(text: quota.badge)
                }
            }
            if let email = model.account?.email {
                Text(email)
                    .font(.ui(15))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The part of the email before the @, else "Guest".
    private var name: String {
        guard let account = model.account, account.isSignedIn, let email = account.email,
              let local = email.split(separator: "@").first, !email.hasSuffix("privaterelay.appleid.com") else {
            return model.account?.isSignedIn == true ? "Your account" : "Guest"
        }
        return String(local)
    }
}

/// "7 of 14 days used in trial" (or this week's words on Basic) with its bar.
struct PlanUsage: View {
    let quota: AccountService.Quota?

    var body: some View {
        if let quota, let line = quota.usageLine() {
            VStack(alignment: .leading, spacing: 8) {
                Text(line)
                    .font(.ui(15))
                    .foregroundStyle(Palette.textSecondary)
                ProgressView(value: quota.usageFraction() ?? 0)
                    .tint(Palette.proBadge)
            }
        }
    }
}

/// The lavender capsule beside the logo and the name: "Pro Trial", "Pro", "Basic".
struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.ui(13, .medium, relativeTo: .caption))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Palette.proBadge, in: .rect(cornerRadius: 5))
            .fixedSize()
    }
}
