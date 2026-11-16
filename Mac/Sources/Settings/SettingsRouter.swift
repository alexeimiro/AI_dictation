import SwiftUI

/// Which Settings tab opens next: the sidebar's Invite a friend opens Plan, the profile opens
/// Account, Settings opens General.
@MainActor
@Observable
final class SettingsRouter {
    enum Tab: String, CaseIterable, Identifiable {
        case general, account, plan, privacy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .account: "Account"
            case .plan: "Plan"
            case .privacy: "Privacy"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .account: "person.crop.circle"
            case .plan: "star"
            case .privacy: "hand.raised"
            }
        }
    }

    static let shared = SettingsRouter()
    var tab: Tab = .general
}
