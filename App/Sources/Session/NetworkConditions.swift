import Foundation
import MurmurCore
import Network
import os

/// Whether dictations spare the network: Settings' Low data mode, or iOS's own Low Data Mode on
/// the current network (`NWPath.isConstrained`). Then the audio uploads at half the bitrate and
/// no warm-up requests go out while the user speaks. And whether the network is one to download a
/// speech model on (`downloadsModels`): Wi-Fi, not mobile data or a hotspot.
final class NetworkConditions: @unchecked Sendable {
    static let shared = NetworkConditions()

    private let monitor = NWPathMonitor()
    private let constrained = OSAllocatedUnfairLock(initialState: false)
    /// True until the first path says otherwise: nothing is downloaded on a network not yet known.
    private let expensive = OSAllocatedUnfairLock(initialState: true)

    private init() {
        monitor.pathUpdateHandler = { [constrained, expensive] path in
            constrained.withLock { $0 = path.isConstrained }
            expensive.withLock { $0 = path.isExpensive || path.status != .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "Murmur.NetworkConditions", qos: .utility))
    }

    /// iOS's Low Data Mode is on for the current network.
    var isConstrained: Bool { constrained.withLock { $0 } }

    /// Mobile data or a personal hotspot (`NWPath.isExpensive`), or no network at all.
    var isExpensive: Bool { expensive.withLock { $0 } }

    /// A speech model (tens to hundreds of megabytes) may be downloaded now: on Wi-Fi, and not
    /// while data is being spared.
    func downloadsModels(settings: SharedSettings = .shared) -> Bool {
        !isExpensive && !savesData(settings: settings)
    }

    func savesData(settings: SharedSettings = .shared) -> Bool {
        settings.lowDataMode || isConstrained
    }
}
