@preconcurrency import AVFoundation
import AppKit
import CoreAudio
import Foundation
import MurmurCore
import os

/// One dictation at a time on the Mac, start to finish: the shortcut opens the microphone, the
/// audio streams into the same transcriber and pipeline the iPhone uses (`OpenAITranscriber`,
/// `DictationPipeline`, the `dictate` function), and the text is typed where the user is
/// (`TextInserter`) and kept in the history.
@MainActor
@Observable
final class DictationEngine {
    enum Phase: Equatable {
        case idle
        case listening(handsFree: Bool)
        case processing
    }

    /// A short message on the floating bar after a dictation, or instead of one.
    struct Notice: Equatable, Identifiable {
        enum Kind: Equatable {
            case copied, signedOut, microphone, accessibility, consent, nothingHeard, failed, limitReached
            case nothingSelected, proRequired, unchanged
        }

        let kind: Kind
        let title: String
        var detail: String?
        let id = UUID()
    }

    private(set) var phase: Phase = .idle
    /// Command mode (the shortcut held with ⌃): the selection is rewritten by what's said.
    private(set) var commanding = false
    /// The microphone's level, 0…1, while listening.
    private(set) var level: Float = 0
    private(set) var notice: Notice?
    /// The last dictation's text, for "Paste last transcript".
    private(set) var lastText: String?
    /// Set briefly after a dictation was typed, for the bar's check mark.
    private(set) var justInserted = false
    /// Bumped when a dictation is added to the history, so lists showing it refresh.
    private(set) var historyRevision = 0
    /// When the current dictation started listening, for the bar's clock.
    private(set) var listeningSince: Date?
    /// The words of the last dictation typed, for the bar's "✓ 13 words".
    private(set) var insertedWords = 0

    /// Shorter recordings are a slip of the finger, not a dictation.
    static let minimumSeconds = 0.35
    /// A dictation can't run longer than this (the server's limit is the same).
    static let maximumSeconds: Double = 6 * 60

    @ObservationIgnored private let audio = MacAudioCapture()
    @ObservationIgnored private let pipeline: DictationPipeline
    @ObservationIgnored private let transcription: TranscriptionClient
    @ObservationIgnored private let dictate: DictateClient
    @ObservationIgnored private let warmup: BackendWarmup?
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let settings: SharedSettings
    @ObservationIgnored private let isSignedIn: () -> Bool
    @ObservationIgnored private let commandClient: CommandClient
    /// Pro or trial, as far as the app knows; nil before the plan has been read.
    @ObservationIgnored var hasPro: () -> Bool? = { nil }
    @ObservationIgnored private let consent: () async -> Bool
    @ObservationIgnored private var transcriber: OpenAITranscriber?
    @ObservationIgnored private var preparedFormat: AVAudioFormat?
    /// The dictation the shortcut is recording now; nil between dictations.
    @ObservationIgnored private var current: Recording?
    /// The last dictation's stop (microphone off, its utterance kept or dropped). The next one
    /// starts after it: a double tap's first tap is still stopping when hands-free begins.
    @ObservationIgnored private var teardown: Task<Void, Never>?
    @ObservationIgnored private var capTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "Engine")

    /// Called when the dictation ends some other way than the shortcut (✕, ✓, the cap, an error),
    /// so the hotkey forgets its press.
    @ObservationIgnored var onEndedOutsideShortcut: (() -> Void)?
    /// A dictation was typed (or only copied) into an app: its history id, the app, and whether
    /// it was only copied.
    @ObservationIgnored var onDelivered: ((UUID, String?, String?, Bool) -> Void)?

    init(pipeline: DictationPipeline, functions: EdgeFunctionClient?, backend: Backend?, history: HistoryStore,
         settings: SharedSettings = .shared, isSignedIn: @escaping () -> Bool,
         consent: @escaping () async -> Bool) {
        self.pipeline = pipeline
        transcription = TranscriptionClient(functions: functions)
        let dictate = DictateClient(functions: functions)
        self.dictate = dictate
        warmup = backend.map { BackendWarmup(session: $0, dictate: dictate) }
        commandClient = CommandClient(functions: functions)
        self.history = history
        self.settings = settings
        self.isSignedIn = isSignedIn
        self.consent = consent
    }

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    // MARK: Start

    /// The shortcut went down (push-to-talk) or was double-tapped (hands-free).
    func begin(handsFree: Bool) {
        guard phase == .idle else { return }
        guard isSignedIn() else {
            show(.init(kind: .signedOut, title: "You’re signed out", detail: "Open Redmic to sign in, and your words come back."))
            onEndedOutsideShortcut?()
            return
        }
        switch MacPermissions.microphone {
        case .authorized:
            break
        case .notDetermined:
            onEndedOutsideShortcut?()
            Task { _ = await MacPermissions.requestMicrophone() }
            return
        default:
            show(.init(kind: .microphone, title: "Redmic can't use the microphone",
                       detail: "Allow it in System Settings › Privacy & Security › Microphone."))
            onEndedOutsideShortcut?()
            return
        }
        guard MacConsent.isGranted else {
            // Asked before any recording, never in the middle of one.
            onEndedOutsideShortcut?()
            Task { _ = await consent() }
            return
        }
        notice = nil
        listeningSince = Date()
        phase = .listening(handsFree: handsFree)
        let recording = Recording()
        let front = NSWorkspace.shared.frontmostApplication
        recording.appName = front?.localizedName
        recording.bundleID = front?.bundleIdentifier
        current = recording
        let previous = teardown
        recording.startTask = Task {
            await previous?.value
            await start(recording)
        }
    }

    /// The shortcut went down with ⌃: rewrite the selection by what the user says.
    func beginCommand() {
        guard phase == .idle else { return }
        guard isSignedIn() else {
            show(.init(kind: .signedOut, title: "You’re signed out", detail: "Open Redmic to sign in, and your words come back."))
            onEndedOutsideShortcut?()
            return
        }
        guard hasPro() != false else {
            show(.init(kind: .proRequired, title: "Command mode is part of Pro",
                       detail: "Select text, hold the shortcut with ⌃ and say how to change it."))
            onEndedOutsideShortcut?()
            return
        }
        guard MacPermissions.microphone == .authorized, MacConsent.isGranted else {
            begin(handsFree: false)  // asks for what's missing, as a dictation would
            end(commit: false)
            return
        }
        notice = nil
        commanding = true
        listeningSince = Date()
        phase = .listening(handsFree: false)
        let recording = Recording()
        recording.command = CommandTake()
        current = recording
        let previous = teardown
        recording.startTask = Task {
            await previous?.value
            await start(recording)
        }
    }

    private func startCommand(_ recording: Recording, _ take: CommandTake) async {
        let selection = await SelectionReader.read()
        guard current === recording, isListening else { return }
        guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            current = nil
            phase = .idle
            commanding = false
            onEndedOutsideShortcut?()
            show(.init(kind: .nothingSelected, title: "Select some text first",
                       detail: "Then hold the shortcut with ⌃ and say how to change it."))
            return
        }
        take.selection = String(selection.prefix(8000))
        do {
            try audio.start(device: Self.pickedMicrophone(),
                            buffers: { [wav = take.wav] buffer in wav.append(buffer) },
                            levels: { [weak self] level in Task { @MainActor in self?.level = level } })
            recording.audioStarted = true
            playSound("Tink")
        } catch {
            current = nil
            phase = .idle
            commanding = false
            onEndedOutsideShortcut?()
            show(.init(kind: .failed, title: "Couldn't start the microphone", detail: error.localizedDescription))
        }
    }

    /// Hands-free was started with push-to-talk's press already recording: keep it, and stop
    /// on the next press instead of the release.
    func switchToHandsFree() {
        guard case .listening(false) = phase else { return }
        phase = .listening(handsFree: true)
    }

    private func start(_ recording: Recording) async {
        if let take = recording.command {
            await startCommand(recording, take)
            return
        }
        let requestId = recording.id
        do {
            let device = Self.pickedMicrophone()
            guard let format = audio.currentInputFormat(device: device) else { throw MacAudioCapture.CaptureError.noInput }
            let transcriber = try await readyTranscriber(for: format)
            // Ended while the transcriber got ready: nothing to record.
            guard current === recording, isListening else { return }
            let speak = KeyboardLanguageDefaults.source(
                saved: settings.translationSourceLanguage, autoDetectApplied: settings.autoDetectDefaultApplied)
            let target = settings.translationEnabled ? KeyboardLanguageDefaults.target(
                saved: settings.translationTargetLanguage.map(DictationLanguage.init(tag:)), source: speak,
                preferred: Locale.preferredLanguages, available: DictationLanguage.cloudLanguages,
                recent: settings.recentTranslationLanguages.map(DictationLanguage.init(tag:))) : nil
            let language = cloudLanguage(speak.tag)
            if transcriber.currentLanguage != language { transcriber.setLanguage(language) }
            transcriber.beginUtterance()
            try audio.start(
                device: device,
                buffers: { [transcriber] buffer in transcriber.append(buffer) },
                levels: { [weak self] level in Task { @MainActor in self?.level = level } })
            recording.dictation = ActiveDictation(
                requestId: requestId, documentIdentifier: nil, style: nil, language: language.tag,
                translationTargetLanguage: target?.tag, source: .keyboard, startedAt: Date())
            let writesWithModel = target != nil || settings.defaultStyle.usesModel
            if !NetworkConditions.shared.savesData(settings: settings) {
                warmup?.dictationDidStart(requestId, cloud: true, writesWithModel: writesWithModel)
            }
            capTask?.cancel()
            capTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.maximumSeconds))
                guard !Task.isCancelled else { return }
                self?.onEndedOutsideShortcut?()
                self?.end(commit: true)
            }
            playSound("Tink")
        } catch {
            logger.error("Couldn't start: \(error.localizedDescription, privacy: .public)")
            audio.stop()
            transcriber?.abandonUtterance()
            recording.dictation = nil
            if current === recording {
                current = nil
                phase = .idle
            }
            onEndedOutsideShortcut?()
            show(.init(kind: .failed, title: "Couldn't start the microphone", detail: error.localizedDescription))
        }
    }

    /// The transcriber, prepared for the microphone's format (again when the device changed).
    private func readyTranscriber(for format: AVAudioFormat) async throws -> OpenAITranscriber {
        if let transcriber, let preparedFormat, preparedFormat == format { return transcriber }
        let transcriber = self.transcriber ?? OpenAITranscriber(client: transcription, dictation: dictate)
        let speak = KeyboardLanguageDefaults.source(
            saved: settings.translationSourceLanguage, autoDetectApplied: settings.autoDetectDefaultApplied)
        try await transcriber.prepare(micFormat: format, language: cloudLanguage(speak.tag))
        self.transcriber = transcriber
        preparedFormat = format
        return transcriber
    }

    /// The microphone picked in Settings, if it's still connected; nil means the system's input.
    static func pickedMicrophone() -> AudioDeviceID? {
        MacSettings.shared.microphoneUID.flatMap { AudioInputs.device(uid: $0)?.id }
    }

    /// Prepares the transcriber ahead of the first dictation, so the first press records at once.
    func prepare() async {
        guard MacPermissions.microphone == .authorized,
              let format = audio.currentInputFormat(device: Self.pickedMicrophone()) else { return }
        _ = try? await readyTranscriber(for: format)
    }

    /// For the cloud the language is its tag, the dictionary as keyword hints, and under
    /// Auto-detect the languages picked in Settings (`SessionController.cloudLanguage`).
    private func cloudLanguage(_ tag: String) -> ResolvedLanguage {
        ResolvedLanguage(tag: tag, locale: Locale(identifier: tag), engine: .speech,
                         contextualStrings: pipeline.contextualStrings(),
                         languageHints: DictationLanguage(tag: tag).isAutomatic ? settings.dictationLanguages : [])
    }

    // MARK: End

    /// The shortcut came up (push-to-talk), was pressed again (hands-free), or ✓/✕ on the bar.
    func end(commit: Bool) {
        guard isListening, let recording = current else { return }
        current = nil
        capTask?.cancel()
        phase = commit ? .processing : .idle
        level = 0
        if let take = recording.command {
            endCommand(recording, take, commit: commit)
            return
        }
        // Microphone off and the utterance kept or dropped, after its start finished; the next
        // dictation waits for this.
        let stopped = Task { () -> Stopped? in
            await recording.startTask?.value
            guard let dictation = recording.dictation, let transcriber = self.transcriber else { return nil }
            let frames = audio.stop()
            let seconds = Double(frames) / (audio.inputFormat?.sampleRate ?? 48_000)
            guard commit, seconds >= Self.minimumSeconds else {
                transcriber.abandonUtterance()
                return nil
            }
            return Stopped(dictation: dictation, transcriber: transcriber, seconds: seconds)
        }
        teardown = Task { _ = await stopped.value }
        guard commit else { return }
        Task {
            guard let stop = await stopped.value else {
                phase = .idle
                return
            }
            playSound("Pop")
            let outcome = await pipeline.complete(
                stop.dictation, transcriber: stop.transcriber, audioSeconds: stop.seconds, stoppedAt: .now)
            history.record(outcome.transcript)
            if let typed = await deliver(outcome.result) {
                onDelivered?(outcome.transcript.id, recording.appName, recording.bundleID, typed == .copied)
            }
            historyRevision += 1
            phase = .idle
        }
    }

    /// How the text reached the app; nil when there was none to type.
    private func endCommand(_ recording: Recording, _ take: CommandTake, commit: Bool) {
        let stopped = Task { () -> (String, Data)? in
            await recording.startTask?.value
            guard recording.audioStarted else { return nil }
            audio.stop()
            guard commit, take.wav.seconds >= Self.minimumSeconds, let selection = take.selection else { return nil }
            return (selection, take.wav.wav())
        }
        teardown = Task { _ = await stopped.value }
        guard commit else {
            commanding = false
            return
        }
        Task {
            defer {
                phase = .idle
                commanding = false
            }
            guard let (selection, wav) = await stopped.value else { return }
            playSound("Pop")
            do throws(CommandClient.Failure) {
                let reply = try await commandClient.send(selection: selection, audio: wav, language: nil,
                                                         hints: settings.dictationLanguages)
                guard reply.status == "rewritten" else {
                    show(.init(kind: .unchanged, title: "Nothing changed",
                               detail: reply.instruction.isEmpty ? "Redmic didn’t catch what to do."
                                   : "“\(reply.instruction)” left the text as it was."))
                    return
                }
                lastText = reply.text
                if await TextInserter.insert(reply.text, language: nil, joining: false) == .copied {
                    show(.init(kind: .copied, title: "Copied. Press ⌘V to paste.", detail: "The selection had gone."))
                    return
                }
                insertedWords = WordCounter.count(reply.text)
                justInserted = true
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    justInserted = false
                }
            } catch .proRequired {
                show(.init(kind: .proRequired, title: "Command mode is part of Pro",
                           detail: "Upgrade to change any text by voice."))
            } catch .signedOut {
                show(.init(kind: .signedOut, title: "You’re signed out", detail: "Open Redmic to sign in."))
            } catch {
                show(.init(kind: .failed, title: "Couldn't change the text", detail: "Check your connection and try again."))
            }
        }
    }

    private func deliver(_ result: DictationResult) async -> TextInserter.Outcome? {
        guard result.isInsertable else {
            switch result.status {
            case .empty:
                show(.init(kind: .nothingHeard, title: "Redmic didn't catch that",
                           detail: "Hold fn while you speak, then let go."))
            case .cancelled:
                break
            case .limitReached:
                show(.init(kind: .limitReached, title: "You've used this week's free words",
                           detail: "Upgrade to Pro for unlimited words."))
            default:
                show(.init(kind: .failed, title: "Couldn't write that",
                           detail: result.message ?? "Check your connection and try again."))
            }
            return nil
        }
        lastText = result.text
        let outcome = await TextInserter.insert(result.text, language: result.language)
        switch outcome {
        case .pasted:
            insertedWords = WordCounter.count(result.text)
            justInserted = true
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                justInserted = false
            }
        case .copied:
            show(.init(kind: .copied, title: "Copied. Press ⌘V to paste.",
                       detail: "There was no text box to type into."))
        }
        // The last dictation before the words ran out went in; the next one won't.
        if result.message == Brand.limitReachedMessage {
            show(.init(kind: .limitReached, title: "You've used this week's free words",
                       detail: "Upgrade to Pro for unlimited words."))
        }
        return outcome
    }

    /// "Paste last transcript" (⌃⌘V, the menu).
    func pasteLast() async {
        guard let lastText else { return }
        _ = await TextInserter.insert(lastText, language: nil)
    }

    // MARK: Notices

    func show(_ notice: Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if self.notice?.id == notice.id { self.notice = nil }
        }
    }

    func dismissNotice() {
        notice = nil
    }

    #if DEBUG
    /// Screenshot runs (`-bar <state>`): the bar in one of its states, with nothing recording.
    func pinForScreenshot(_ state: String) {
        switch state {
        case "listening":
            phase = .listening(handsFree: false)
            level = 0.75
            listeningSince = Date().addingTimeInterval(-3)
        case "handsfree":
            phase = .listening(handsFree: true)
            level = 0.6
            listeningSince = Date().addingTimeInterval(-12)
        case "processing":
            phase = .processing
        case "inserted":
            insertedWords = 13
            justInserted = true
        case "copied":
            notice = Notice(kind: .copied, title: "Copied. Press ⌘V to paste.", detail: "There was no text box to type into.")
        case "signedout":
            notice = Notice(kind: .signedOut, title: "You’re signed out", detail: "Open Redmic to sign in, and your words come back.")
        case "command":
            commanding = true
            phase = .listening(handsFree: false)
            level = 0.6
            listeningSince = Date().addingTimeInterval(-2)
        case "limit":
            notice = Notice(kind: .limitReached, title: "You’ve used this week’s 1,000 words",
                            detail: "Upgrade to Pro for unlimited words, or wait until Monday.")
        default:
            break
        }
    }
    #endif

    /// One press of the shortcut, from start to stop.
    @MainActor
    private final class Recording {
        let id = UUID()
        /// Command mode's selection and instruction; nil for a dictation.
        var command: CommandTake?
        /// Command mode: the microphone started.
        var audioStarted = false
        /// The app in front when the shortcut went down: where the words are meant to go.
        var appName: String?
        var bundleID: String?
        var startTask: Task<Void, Never>?
        /// Set once the microphone records; nil if it never got that far.
        var dictation: ActiveDictation?
    }

    /// What was selected, and the instruction being recorded.
    private final class CommandTake {
        var selection: String?
        let wav = WavRecorder()
    }

    private struct Stopped {
        let dictation: ActiveDictation
        let transcriber: OpenAITranscriber
        let seconds: Double
    }

    private func playSound(_ name: String) {
        guard settings.interactionSounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
