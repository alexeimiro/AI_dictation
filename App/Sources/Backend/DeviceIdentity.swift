import CryptoKit
import Foundation
import os
import Security
#if os(macOS)
import IOKit
#endif

/// What reading the stored id came to.
enum DeviceIdentityRead: Equatable, Sendable {
    case found(String)
    /// Nothing is stored: this is the first run on this device (or since it was erased).
    case missing
    /// The store can't be read now (the iPhone hasn't been unlocked since it restarted).
    case unavailable
}

/// Where the id is kept.
protocol DeviceIdentityStore: Sendable {
    func read() -> DeviceIdentityRead
    /// False when the id couldn't be kept; then it isn't used, or each launch would make a new one.
    func write(_ id: String) -> Bool
    func remove()
}

/// The id Murmur's server counts the free plan's week by, beside the account: one weekly allowance
/// per iPhone, whichever account is signed in. Without it, signing out and signing in with a second
/// email gave a second week on the same iPhone. `EdgeFunctionClient` sends it with every call
/// (`x-murmur-device`) and `AccountService` with the plan's question (`my_quota`).
///
/// On the iPhone it is a random UUID in the Keychain: it outlives deleting and reinstalling Murmur,
/// as the sign-in does, and it stays on this iPhone (not synced, not restored onto another one). On
/// the Mac it is worked out from the hardware's own id each time, so nothing is stored.
///
/// It is good for that count alone: not the advertising id, not a serial number, nothing another
/// app can read, and it goes when the iPhone is erased.
@MainActor
final class DeviceIdentity {
    static let shared = DeviceIdentity()

    /// The header every call to Murmur's functions carries the id in.
    nonisolated static let header = "x-murmur-device"

    private let store: any DeviceIdentityStore
    private let make: @MainActor () -> UUID
    private var known: String?
    private let logger = Logger(subsystem: "Murmur", category: "Device")

    init(store: any DeviceIdentityStore = DeviceIdentity.systemStore(), make: @escaping @MainActor () -> UUID = { UUID() }) {
        self.store = store
        self.make = make
    }

    /// The id, a lower-case UUID. Nil while it can't be read or kept: nothing is sent then, and the
    /// server goes by the account alone, as it does for builds from before the id.
    var id: String? {
        if let known { return known }
        switch store.read() {
        case .unavailable:
            return nil
        case .found(let stored):
            if let id = Self.normalized(stored) {
                known = id
                return id
            }
            // Not an id of ours: start over rather than send something the server would ignore.
            store.remove()
        case .missing:
            break
        }
        let fresh = make().uuidString.lowercased()
        guard store.write(fresh) else {
            logger.notice("The device id couldn't be kept; none is sent")
            // Another start of the app may have kept one in the meantime.
            if case .found(let stored) = store.read(), let id = Self.normalized(stored) {
                known = id
                return id
            }
            return nil
        }
        known = fresh
        return fresh
    }

    /// A UUID in lower case, as the server takes it; nil for anything else.
    nonisolated static func normalized(_ value: String) -> String? {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))?.uuidString.lowercased()
    }

    nonisolated static func systemStore() -> any DeviceIdentityStore {
        #if os(macOS)
        HardwareDeviceStore()
        #else
        KeychainDeviceStore()
        #endif
    }
}

#if os(macOS)
/// The Mac's id: its hardware UUID, hashed with a prefix of Murmur's own, in the shape of a UUID.
/// The same on every launch and after a reinstall; the hardware UUID itself never leaves the Mac.
struct HardwareDeviceStore: DeviceIdentityStore {
    func read() -> DeviceIdentityRead {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return .unavailable }
        defer { IOObjectRelease(entry) }
        let property = IORegistryEntryCreateCFProperty(entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        guard let hardware = property?.takeRetainedValue() as? String, !hardware.isEmpty else { return .unavailable }
        return .found(Self.id(forHardware: hardware))
    }

    func write(_ id: String) -> Bool { false }
    func remove() {}

    static func id(forHardware hardware: String) -> String {
        let digest = Array(SHA256.hash(data: Data("murmur-device:\(hardware)".utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
            .uuidString.lowercased()
    }
}
#else
/// The iPhone's id, in the app's own Keychain: readable in the background once the iPhone has been
/// unlocked after a restart (a dictation can start from the keyboard while Murmur is behind), kept
/// on this device only, and left in place when the app is deleted.
struct KeychainDeviceStore: DeviceIdentityStore {
    var service = "com.antonmironenko.murmur.device"
    var account = "id"

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read() -> DeviceIdentityRead {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            // Data that isn't text comes back as no id at all: the caller replaces what it can't use.
            return .found((result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable
        }
    }

    func write(_ id: String) -> Bool {
        var attributes = item
        attributes[kSecValueData as String] = Data(id.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    func remove() {
        SecItemDelete(item as CFDictionary)
    }
}
#endif
