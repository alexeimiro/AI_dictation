@preconcurrency import AVFoundation
import Foundation
import os

/// Owns the audio session and the always-on input tap ("hot mic").
///
/// iOS only lets an app *begin* recording in the foreground, so a session starts the engine
/// while the app is visible and keeps the tap running in the background (UIBackgroundModes
/// audio). Buffers are discarded unless the gate is open; the last ~300 ms are kept as pre-roll
/// so the first syllable isn't lost when a dictation starts.
final class AudioCapture: @unchecked Sendable {
    typealias BufferHandler = (AVAudioPCMBuffer) -> Void
    typealias LevelHandler = (Float) -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var gateOpen = false
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFrameCount = 0
    private var bufferHandler: BufferHandler?
    private var levelHandler: LevelHandler?
    private var capturedFrames: AVAudioFramePosition = 0
    private let logger = Logger(subsystem: "Murmur", category: "Audio")

    private(set) var inputFormat: AVAudioFormat?
    private(set) var isRunning = false

    /// Called on the audio thread for every buffer while the gate is open.
    func setBufferHandler(_ handler: BufferHandler?) {
        lock.withLock { bufferHandler = handler }
    }

    /// Called on the audio thread with a 0...1 level for every buffer.
    func setLevelHandler(_ handler: LevelHandler?) {
        lock.withLock { levelHandler = handler }
    }

    // MARK: Session

    /// Must be called while the app is in the foreground.
    func activateSession(preferBuiltInMic: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // .mixWithOthers keeps the user's music playing; leaving out Bluetooth HFP keeps AirPods
        // in high-quality playback and records from the built-in mic.
        try session.setCategory(
            .playAndRecord, mode: .default,
            options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
        if preferBuiltInMic,
           let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }
    }

    func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Engine

    func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInput
        }
        inputFormat = format
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: makeTapBlock())
        engine.prepare()
        try engine.start()
        isRunning = true
        logger.info("Engine started: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount) ch")
    }

    func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        lock.withLock {
            gateOpen = false
            preRoll.removeAll()
            preRollFrames = 0
        }
    }

    /// After a route or configuration change the input format can change: rebuild the tap.
    func restartEngine() throws {
        stopEngine()
        try startEngine()
    }

    // MARK: Gate

    /// Opens the gate. The pre-roll goes through the buffer handler first, while holding the
    /// lock, so it reaches the transcriber before any newer audio from the tap.
    func openGate() {
        lock.withLock {
            gateOpen = true
            capturedFrames = 0
            for buffer in preRoll {
                capturedFrames += AVAudioFramePosition(buffer.frameLength)
                bufferHandler?(buffer)
            }
            preRoll.removeAll()
            preRollFrames = 0
        }
    }

    /// Closes the gate; returns the number of frames captured since `openGate`.
    @discardableResult
    func closeGate() -> AVAudioFramePosition {
        lock.withLock {
            gateOpen = false
            return capturedFrames
        }
    }

    // MARK: Tap

    private func makeTapBlock() -> AVAudioNodeTapBlock {
        { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let level = Self.normalizedLevel(buffer)
        let (open, handler, levels) = lock.withLock { () -> (Bool, BufferHandler?, LevelHandler?) in
            if gateOpen {
                capturedFrames += AVAudioFramePosition(buffer.frameLength)
            } else if let copy = buffer.copy() as? AVAudioPCMBuffer {
                preRoll.append(copy)
                preRollFrames += copy.frameLength
                let limit = AVAudioFrameCount(buffer.format.sampleRate * 0.3)
                while preRollFrames > limit, let first = preRoll.first {
                    preRollFrames -= first.frameLength
                    preRoll.removeFirst()
                }
            }
            return (gateOpen, bufferHandler, levelHandler)
        }
        levels?(level)
        if open { handler?(buffer) }
    }

    /// RMS of the first channel mapped from -50…0 dBFS to 0…1.
    private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in stride(from: 0, to: count, by: 2) {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float((count + 1) / 2))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 50) / 50, 0), 1)
    }

    enum CaptureError: LocalizedError {
        case noInput

        var errorDescription: String? {
            "Couldn't start audio capture. Check that no other app is using the microphone."
        }
    }
}
