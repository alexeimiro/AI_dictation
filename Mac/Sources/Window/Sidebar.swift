import MurmurBrand
import MurmurCore
import SwiftUI

/// The sidebar: the mark and plan badge, the six pages, the trial or weekly-words meter with
/// Upgrade, then Invite a friend, Help, Settings and the account.
struct Sidebar: View {
    @Bindable var model: MacAppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: Mac.Metric.barHeight)
            brand
            VStack(spacing: 2) {
                ForEach(MacAppModel.Page.allCases) { page in
                    SidebarRow(symbol: page.symbol, title: page.title, selected: model.page == page) {
                        model.page = page
                    }
                }
            }
            .padding(.top, 12)
            Spacer(minLength: 12)
            plan
            Rectangle().fill(Mac.Palette.line).frame(height: 1).padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 6)
            SidebarRow(symbol: "person.badge.plus", title: "Invite a friend", selected: false) {
                SettingsRouter.shared.tab = .plan
                openSettings()
            }
            SidebarRow(symbol: "questionmark.circle", title: "Help", selected: false, external: true) {
                openURL(MacLinks.support)
            }
            SidebarRow(symbol: "slider.horizontal.3", title: "Settings", selected: false) {
                SettingsRouter.shared.tab = .general
                openSettings()
            }
            profile.padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity)
        .background(Mac.Palette.fill)
    }

    private var brand: some View {
        HStack(spacing: 8) {
            MarkView(size: 20)
            wordmarkName().font(Mac.Font.wordmark).tracking(-0.4)
            if let badge = planBadge { Badge(text: badge) }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var planBadge: String? {
        guard let quota = model.quota else { return nil }
        if let left = quota.trialDaysLeft() { return "Trial · \(left) \(left == 1 ? "day" : "days")" }
        return quota.isPro ? "Pro" : "Basic"
    }

    @ViewBuilder private var plan: some View {
        if let quota = model.quota, !(quota.isPro && !quota.onTrial) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(quota.onTrial ? "Trial" : "Basic").font(Mac.Font.label)
                    Spacer()
                    Text(usage(quota)).font(Mac.Font.caption.monospacedDigit()).foregroundStyle(Mac.Palette.third)
                }
                meter(quota)
                Button { model.sheet = .paywall } label: {
                    Text("Upgrade to Pro").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle())
                .padding(.top, 4)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
    }

    private func usage(_ quota: AccountService.Quota) -> String {
        if let left = quota.trialDaysLeft() {
            let used = min(quota.trialLength, max(0, quota.trialLength - left))
            return "\(used) of \(quota.trialLength) days used"
        }
        guard let limit = quota.weeklyLimit else { return "" }
        return "\(quota.wordsThisWeek.formatted()) of \(limit.formatted()) words"
    }

    /// One segment a trial day, or a bar for the week's words.
    @ViewBuilder private func meter(_ quota: AccountService.Quota) -> some View {
        if let left = quota.trialDaysLeft() {
            let used = min(quota.trialLength, max(0, quota.trialLength - left))
            HStack(spacing: 2) {
                ForEach(0..<quota.trialLength, id: \.self) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(day < used ? Mac.Palette.ink : Mac.Palette.track)
                        .frame(height: 4)
                }
            }
            .accessibilityLabel("\(used) of \(quota.trialLength) days used")
        } else {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Mac.Palette.track)
                    Capsule().fill(Mac.Palette.ink).frame(width: proxy.size.width * (quota.usageFraction() ?? 0))
                }
            }
            .frame(height: 4)
        }
    }

    private var profile: some View {
        Button {
            SettingsRouter.shared.tab = .account
            openSettings()
        } label: {
            HStack(spacing: 10) {
                Text(String(model.displayName.prefix(1)).uppercased())
                    .font(Mac.Font.label)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Mac.Palette.ink, lineWidth: 1.5))
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.displayName).font(Mac.Font.label).lineLimit(1)
                    Text(model.accountEmail ?? "Not signed in").font(Mac.Font.caption)
                        .foregroundStyle(Mac.Palette.third).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A sidebar row: 32 pt, icon and title; the selected one is darker grey and semibold.
struct SidebarRow: View {
    let symbol: String
    let title: String
    let selected: Bool
    var external = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
                if external {
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Mac.Palette.third)
                }
            }
            .foregroundStyle(Mac.Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Mac.Palette.line : hovering ? Mac.Palette.line.opacity(0.55) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Murmur's pages on the web.
enum MacLinks {
    static let support = URL(string: info("MurmurSupportURL") ?? "https://simplymurmur.com/support/")!
    static let privacy = URL(string: info("MurmurPrivacyURL") ?? "https://simplymurmur.com/privacy/")!
    static let terms = URL(string: info("MurmurTermsURL") ?? "https://simplymurmur.com/terms/")!
    static let invite = info("MurmurInviteURL") ?? "https://simplymurmur.com/invite/"

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
