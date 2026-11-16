@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// The microphone for one dictation. Unlike the iPhone's `AudioCapture`, nothing runs between
/// dictations: the engine starts when the shortcut goes down and stops when the dictation ends,
/// so macOS shows its microphone indicator only while Murmur records.
final class MacAudioCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    typealias LevelHandler = @Sendable (Float) -> Void

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var bufferHandler: BufferHandler?
    private var levelHandler: LevelHandler?
    private var capturedFrames: AVAudioFramePosition = 0
    private let logger = Logger(subsystem: "Murmur", category: "Audio")

    /// The format the last dictation recorded in.
    private(set) var inputFormat: AVAudioFormat?

    var isRunning: Bool { engine.isRunning }

    /// The format the input records in, read without starting it (the transcriber is prepared
    /// for it ahead of the first dictation). Nil without an input device. `device`: the
    /// microphone picked in Settings, nil for the system's.
    func currentInputFormat(device: AudioDeviceID? = nil) -> AVAudioFormat? {
        use(device)
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    /// Starts recording; every buffer goes to `buffers`, and its level (0…1) to `levels`.
    @discardableResult
    func start(device: AudioDeviceID? = nil, buffers: @escaping BufferHandler,
               levels: @escaping LevelHandler) throws -> AVAudioFormat {
        use(device)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        lock.withLock {
            bufferHandler = buffers
            levelHandler = levels
            capturedFrames = 0
        }
        inputFormat = format
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        logger.info("Recording at \(format.sampleRate, privacy: .public) Hz, \(format.channelCount) ch")
        return format
    }

    /// Stops recording and returns how many frames it captured.
    @discardableResult
    func stop() -> AVAudioFramePosition {
        if engine.isRunning || inputFormat != nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return lock.withLock {
            bufferHandler = nil
            levelHandler = nil
            return capturedFrames
        }
    }

    /// Points the input at `device` (only while stopped); nil leaves it on the system's input.
    private func use(_ device: AudioDeviceID?) {
        guard !engine.isRunning, let unit = engine.inputNode.audioUnit else { return }
        var id = device ?? Self.systemInput() ?? 0
        guard id != 0 else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { logger.notice("Couldn't switch the microphone: \(status)") }
    }

    private static func systemInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr
        else { return nil }
        return id
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let level = Self.normalizedLevel(buffer)
        let (handler, levels) = lock.withLock { () -> (BufferHandler?, LevelHandler?) in
            if bufferHandler != nil { capturedFrames += AVAudioFramePosition(buffer.frameLength) }
            return (bufferHandler, levelHandler)
        }
        levels?(level)
        handler?(buffer)
    }

    /// RMS in dBFS mapped to 0…1 over -50…0 dB, as the iPhone's capture does.
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
            "Murmur can't find a microphone. Check Sound settings, or pick one in Murmur's settings."
        }
    }
}
