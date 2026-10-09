import Darwin
import notify
import Foundation

/// A registration for an `IPCEvent`. Cancelled on `cancel()` or deinit.
public protocol IPCObservation: AnyObject, Sendable {
    func cancel()
}

/// The channel between the keyboard extension and the app.
///
/// - Hot state: one 64-bit value (status, mic level, request tag, sequence), polled cheaply.
/// - Events: payload-less Darwin notifications.
/// - Payloads: small JSON files in the App Group container (`payloads`).
public protocol IPCTransport: AnyObject, Sendable {
    var payloads: IPCPayloadStore { get }

    func publish(_ state: HotState)
    func currentState() -> HotState

    func post(_ event: IPCEvent)
    /// `handler` runs on the main queue.
    func observe(_ event: IPCEvent, handler: @escaping @Sendable () -> Void) -> IPCObservation
}

/// File-backed payloads shared by both processes.
public final class IPCPayloadStore: @unchecked Sendable {
    public let container: SharedContainer

    public init(container: SharedContainer) {
        self.container = container
    }

    private var commandURL: URL { container.url("command.json") }
    private var latestResultURL: URL { container.url("latest-result.json") }
    private var keyboardStatusURL: URL { container.url("keyboard-status.json") }
    private var launchTokenURL: URL { container.url("launch-token.json") }
    private var pendingStartURL: URL { container.url("pending-start.json") }
    private var resultsDirectory: URL { container.directory("results") }
    private var claimsDirectory: URL { container.directory("claimed") }

    // MARK: Commands (keyboard → app)

    public func write(command: KeyboardCommand) throws {
        try JSONFile.write(command, to: commandURL)
    }

    public func readCommand() -> KeyboardCommand? {
        JSONFile.read(KeyboardCommand.self, from: commandURL)
    }

    // MARK: Results (app → keyboard)

    public func write(result: DictationResult) throws {
        try JSONFile.write(result, to: resultsDirectory.appendingPathComponent("\(result.requestId.uuidString).json"))
        try JSONFile.write(result, to: latestResultURL)
    }

    public func readResult(_ requestId: UUID) -> DictationResult? {
        JSONFile.read(DictationResult.self, from: resultsDirectory.appendingPathComponent("\(requestId.uuidString).json"))
    }

    public func latestResult() -> DictationResult? {
        JSONFile.read(DictationResult.self, from: latestResultURL)
    }

    /// Claims a result for insertion. Exactly one caller (across processes) gets `true`,
    /// because the marker file is created with O_EXCL.
    @discardableResult
    public func claim(_ requestId: UUID) -> Bool {
        try? FileManager.default.createDirectory(at: claimsDirectory, withIntermediateDirectories: true)
        let path = claimsDirectory.appendingPathComponent(requestId.uuidString).path
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    public func isClaimed(_ requestId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: claimsDirectory.appendingPathComponent(requestId.uuidString).path)
    }

    // MARK: Keyboard status

    public func write(keyboardStatus: KeyboardStatus) throws {
        try JSONFile.write(keyboardStatus, to: keyboardStatusURL)
    }

    public func readKeyboardStatus() -> KeyboardStatus? {
        JSONFile.read(KeyboardStatus.self, from: keyboardStatusURL)
    }

    // MARK: Session start handshake

    public func write(launchToken: LaunchToken) throws {
        try JSONFile.write(launchToken, to: launchTokenURL)
    }

    /// Returns the token if it matches and is fresh, deleting it so it can't be replayed.
    public func consumeLaunchToken(_ token: String, maxAge: TimeInterval, now: Date) -> LaunchToken? {
        guard let stored = JSONFile.read(LaunchToken.self, from: launchTokenURL) else { return nil }
        JSONFile.remove(launchTokenURL)
        guard stored.token == token, now.timeIntervalSince(stored.createdAt) <= maxAge,
              stored.createdAt <= now.addingTimeInterval(5) else { return nil }
        return stored
    }

    public func write(pendingStart: PendingStart) throws {
        try JSONFile.write(pendingStart, to: pendingStartURL)
    }

    public func readPendingStart() -> PendingStart? {
        JSONFile.read(PendingStart.self, from: pendingStartURL)
    }

    public func clearPendingStart() {
        JSONFile.remove(pendingStartURL)
    }

    // MARK: Housekeeping

    /// Deletes results and claim markers older than `age`.
    public func prune(olderThan age: TimeInterval, now: Date = Date()) {
        let fileManager = FileManager.default
        for directory in [resultsDirectory, claimsDirectory] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(modified) > age {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}

/// Production transport: libnotify state + Darwin notifications + App Group files.
public final class DarwinIPCTransport: IPCTransport, @unchecked Sendable {
    public let payloads: IPCPayloadStore
    private let group: String
    private let stateToken: Int32

    public init(container: SharedContainer, group: String = Brand.appGroupID) {
        self.payloads = IPCPayloadStore(container: container)
        self.group = group
        var token: Int32 = -1
        let status = notify_register_check("\(group).hotstate", &token)
        self.stateToken = status == UInt32(NOTIFY_STATUS_OK) ? token : -1
    }

    deinit {
        if stateToken >= 0 { notify_cancel(stateToken) }
    }

    public func publish(_ state: HotState) {
        guard stateToken >= 0 else { return }
        notify_set_state(stateToken, state.packed)
    }

    public func currentState() -> HotState {
        guard stateToken >= 0 else { return .off }
        var value: UInt64 = 0
        notify_get_state(stateToken, &value)
        return HotState(packed: value)
    }

    public func post(_ event: IPCEvent) {
        notify_post(event.notificationName(group: group))
    }

    public func observe(_ event: IPCEvent, handler: @escaping @Sendable () -> Void) -> IPCObservation {
        var token: Int32 = -1
        let status = notify_register_dispatch(event.notificationName(group: group), &token, DispatchQueue.main) { _ in
            handler()
        }
        return NotifyObservation(token: status == UInt32(NOTIFY_STATUS_OK) ? token : -1)
    }
}

private final class NotifyObservation: IPCObservation, @unchecked Sendable {
    private let lock = NSLock()
    private var token: Int32

    init(token: Int32) {
        self.token = token
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if token >= 0 {
            notify_cancel(token)
            token = -1
        }
    }

    deinit { cancel() }
}

/// In-process transport for tests and previews. Events are delivered asynchronously on the
/// main queue, like the real one.
public final class InMemoryIPCTransport: IPCTransport, @unchecked Sendable {
    public let payloads: IPCPayloadStore
    private let lock = NSLock()
    private var state = HotState.off
    private var handlers: [IPCEvent: [UUID: @Sendable () -> Void]] = [:]
    public private(set) var postedEvents: [IPCEvent] = []

    public init(container: SharedContainer = .temporary()) {
        self.payloads = IPCPayloadStore(container: container)
    }

    public func publish(_ state: HotState) {
        lock.withLock { self.state = state }
    }

    public func currentState() -> HotState {
        lock.withLock { state }
    }

    public func post(_ event: IPCEvent) {
        let callbacks = lock.withLock { () -> [@Sendable () -> Void] in
            postedEvents.append(event)
            return Array(handlers[event, default: [:]].values)
        }
        for callback in callbacks {
            DispatchQueue.main.async(execute: callback)
        }
    }

    public func observe(_ event: IPCEvent, handler: @escaping @Sendable () -> Void) -> IPCObservation {
        let id = UUID()
        lock.withLock { handlers[event, default: [:]][id] = handler }
        return InMemoryObservation { [weak self] in
            self?.lock.withLock { _ = self?.handlers[event]?.removeValue(forKey: id) }
        }
    }
}

private final class InMemoryObservation: IPCObservation, @unchecked Sendable {
    private var onCancel: (@Sendable () -> Void)?
    private let lock = NSLock()

    init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let callback = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onCancel = nil }
            return onCancel
        }
        callback?()
    }

    deinit { cancel() }
}
