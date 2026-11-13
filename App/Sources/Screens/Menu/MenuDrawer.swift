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
        let offersPro = !model.hasProSubscription
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
        let identity = AccountIdentity(model.account)
        return Button {
            model.router.openFromMenu(.account)
        } label: {
            HStack(spacing: 12) {
                Avatar(initial: identity.initial, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: identity.name)
                        .font(.murmur(.subhead, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(verbatim: identity.detail)
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
        .accessibilityValue(identity.name)
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
