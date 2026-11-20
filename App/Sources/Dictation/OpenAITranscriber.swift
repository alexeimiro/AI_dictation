@preconcurrency import AVFoundation
import Foundation
import MurmurCore
import os

/// Cloud recognition with OpenAI, through the `dictate` function: one request that transcribes a
/// dictation and, when it is translated or written in a style, writes it too. The older
/// `transcribe` function takes the audio whenever `dictate` can't.
///
/// The dictation's audio is kept as 16 kHz mono samples and sent in one request when it ends,
/// compressed to AAC. If the language's on-device model is already on the iPhone, an on-device
/// transcriber listens alongside and is used when the request fails (offline, a server error, a
/// signed-out account), so a dictation isn't lost. Never when the server refused the account (the
/// free plan's weekly words are used up, or too many dictations a minute), nor while the week's
/// words are known to be used up: the iPhone's own recognition would make the limit mean nothing.
/// The fallback's words are also what the keyboard shows while it listens (`LiveWordsProviding`).
///
/// Preparing the fallback takes a while, so a dictation can begin before it is ready: the first
/// one after the microphone turns on, or one right after a reconnect. The fallback takes such a
/// dictation up as soon as it is prepared (`joinDictationUnderWay`): it is handed everything
/// recorded so far, then the microphone's buffers. That dictation has its words a moment late
/// and is covered when the request fails, like any other.
final class OpenAITranscriber: Transcriber, UtteranceTimingProviding, RecordingProviding, LiveWordsProviding,
                               @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Shorter recordings are treated as silence instead of being sent.
    static let minimumSeconds: Double = 0.3
    /// After a connection failure, dictations go straight to the on-device fallback for this long
    /// instead of waiting on the network each time (an unreachable server can take the whole
    /// request timeout to fail).
    static let cloudPause: TimeInterval = 120

    private let client: any CloudTranscribing
    private let dictation: (any Dictating)?
    private let fallback: (any Transcriber)?
    /// Low data mode: the audio uploads at `EncodedAudio.lowDataBitRate`.
    private let savesData: @Sendable () -> Bool
    /// When the free words were last said to be used up until, while the server hasn't said they
    /// are back (`SharedSettings.wordsUsedUpUntil`): the fallback stays out of it meanwhile.
    private let wordsUsedUpUntil: @Sendable () -> Date?
    /// What the session knows before the transcriber does: a verified on-device model is on the
    /// iPhone for a dictation in this language. With it a dictation that begins before the
    /// fallback's languages are even known can be promised its words.
    private let expectsOnDevice: @Sendable (ResolvedLanguage) -> Bool
    /// After a preparation of the fallback came to nothing (no model for the language, or the
    /// model didn't load), it is tried again as a dictation begins, at most this often. A language
    /// that turns up meanwhile is prepared at once.
    private let fallbackRetryPause: TimeInterval
    /// A dictation that has run this long is not taken up by a fallback that is only ready now:
    /// the recognizer would be busy with the past for too long to show anything of the present.
    private let lateJoinLimit: Duration
    private let lock = NSLock()
    /// Held by whoever begins, ends or joins the fallback's part of a dictation, so a join never
    /// begins a part that was just ended, nor ends the next dictation's. Taken before `lock`,
    /// never inside it, and nothing is awaited under it.
    private let fallbackGate = NSLock()
    private let logger = Logger(subsystem: "Murmur", category: "CloudASR")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: OpenAITranscriber.sampleRate, channels: 1, interleaved: false)!
    private var language: ResolvedLanguage?
    private var converter: AVAudioConverter?
    private var micFormat: AVAudioFormat?
    /// Bumped by every `prepare`, so a fallback preparation for an older mic format that finishes
    /// late doesn't mark the fallback ready.
    private var generation = 0
    private var samples: [Float] = []
    private var capturing = false
    /// On-device languages the fallback can recognize, by tag.
    private var fallbackLanguages: [String: ResolvedLanguage]
    /// What the fallback listens in under Auto-detect, when only the cloud knows the language
    /// (`setAutomaticFallback`).
    private var automaticFallback: ResolvedLanguage?
    private var fallbackPrepared = false
    /// The session has asked for the fallback (`prepareFallback`). From then on it is prepared
    /// again whenever it can be and isn't: a language turns up, the guess under Auto-detect
    /// changes, or a dictation begins some time after an attempt that came to nothing.
    private var fallbackWanted = false
    /// The preparation under way: there is only ever one.
    private var preparing: Task<Void, Never>?
    /// Something the preparation under way may have missed has changed (a language turned up, the
    /// guess changed): if it comes to nothing, it looks once more before it ends.
    private var looksAgain = false
    /// When the last preparation since `prepare` came to nothing. While it is set no dictation is
    /// promised words it may not get.
    private var fallbackFailedAt: Date?
    /// The fallback has a part in the current dictation, which whoever ends the dictation ends,
    /// exactly once (`claimFallback`, `abandonUtterance`, the next `begin`).
    private var fallbackListening = false
    /// The microphone's buffers go straight to the fallback. False while it has no part in the
    /// dictation, and while one it took up late is still being handed what was recorded before.
    private var fallbackFeeding = false
    /// The on-device language the fallback's part of the current dictation is in: its transcript's
    /// language under Auto-detect, whatever the guess has become since.
    private var listeningLanguage: ResolvedLanguage?
    /// The dictation under way began before the fallback was prepared and was promised its words:
    /// the fallback takes it up when it is prepared (`joinDictationUnderWay`).
    private var lateJoin: (utterance: Int, handler: LiveWordsHandler, began: ContinuousClock.Instant)?
    private var cloudPausedUntil: Date?
    /// Bumped by every `beginUtterance` and `abandonUtterance`, so a finish or a buffer that
    /// outlives its dictation doesn't report into the next one.
    private var utteranceNumber = 0
    /// The last finished dictation's measurements, until `takeTimings`.
    private var timings: UtteranceTimings?
    /// The last finished dictation's audio as uploaded, until `takeRecording`.
    private var recording: EncodedAudio?

    /// `dictation`: transcribes, and translates or writes in a style, in one request; without it
    /// every dictation goes to `client` for its transcript. `fallbackLanguages`: languages whose
    /// on-device model is installed and verified. `wordsUsedUpUntil`: the account's free words were
    /// said to be used up and the server hasn't said otherwise since, so a dictation the cloud can't
    /// take isn't recognized on the iPhone either. `expectsOnDevice`: the iPhone holds a verified
    /// model for a dictation in that language, as far as the session knows without asking Apple's
    /// framework; a dictation that begins before the fallback is prepared is promised its words
    /// on that (or on a language already in `fallbackLanguages`). `fallbackRetryPause` and
    /// `lateJoinLimit`: tests shorten them.
    init(client: any CloudTranscribing, dictation: (any Dictating)? = nil, fallback: (any Transcriber)? = nil,
         fallbackLanguages: [String: ResolvedLanguage] = [:],
         savesData: @escaping @Sendable () -> Bool = { NetworkConditions.shared.savesData() },
         wordsUsedUpUntil: @escaping @Sendable () -> Date? = { nil },
         expectsOnDevice: @escaping @Sendable (ResolvedLanguage) -> Bool = { _ in false },
         fallbackRetryPause: TimeInterval = 30, lateJoinLimit: Duration = .seconds(60)) {
        self.client = client
        self.dictation = dictation
        self.fallback = fallback
        self.fallbackLanguages = fallbackLanguages
        self.savesData = savesData
        self.wordsUsedUpUntil = wordsUsedUpUntil
        self.expectsOnDevice = expectsOnDevice
        self.fallbackRetryPause = fallbackRetryPause
        self.lateJoinLimit = lateJoinLimit
    }

    var displayName: String {
        lock.withLock { fallbackPrepared ? "OpenAI (on-device fallback)" : "OpenAI" }
    }

    var currentLanguage: ResolvedLanguage? {
        lock.withLock { language }
    }

    /// A language whose on-device model became ready after the session started. A fallback that
    /// was waiting for one is prepared now.
    func addFallbackLanguage(_ language: ResolvedLanguage) {
        let prepares = lock.withLock { () -> Bool in
            fallbackLanguages[language.tag] = language
            return asksForPreparation()
        }
        if prepares { prepareFallbackAgain() }
    }

    /// Under Auto-detect a failed request can only be covered by a guess: the session names the
    /// installed language most likely spoken (nil: no fallback under Auto).
    func setAutomaticFallback(_ language: ResolvedLanguage?) {
        let (switchTo, prepares) = lock.withLock { () -> (ResolvedLanguage?, Bool) in
            let changed = automaticFallback != language
            automaticFallback = language
            guard changed, self.language?.language.isAutomatic == true else { return (nil, false) }
            // Not prepared: a guess that has a model is what the preparation was waiting for.
            guard fallbackPrepared else { return (nil, language != nil && asksForPreparation()) }
            // A dictation that listens in the old guess, or waits to be taken up in it, keeps it:
            // switching the recognizer under it would drop its audio. The next dictation's
            // `begin` makes the switch.
            guard !fallbackListening, lateJoin == nil else { return (nil, false) }
            return (language, false)
        }
        if let switchTo { fallback?.setLanguage(switchTo) }
        if prepares { prepareFallbackAgain() }
    }

    /// The on-device language that covers a dictation in `language`: its own model, else the
    /// model of the same language for another region (en-GB hears en-US well enough for words on
    /// the keyboard and for a request that failed). Call under the lock.
    private func onDeviceLanguage(for language: ResolvedLanguage) -> ResolvedLanguage? {
        if language.language.isAutomatic { return automaticFallback }
        if let exact = fallbackLanguages[language.tag] { return exact }
        let code = language.language.languageCode
        return fallbackLanguages.values.filter { $0.language.languageCode == code }.min { $0.tag < $1.tag }
    }

    /// The fallback was asked for, isn't prepared, and nobody is preparing it. Call under the lock.
    private var needsPreparation: Bool { fallbackWanted && !fallbackPrepared && preparing == nil }

    /// Something a preparation was waiting for has turned up. True when a new one is to be
    /// started now; one under way took its bearings before the change, so it is told to look
    /// again when it is done. Call under the lock.
    private func asksForPreparation() -> Bool {
        guard fallbackWanted, !fallbackPrepared else { return false }
        if preparing != nil {
            looksAgain = true
            return false
        }
        return true
    }

    /// Another attempt, for a language that turned up, a guess that changed or a pause that is
    /// over: `prepareFallback` finds out whether there is anything to prepare now.
    private func prepareFallbackAgain() {
        Task { await self.prepareFallback() }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: Transcriber

    /// Only what the cloud needs, so the session is ready quickly; the on-device fallback is
    /// prepared separately (`prepareFallback`).
    func prepare(micFormat: AVAudioFormat, language: ResolvedLanguage) async throws {
        guard let converter = AVAudioConverter(from: micFormat, to: targetFormat) else {
            throw CloudTranscriptionError.unavailable("Unsupported microphone format")
        }
        lock.withLock {
            self.converter = converter
            self.language = language
            self.micFormat = micFormat
            generation += 1
            fallbackPrepared = false
            fallbackFailedAt = nil
        }
    }

    /// Prepares the installed on-device model for the current language. It takes a while, so the
    /// session calls it once it's ready. A dictation that began meanwhile and was promised its
    /// words is taken up when this succeeds (`joinDictationUnderWay`). Only one preparation runs
    /// at a time: a second caller waits for it, then looks again.
    func prepareFallback() async {
        while true {
            let (task, own) = lock.withLock { () -> (Task<Void, Never>, Bool) in
                fallbackWanted = true
                if let preparing { return (preparing, false) }
                let task = Task { await self.runFallbackPreparation() }
                preparing = task
                return (task, true)
            }
            await task.value
            // The attempt waited for was begun for a format or a language that may have been
            // replaced since: this caller makes its own, which returns at once when nothing is
            // left to do.
            if own { return }
        }
    }

    private func runFallbackPreparation() async {
        while true {
            await attemptFallbackPreparation()
            // The hold that finds nothing more to look at is the one that ends the preparation:
            // whoever turns up after it starts the next one.
            let again = lock.withLock { () -> Bool in
                let again = looksAgain && !fallbackPrepared
                looksAgain = false
                if !again { preparing = nil }
                return again
            }
            if !again { return }
        }
    }

    private func attemptFallbackPreparation() async {
        let (micFormat, onDevice, generation, prepared) = lock.withLock {
            (self.micFormat, language.flatMap(onDeviceLanguage(for:)), self.generation, fallbackPrepared)
        }
        guard !prepared, let fallback, let micFormat else { return }
        guard let onDevice else {
            // No model for the language (yet). `addFallbackLanguage` and `setAutomaticFallback`
            // bring the next attempt when one turns up.
            lock.withLock { if self.generation == generation { fallbackFailedAt = Date() } }
            logger.info("On-device fallback: no model for the language yet")
            return
        }
        let started = ContinuousClock.now
        do {
            try await fallback.prepare(micFormat: micFormat, language: onDevice)
        } catch {
            lock.withLock { if self.generation == generation { fallbackFailedAt = Date() } }
            logger.notice("On-device fallback unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Prepared for a microphone format a newer `prepare` has replaced: the session asks again.
        let (current, wanted) = lock.withLock { () -> (Bool, ResolvedLanguage?) in
            guard self.generation == generation else { return (false, nil) }
            fallbackPrepared = true
            fallbackFailedAt = nil
            return (true, language.flatMap(onDeviceLanguage(for:)))
        }
        guard current else { return }
        logger.info("On-device fallback ready for \(onDevice.tag, privacy: .public) in \(started.elapsedMilliseconds) ms")
        if let wanted, wanted != onDevice {
            // The language moved on while the model loaded (a guess that changed): the fallback
            // follows it for the next dictation. The one under way is not taken up in a language
            // it isn't in, so its promise goes.
            lock.withLock { lateJoin = nil }
            fallback.setLanguage(wanted)
            logger.info("On-device fallback switched to \(wanted.tag, privacy: .public) before its first dictation")
            return
        }
        joinDictationUnderWay(in: onDevice)
    }

    /// The fallback has just been prepared, and a dictation that was promised its words is still
    /// being recorded: the fallback takes it up. It is handed the recording so far, piece by
    /// piece, while the microphone's new buffers go on into the recording only; the lock hold
    /// that finds nothing left to hand over is the one that lets the microphone's buffers through
    /// (`fallbackFeeding`), so nothing reaches the fallback twice, late or out of order. All of it
    /// inside `fallbackGate`: the dictation can't end, and the next can't begin, in between.
    private func joinDictationUnderWay(in onDevice: ResolvedLanguage) {
        let shown = wordsUsedUpUntil() == nil
        fallbackGate.withLock {
            let job = lock.withLock { () -> (handler: LiveWordsHandler, waited: Duration)? in
                guard let late = lateJoin else { return nil }
                lateJoin = nil
                let waited = ContinuousClock.now - late.began
                guard fallbackPrepared, late.utterance == utteranceNumber, capturing, shown,
                      waited < lateJoinLimit else { return nil }
                // From here the dictation's end ends the fallback's part too, exactly once.
                fallbackListening = true
                listeningLanguage = onDevice
                return (late.handler, waited)
            }
            guard let job else { return }
            guard let fallback = fallback as? (any ReplayableTranscriber & LiveWordsProviding),
                  fallback.beginUtterance(liveWords: job.handler) else {
                return giveUpJoin(why: "the fallback takes no dictation under way")
            }
            var replayed = 0
            while true {
                let piece = lock.withLock { () -> [Float]? in
                    if replayed == samples.count {
                        fallbackFeeding = true
                        return nil
                    }
                    defer { replayed = samples.count }
                    return Array(samples[replayed...])
                }
                guard let piece else { break }
                guard fallback.appendRecorded(piece[...], sampleRate: Self.sampleRate) else {
                    return giveUpJoin(why: "its analyzer wasn't ready")
                }
            }
            let seconds = Double(replayed) / Self.sampleRate
            logger.info("Live words: joined \(Self.milliseconds(job.waited)) ms into the dictation, \(seconds, format: .fixed(precision: 1)) s replayed")
        }
    }

    /// The fallback couldn't take the dictation up after all: its part ends here, so the dictation
    /// goes on as one without a fallback. Call inside `fallbackGate`.
    private func giveUpJoin(why reason: String) {
        lock.withLock {
            fallbackListening = false
            fallbackFeeding = false
            listeningLanguage = nil
        }
        fallback?.abandonUtterance()
        logger.notice("Live words: not joined, \(reason, privacy: .public)")
    }

    func setLanguage(_ language: ResolvedLanguage) {
        let (onDevice, prepares) = lock.withLock { () -> (ResolvedLanguage?, Bool) in
            self.language = language
            let onDevice = onDeviceLanguage(for: language)
            // Not prepared: a language that has a model is what the preparation was waiting for.
            guard fallbackPrepared else { return (nil, onDevice != nil && asksForPreparation()) }
            return (onDevice, false)
        }
        if let onDevice { fallback?.setLanguage(onDevice) }
        if prepares { prepareFallbackAgain() }
    }

    func beginUtterance() { _ = begin(liveWords: nil) }

    /// The words come from the on-device model that listens beside the cloud, so there are none when
    /// it isn't listening. Nor while the week's words were said to be used up and the server hasn't
    /// said they are back: the fallback still listens as before, but nothing it hears is shown.
    func beginUtterance(liveWords handler: @escaping LiveWordsHandler) -> Bool { begin(liveWords: handler) }

    private func begin(liveWords handler: LiveWordsHandler?) -> Bool {
        // Asked outside the locks: both read the session's settings.
        let shown = handler != nil && wordsUsedUpUntil() == nil
        let expected = lock.withLock { language }.map(expectsOnDevice) ?? false
        let joins = fallback is (any ReplayableTranscriber & LiveWordsProviding)
        let now = Date()
        return fallbackGate.withLock {
            let plan = lock.withLock {
                () -> (unended: Bool, wanted: ResolvedLanguage?, listens: Bool, promised: Bool, prepares: Bool) in
                // The last dictation's part, when a reconnect let this one begin while that one was
                // still uploading: its finish can no longer claim it, so it's ended here.
                let unended = fallbackListening
                samples.removeAll(keepingCapacity: true)
                capturing = true
                utteranceNumber += 1
                timings = nil
                recording = nil
                lateJoin = nil
                // The fallback only helps when it recognizes the dictation's language (or, under
                // Auto-detect, the language it is most likely in).
                let wanted = language.flatMap(onDeviceLanguage(for:))
                fallbackListening = fallbackPrepared && wanted != nil
                fallbackFeeding = fallbackListening
                listeningLanguage = fallbackListening ? wanted : nil
                guard !fallbackPrepared else { return (unended, wanted, fallbackListening, false, false) }
                // Not prepared yet. When it can be expected (no attempt has come to nothing since
                // `prepare`, and a model is known for the language), the dictation is promised
                // its words and taken up when the fallback is ready.
                var promised = false
                if shown, joins, fallbackFailedAt == nil, wanted != nil || expected, let handler {
                    lateJoin = (utteranceNumber, handler, .now)
                    promised = true
                }
                let due = fallbackFailedAt.map { now.timeIntervalSince($0) >= fallbackRetryPause } ?? true
                return (unended, wanted, false, promised, needsPreparation && due)
            }
            if plan.unended { fallback?.abandonUtterance() }
            if plan.prepares { prepareFallbackAgain() }
            guard plan.listens, let fallback else {
                if handler != nil {
                    let why = plan.promised ? "later, the on-device model is still loading"
                        : shown ? "none, no on-device model listens" : "none, the week's words wait for the server"
                    logger.info("Live words: \(why, privacy: .public)")
                }
                return plan.promised
            }
            // The fallback may still be set to another language: one changed while it wasn't
            // prepared, or a guess that changed while the last dictation listened.
            if let wanted = plan.wanted, fallback.currentLanguage != wanted { fallback.setLanguage(wanted) }
            if shown, let handler, let live = fallback as? LiveWordsProviding {
                logger.info("Live words: now, in \(plan.wanted?.tag ?? "?", privacy: .public)")
                return live.beginUtterance(liveWords: handler)
            }
            fallback.beginUtterance()
            if handler != nil { logger.info("Live words: none, the week's words wait for the server") }
            return false
        }
    }

    /// Audio thread (and, for the pre-roll as a dictation begins, the thread that begins it).
    func append(_ buffer: AVAudioPCMBuffer) {
        let (converter, capturing, utterance) = lock.withLock { (self.converter, self.capturing, utteranceNumber) }
        guard capturing, let converter else { return }
        let converted = convert(buffer, with: converter)
        // One lock hold takes the buffer into the recording and finds out whether the fallback is
        // fed directly. A dictation the fallback took up late is handed the recording first
        // (`joinDictationUnderWay`): this buffer is then either part of that, or goes after it.
        let feeds = lock.withLock { () -> Bool in
            // Not into a dictation that was abandoned, or began, while this buffer was converted.
            guard utteranceNumber == utterance else { return false }
            if let converted, let channel = converted.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            }
            return fallbackFeeding
        }
        if feeds { fallback?.append(buffer) }
    }

    func finishUtterance() async throws -> String {
        try await finish(model: nil, dictationId: nil).transcript
    }

    /// With a request and `dictate` available, the transcript and the model's text from one
    /// request. Otherwise, and whenever the on-device fallback answers, the transcript alone.
    func finishUtterance(model request: ModelRequest?) async throws -> UtteranceOutput {
        try await finish(model: request, dictationId: request?.dictationId)
    }

    /// As above, naming the dictation whatever it asks for: Word for word has no model request to
    /// carry its id, and its words are counted under it by the function that transcribes it,
    /// `dictate` when that can, else `transcribe`.
    func finishUtterance(model request: ModelRequest?, dictationId: UUID) async throws -> UtteranceOutput {
        try await finish(model: request, dictationId: dictationId)
    }

    private func finish(model request: ModelRequest?, dictationId: UUID?) async throws -> UtteranceOutput {
        // Inside the gate: a fallback that is taking this dictation up is handed the whole
        // recording first, and none can begin to once the recording has ended.
        let (pcm, language, paused, utterance, onDevice) = fallbackGate.withLock {
            lock.withLock { () -> ([Float], ResolvedLanguage?, Bool, Int, ResolvedLanguage?) in
                capturing = false
                lateJoin = nil
                let taken = samples
                samples.removeAll(keepingCapacity: true)
                return (taken, self.language, cloudPausedUntil.map { $0 > Date() } ?? false, utteranceNumber,
                        listeningLanguage)
            }
        }
        let automatic = language?.language.isAutomatic == true
        // Under Auto-detect the fallback's transcript is in the language it listened in.
        let fallbackDetected = automatic ? onDevice?.tag : nil
        guard Double(pcm.count) >= Self.sampleRate * Self.minimumSeconds else {
            if claimFallback(of: utterance) { fallback?.abandonUtterance() }
            return UtteranceOutput(transcript: "")
        }
        if paused, claimFallback(of: utterance), let fallback {
            // Offline with the week's words used up: nothing stands in for the cloud.
            if let refusal = refusalWhileWordsAwaitServer(
                otherwise: CloudTranscriptionError.unavailable("The cloud is paused after a failure.")) {
                fallback.abandonUtterance()
                throw refusal
            }
            return UtteranceOutput(transcript: try await fallback.finishUtterance(), detectedLanguage: fallbackDetected)
        }
        do {
            let encodeStarted = ContinuousClock.now
            let bitRate = savesData() ? EncodedAudio.lowDataBitRate : EncodedAudio.standardBitRate
            let audio = try EncodedAudio(samples: pcm, sampleRate: Self.sampleRate, bitRate: bitRate)
            var measured = UtteranceTimings(encodeMs: encodeStarted.elapsedMilliseconds, audioBytes: audio.data.count)
            record(measured, for: utterance)
            keep(audio, for: utterance)
            let spoken = automatic ? nil : language?.tag
            let hints = automatic ? language?.languageHints ?? [] : []
            let keywords = language?.contextualStrings ?? []
            // What OpenAI heard matters only when it chose the language.
            let detected = { (languages: [String]) in automatic ? languages.first.map(DictationLanguage.normalize) : nil }
            let output: UtteranceOutput
            let timing: RequestTiming?
            if let request,
               let reply = try await dictated(audio, language: spoken, hints: hints, keywords: keywords,
                                              request: request) {
                // The words left come with the model's part of the reply (`modelReply`).
                output = UtteranceOutput(transcript: reply.transcript, modelReply: reply.modelReply,
                                         detectedLanguage: detected(reply.languages), heardInCloud: true)
                timing = reply.timing
            } else {
                // Word for word asks `dictate` for the transcript alone. A dictation the model was
                // to write, which `dictate` couldn't take, goes to `transcribe` as it always did.
                let transcript: CloudTranscript
                if request == nil, let dictationId,
                   let alone = try await transcribedAlone(audio, language: spoken, hints: hints, keywords: keywords,
                                                          dictationId: dictationId) {
                    transcript = alone
                } else {
                    transcript = try await client.transcribe(
                        audio: audio.data, format: audio.format, language: spoken, languageHints: hints,
                        keywords: keywords, dictationId: dictationId)
                }
                output = UtteranceOutput(transcript: transcript.text, detectedLanguage: detected(transcript.languages),
                                         heardInCloud: true, wordsLeft: transcript.remaining)
                timing = transcript.timing
            }
            measured.requests = timing.map { [$0] } ?? []
            measured.cloudTranscript = true
            record(measured, for: utterance)
            lock.withLock { cloudPausedUntil = nil }
            if claimFallback(of: utterance) { fallback?.abandonUtterance() }
            return output
        } catch CloudTranscriptionError.cancelled {
            // The dictation is being dropped, or another path already answered: the service isn't
            // at fault, and nobody is waiting for an on-device transcript.
            if claimFallback(of: utterance) { fallback?.abandonUtterance() }
            throw CloudTranscriptionError.cancelled
        } catch {
            if case .unavailable = error as? CloudTranscriptionError {
                lock.withLock { cloudPausedUntil = Date().addingTimeInterval(Self.cloudPause) }
            }
            recordFailure(error, for: utterance)
            guard claimFallback(of: utterance), let fallback else { throw error }
            // The server refused the account, or the week's words were used up and it hasn't said
            // they're back: the iPhone's own recognition doesn't stand in, or the limit would mean nothing.
            if (error as? CloudTranscriptionError)?.refusesAccount == true {
                fallback.abandonUtterance()
                throw error
            }
            if let refusal = refusalWhileWordsAwaitServer(otherwise: error) {
                fallback.abandonUtterance()
                throw refusal
            }
            logger.notice("Cloud transcription failed, using on-device: \(error.localizedDescription, privacy: .public)")
            return UtteranceOutput(transcript: try await fallback.finishUtterance(), detectedLanguage: fallbackDetected)
        }
    }

    /// `dictate`'s reply, or nil to send the same audio to `transcribe`: `dictate` is unavailable,
    /// or has just answered that it isn't deployed. Its other failures are the cloud's, as
    /// `transcribe`'s are.
    private func dictated(_ audio: EncodedAudio, language: String?, hints: [String], keywords: [String],
                          request: ModelRequest) async throws -> DictateReply? {
        guard let dictation, await dictation.isAvailable else { return nil }
        do {
            return try await dictation.dictate(
                audio: audio.data, format: audio.format, language: language, languageHints: hints,
                keywords: keywords, request: request)
        } catch {
            // Rethrown by hand: Swift 6.3.3's optimizer crashes (OSSACompleteLifetime) on the
            // implicit rethrow of the other typed errors after `catch .notDeployed`, in Release only.
            guard error == .notDeployed else { throw error }
            logger.notice("dictate isn't deployed; transcribing and writing in two requests")
            return nil
        }
    }

    /// A Word for word dictation's transcript from `dictate`, or nil to send the same audio to
    /// `transcribe`: `dictate` is unavailable, can't transcribe alone, or couldn't run its checks.
    private func transcribedAlone(_ audio: EncodedAudio, language: String?, hints: [String], keywords: [String],
                                  dictationId: UUID) async throws -> CloudTranscript? {
        guard let dictation, await dictation.transcribesAlone else { return nil }
        do {
            return try await dictation.transcribe(
                audio: audio.data, format: audio.format, language: language, languageHints: hints,
                keywords: keywords, dictationId: dictationId)
        } catch {
            // Rethrown by hand, as in `dictated`.
            guard error == .notDeployed else { throw error }
            logger.notice("dictate didn't transcribe alone; sending the audio to transcribe")
            return nil
        }
    }

    func cancelUtterance() async {
        let listening = fallbackGate.withLock {
            lock.withLock { () -> Bool in
                capturing = false
                samples.removeAll(keepingCapacity: true)
                lateJoin = nil
                fallbackFeeding = false
                return fallbackListening
            }
        }
        if listening { await fallback?.cancelUtterance() }
    }

    /// Under the lock, so audio and a finish still under way for this dictation find it gone: no
    /// samples or timings kept (`utteranceNumber` moves on), and the fallback's part ended once,
    /// here.
    func abandonUtterance() {
        fallbackGate.withLock {
            let listening = lock.withLock { () -> Bool in
                capturing = false
                samples.removeAll(keepingCapacity: true)
                utteranceNumber += 1
                timings = nil
                recording = nil
                lateJoin = nil
                fallbackFeeding = false
                defer { fallbackListening = false }
                return fallbackListening
            }
            if listening { fallback?.abandonUtterance() }
        }
    }

    func shutdown() async {
        await fallback?.shutdown()
    }

    /// Why the fallback may not answer, while the words were said to be used up and the server
    /// hasn't said they're back: the limit until the reset; past it (by the iPhone's clock), the
    /// cloud's own failure, since only the server can say the words are back. Nil: it may.
    private func refusalWhileWordsAwaitServer(otherwise failure: any Error) -> (any Error)? {
        guard let until = wordsUsedUpUntil() else { return nil }
        return until > Date() ? CloudTranscriptionError.limitReached : failure
    }

    /// Whether the fallback still listens to `utterance`, handing it to the caller to end if so.
    /// False once that dictation was abandoned (which ended it) or a newer one began, so a finish
    /// that outlives its dictation never ends or uses the next one's.
    private func claimFallback(of utterance: Int) -> Bool {
        lock.withLock {
            guard utteranceNumber == utterance, fallbackListening else { return false }
            fallbackListening = false
            fallbackFeeding = false
            return true
        }
    }

    // MARK: Timings

    func takeTimings() -> UtteranceTimings? {
        lock.withLock {
            defer { timings = nil }
            return timings
        }
    }

    func takeRecording() -> EncodedAudio? {
        lock.withLock {
            defer { recording = nil }
            return recording
        }
    }

    /// Keeps `audio` for `takeRecording`, unless a newer dictation has begun meanwhile.
    private func keep(_ audio: EncodedAudio, for utterance: Int) {
        lock.withLock {
            if utteranceNumber == utterance { recording = audio }
        }
    }

    /// Keeps `measured` for `takeTimings`, unless a newer dictation has begun meanwhile.
    private func record(_ measured: UtteranceTimings, for utterance: Int) {
        lock.withLock {
            if utteranceNumber == utterance { timings = measured }
        }
    }

    /// Adds why the request failed to `utterance`'s timings, for the pipeline to tell the user.
    private func recordFailure(_ error: any Error, for utterance: Int) {
        lock.withLock {
            if utteranceNumber == utterance { timings?.cloudFailure = error as? CloudTranscriptionError }
        }
    }

    // MARK: Audio

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }
        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil else { return nil }
        return output
    }
}

/// A dictation's audio, ready to upload: AAC in an M4A container, or WAV if AAC encoding fails.
struct EncodedAudio: Sendable {
    enum Format: String, Sendable, CaseIterable {
        case m4a, wav
    }

    let data: Data
    let format: Format

    /// 32 kbps mono AAC: about 4 KB a second, so even a five-minute dictation uploads quickly.
    static let standardBitRate = 32_000
    /// Low data mode: half that, still clear speech at 16 kHz.
    static let lowDataBitRate = 16_000

    init(data: Data, format: Format) {
        self.data = data
        self.format = format
    }

    init(samples: [Float], sampleRate: Double, bitRate: Int = EncodedAudio.standardBitRate) throws {
        if let aac = try? Self.aac(samples, sampleRate: sampleRate, bitRate: bitRate) {
            data = aac
            format = .m4a
        } else {
            data = Self.wav(samples, sampleRate: sampleRate)
            format = .wav
        }
    }

    static func aac(_ samples: [Float], sampleRate: Double, bitRate: Int = standardBitRate) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw CloudTranscriptionError.unavailable("Couldn't allocate audio")
            }
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
            file.close()
        }
        return try Data(contentsOf: url)
    }

    /// 16-bit PCM WAV.
    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        let byteCount = UInt32(samples.count * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(rate)
        append(rate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}
