import Foundation
import MurmurCore
import Network
import os

/// Whether dictations spare the network: Settings' Low data mode, or iOS's own Low Data Mode on
/// the current network (`NWPath.isConstrained`). Then the audio uploads at half the bitrate and
/// no warm-up requests go out while the user speaks.
final class NetworkConditions: @unchecked Sendable {
    static let shared = NetworkConditions()

    private let monitor = NWPathMonitor()
    private let constrained = OSAllocatedUnfairLock(initialState: false)

    private init() {
        monitor.pathUpdateHandler = { [constrained] path in
            constrained.withLock { $0 = path.isConstrained }
        }
        monitor.start(queue: DispatchQueue(label: "Murmur.NetworkConditions", qos: .utility))
    }

    /// iOS's Low Data Mode is on for the current network.
    var isConstrained: Bool { constrained.withLock { $0 } }

    func savesData(settings: SharedSettings = .shared) -> Bool {
        settings.lowDataMode || isConstrained
    }
}
