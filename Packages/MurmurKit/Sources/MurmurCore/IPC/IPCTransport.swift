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
/// - Payloads: small JSON files in the App Group container (`payloads`), among them the words of
///   the dictation being recorded (`LivePreview`), which the app removes when the dictation ends,
///   and the keyboard's note of the words "Type as I speak" has put into a field
///   (`LiveTypedRecord`), which goes when the final text has replaced them.
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
    private var sessionFailureURL: URL { container.url("session-failure.json") }
    private var dictionaryAdditionsURL: URL { container.url("dictionary-additions.json") }
    private var resultsDirectory: URL { container.directory("results") }
    private var claimsDirectory: URL { container.directory("claimed") }
    private var livePreviewDirectory: URL { container.directory("live") }
    private var livePreviewURL: URL { livePreviewDirectory.appendingPathComponent("preview.json") }
    private var liveTypedDirectory: URL { container.directory("typed") }
    private var liveTypedURL: URL { liveTypedDirectory.appendingPathComponent("record.json") }

    // MARK: Commands (keyboard → app)

    public func write(command: KeyboardCommand) throws {
        try JSONFile.write(command, to: commandURL)
    }

    public func readCommand() -> KeyboardCommand? {
        JSONFile.read(KeyboardCommand.self, from: commandURL)
    }

    // MARK: Results (app → keyboard)

    /// `updatesLatest: false` leaves `latest-result.json` alone, so an answer only the waiting
    /// keyboard needs (a dictation that was dropped) doesn't hide the last real one.
    public func write(result: DictationResult, updatesLatest: Bool = true) throws {
        try JSONFile.write(result, to: resultsDirectory.appendingPathComponent("\(result.requestId.uuidString).json"))
        if updatesLatest { try JSONFile.write(result, to: latestResultURL) }
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

    /// When `requestId` was claimed: its marker's modification date, which `prune` goes by too.
    /// Nil while unclaimed.
    public func claimDate(_ requestId: UUID) -> Date? {
        let marker = claimsDirectory.appendingPathComponent(requestId.uuidString)
        return (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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

    /// Clears the pending start only while it is still `requestId`'s, so a newer tap survives.
    public func clearPendingStart(_ requestId: UUID) {
        guard readPendingStart()?.requestId == requestId else { return }
        JSONFile.remove(pendingStartURL)
    }

    // MARK: Session failure (app → keyboard)

    public func write(sessionFailure: SessionFailure) throws {
        try JSONFile.write(sessionFailure, to: sessionFailureURL)
    }

    public func readSessionFailure() -> SessionFailure? {
        JSONFile.read(SessionFailure.self, from: sessionFailureURL)
    }

    public func clearSessionFailure() {
        JSONFile.remove(sessionFailureURL)
    }

    // MARK: Live preview (app → keyboard)

    /// The words of the dictation being recorded. Only the app writes it. Staged beside the file
    /// and renamed over it, so a reader never sees half of it; its directory is kept out of backups.
    public func write(livePreview: LivePreview) throws {
        try writeStaged(JSONEncoder().encode(livePreview), to: livePreviewURL)
    }

    /// Writes a file of dictated words into its own directory, which is kept out of backups.
    private func writeStaged(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // The words are no part of a backup.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var marked = directory
            try? marked.setResourceValues(values)
        }
        // Staged here, not by `.atomic`, whose temporary copy a sandboxed process keeps outside
        // this folder: removing the directory then takes a write that was cut short with it.
        let staging = url.deletingPathExtension().appendingPathExtension("tmp")
        try data.write(to: staging)
        guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    public func readLivePreview() -> LivePreview? {
        JSONFile.read(LivePreview.self, from: livePreviewURL)
    }

    /// Removes the preview, and with it a write that was cut short: the file has a directory of
    /// its own (`live/`), where writes are staged too, so that it can all go at once. The app calls
    /// it when the dictation ends; the keyboard when it stops following a dictation (the check, the
    /// cross, or the app stopped answering), should the app be gone.
    public func clearLivePreview() {
        JSONFile.remove(livePreviewDirectory)
    }

    // MARK: Live typing (the keyboard's own)

    /// What "Type as I speak" has put into the field for a dictation. Only the keyboard writes it,
    /// before each insertion. Staged and renamed like the preview, in a directory of its own
    /// (`typed/`) that is kept out of backups too and that `clearLivePreview()` leaves alone: the
    /// record outlives the preview, until the final text has replaced its words.
    public func write(liveTyped record: LiveTypedRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try writeStaged(encoder.encode(record), to: liveTypedURL)
    }

    public func readLiveTyped() -> LiveTypedRecord? {
        JSONFile.read(LiveTypedRecord.self, from: liveTypedURL)
    }

    /// Removes the record, and a write of it that was cut short. The keyboard calls it when the
    /// words are replaced or taken out, when they are left as text for good (`LiveTypedRecord`)
    /// and when the next dictation starts; the app when the account goes.
    public func clearLiveTyped() {
        JSONFile.remove(liveTypedDirectory)
    }

    // MARK: Dictionary additions (keyboard → app)

    /// Queues a word from the keyboard's ☰ menu; one already queued (in any case) isn't queued
    /// twice. At most the newest 50 wait.
    public func append(dictionaryAddition addition: DictionaryAddition) throws {
        var queued = JSONFile.read([DictionaryAddition].self, from: dictionaryAdditionsURL) ?? []
        let key = addition.term.lowercased()
        guard !queued.contains(where: { $0.term.lowercased() == key }) else { return }
        queued.append(addition)
        try JSONFile.write(Array(queued.suffix(50)), to: dictionaryAdditionsURL)
    }

    /// Everything queued, oldest first, emptying the queue.
    public func takeDictionaryAdditions() -> [DictionaryAddition] {
        let queued = JSONFile.read([DictionaryAddition].self, from: dictionaryAdditionsURL) ?? []
        if !queued.isEmpty { JSONFile.remove(dictionaryAdditionsURL) }
        return queued
    }

    // MARK: Housekeeping

    /// Deletes results and claim markers older than `age`, and a `LiveTypedRecord` last written
    /// longer ago: its words are ordinary text by then.
    public func prune(olderThan age: TimeInterval, now: Date = Date()) {
        let fileManager = FileManager.default
        if let written = (try? liveTypedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate, now.timeIntervalSince(written) > age {
            clearLiveTyped()
        }
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
