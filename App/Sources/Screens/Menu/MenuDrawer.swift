import MurmurCore
import MurmurUI
import SwiftUI

/// The menu the top-left button opens over the screen: the five places, the plan, then invites,
/// help, support and Settings, with the account at the bottom. Swipe left, tap outside or tap ✕
/// to close.
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
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                    panel
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(Theme.canvas.ignoresSafeArea())
                        .offset(x: min(0, drag))
                        .gesture(
                            DragGesture()
                                .updating($drag) { value, state, _ in state = value.translation.width }
                                .onEnded { value in if value.translation.width < -width / 3 { close() } }
                        )
                        .transition(.move(edge: .leading))
                        // One container, so VoiceOver stays inside the menu while it is open.
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { close() }
                }
            }
        }
        // Closed, the screen underneath gets every touch.
        .allowsHitTesting(isOpen)
        .animation(.snappy(duration: 0.3), value: isOpen)
        .onChange(of: isOpen) { _, open in if open { model.refreshQuota() } }
        .sheet(item: $support) { kind in
            SupportSheet(kind: kind)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Wordmark(height: 24)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close menu")
                .accessibilityIdentifier(AccessibilityID.menuClose)
            }
            .padding(.leading, 12)
            .frame(height: 44)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 2) {
                        ForEach(MainTab.menuOrder, id: \.self) { place in
                            placeRow(place)
                        }
                    }
                    .padding(.top, 10)
                    divider
                    plan
                    VStack(spacing: 2) {
                        row("Invite a friend", systemImage: "person.badge.plus", id: AccessibilityID.menuInvite) {
                            model.router.openFromMenu(.referral)
                        }
                        if let help = Brand.supportURL {
                            Link(destination: help) {
                                MenuRow(title: "Help", systemImage: "questionmark.circle", isExternal: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.menuHelp)
                        }
                        // One row: the sheet asks whether it's a problem or feedback.
                        row("Contact support", systemImage: "bubble.left", id: AccessibilityID.menuSupport) {
                            support = .issue
                        }
                        row("Settings", systemImage: "slider.horizontal.3", id: AccessibilityID.menuSettings) {
                            model.router.openFromMenu(.settings)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)

            // The rows above scroll under this line when they don't fit (a small screen, large type).
            Hairline()
                .padding(.horizontal, 12)
            profile
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var divider: some View {
        Hairline()
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
    }

    private func placeRow(_ place: MainTab) -> some View {
        let isCurrent = model.router.tab == place
        return Button {
            model.router.select(place)
        } label: {
            MenuRow(title: place.title, systemImage: place.systemImage, isCurrent: isCurrent)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.menuPlace(place.rawValue))
    }

    private func row(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            MenuRow(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// The trial's days or this week's words, and the way to Pro; nothing for a subscriber.
    @ViewBuilder
    private var plan: some View {
        let usage = model.quota?.usage()
        let offersPro = !model.pro.isSubscribed
        if usage != nil || offersPro {
            VStack(alignment: .leading, spacing: 10) {
                if let usage {
                    HStack(alignment: .firstTextBaseline) {
                        Text(usage.title)
                            .font(.murmur(.subhead, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Text(usage.detail)
                            .font(.murmur(.footnote))
                            .monospacedDigit()
                            .foregroundStyle(Theme.third)
                    }
                    .accessibilityElement(children: .combine)
                    // The line above says the same in words.
                    Meter(total: usage.total, filled: usage.filled)
                        .accessibilityHidden(true)
                }
                if offersPro {
                    Button {
                        close()
                        model.showsPaywall = true
                    } label: {
                        Text("Upgrade to Pro").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.murmur(.primary, size: .compact))
                    .padding(.top, usage == nil ? 0 : 4)
                    .accessibilityIdentifier(AccessibilityID.menuUpgrade)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            divider
        }
    }

    /// Who is signed in, at the bottom: opens Account.
    private var profile: some View {
        let account = model.account
        let name = AccountHeader.name(for: account)
        let signedIn = account?.isSignedIn == true
        // The email names the account, unless it's one of Apple's relay addresses.
        let isNamed = signedIn && name != AccountHeader.unnamed
        return Button {
            model.router.openFromMenu(.account)
        } label: {
            HStack(spacing: 12) {
                Group {
                    if isNamed, let initial = name.first {
                        Text(String(initial).uppercased())
                            .font(.murmur(.subhead, weight: .semibold))
                    } else {
                        Image(systemName: "person")
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .foregroundStyle(Theme.ink)
                .frame(width: 36, height: 36)
                .overlay { Circle().strokeBorder(Theme.ink, lineWidth: 1.5) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name)
                        .font(.murmur(.subhead, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(verbatim: isNamed ? (account?.email ?? "Signed in") : signedIn ? "Signed in" : "Not signed in")
                        .font(.murmur(.footnote))
                        .foregroundStyle(Theme.third)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.third)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Account")
        .accessibilityValue(name)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.menuAccount)
    }

    private func close() {
        model.router.isMenuOpen = false
    }
}

/// One row of the menu: an icon and a title, then the dot that marks the place on screen, or ↗
/// for a page that opens in Safari.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    var isCurrent = false
    var isExternal = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: isCurrent ? .semibold : .regular))
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .font(.murmur(.body, weight: isCurrent ? .bold : .regular))
            Spacer(minLength: 8)
            if isCurrent {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
            if isExternal {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.third)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(.rect)
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
                Text(Self.name(for: model.account))
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

    /// The name of a signed-in account whose email shouldn't be shown (Apple's private relay).
    static let unnamed = "Your account"

    /// The part of the email before the @, else "Guest".
    static func name(for account: AccountModel?) -> String {
        guard let account, account.isSignedIn, let email = account.email,
              let local = email.split(separator: "@").first, !email.hasSuffix("privaterelay.appleid.com") else {
            return account?.isSignedIn == true ? unnamed : "Guest"
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

/// The capsule beside the name: "Pro Trial", "Pro", "Basic".
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
