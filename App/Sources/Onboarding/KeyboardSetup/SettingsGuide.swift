@preconcurrency import AVFoundation
@preconcurrency import AVKit
import MurmurUI
import Observation
import os
import SwiftUI
import UIKit

/// The steps to take in Settings, kept on screen while the user takes them. iOS lets no app draw
/// over Settings; a Picture in Picture window is the one thing that floats over it. So the card
/// is a video frame: `open` lifts it off the page into the window and then opens Settings, and
/// coming back to Murmur closes it. Where there can be no window (iPhone simulators, a start
/// that fails) Settings opens on its own, as before.
///
/// iOS ends Murmur the moment Allow Full Access is switched on, and the window goes with it:
/// nothing here can keep it up past that tap.
@MainActor
@Observable
final class SettingsGuide {
    enum Variant: CaseIterable {
        /// The keyboard page: Keyboards, Murmur, Allow Full Access.
        case enableKeyboard
        /// The practice page's hint: Full Access, once the keyboard has run.
        case fullAccess

        var lines: [OnboardingCopy.Guide.Line] {
            switch self {
            case .enableKeyboard: OnboardingCopy.Guide.enableKeyboard
            case .fullAccess: OnboardingCopy.Guide.fullAccess
            }
        }

        /// A glyph per line.
        var symbols: [String] {
            switch self {
            case .enableKeyboard: ["keyboard", "switch.2", "switch.2", "checkmark.circle"]
            case .fullAccess: ["keyboard", "switch.2", "checkmark.circle", "arrow.uturn.backward"]
            }
        }
    }

    enum Phase: Equatable {
        case idle
        /// The card is on the page, and the window is being made possible.
        case preparing
        /// The window was asked to start.
        case starting
        /// The window said it is starting: it takes the card off the page.
        case lifting
        /// The window is up and Settings was opened.
        case presenting
        /// Back in Murmur: the window is landing on the card.
        case returning
    }

    private(set) var phase = Phase.idle
    /// The card shows on the page until the window takes it, and again for the window to land
    /// on. (The view stays mounted in between, unseen: its layer is the window's.)
    var showsCard: Bool { phase == .preparing || phase == .starting || phase == .returning }
    /// The dim behind the card, which stays while the window lifts off.
    var showsBackdrop: Bool { showsCard || phase == .lifting }
    /// The card as a picture, for the page. The layer under it belongs to the window, and once
    /// the window has it iOS draws its own placeholder there ("This video is playing in picture
    /// in picture"), which the page must never show.
    private(set) var card: CGImage?

    /// The view whose layer the window shows; one for the guide's lifetime, mounted by the overlay.
    let displayView = GuideDisplayView()

    @ObservationIgnored private let isSupported: () -> Bool
    @ObservationIgnored private let openURL: () -> Void
    @ObservationIgnored private let sessionIsLive: () -> Bool
    @ObservationIgnored private var frame: GuideFrame?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    /// The controller keeps both of these weakly.
    @ObservationIgnored private var playback: GuidePlaybackDelegate?
    @ObservationIgnored private var events: GuideControllerDelegate?
    @ObservationIgnored private var ownsAudioSession = false
    @ObservationIgnored private var trip: Task<Void, Never>?
    @ObservationIgnored private var starter: Task<Void, Never>?
    @ObservationIgnored private var keepAlive: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "Murmur", category: "SettingsGuide")
    /// When the trip began: the log counts from the tap.
    @ObservationIgnored private var began = ContinuousClock.now

    /// How long the window gets to become possible, then to start, then to land.
    nonisolated static let patience: Duration = .seconds(2)
    /// How soon the start is asked again while the window hasn't said it is starting.
    nonisolated static let startRetry: Duration = .milliseconds(120)

    /// `openURL` opens Settings. `sessionIsLive`: Murmur's microphone session is on, and owns
    /// the audio session.
    init(isSupported: @escaping () -> Bool = { AVPictureInPictureController.isPictureInPictureSupported() },
         openURL: @escaping () -> Void,
         sessionIsLive: @escaping () -> Bool) {
        self.isSupported = isSupported
        self.openURL = openURL
        self.sessionIsLive = sessionIsLive
    }

    /// Lifts the card into the window and opens Settings; opens Settings alone where it can't.
    func open(_ variant: Variant) {
        guard phase == .idle else { return }
        guard isSupported() else {
            logger.notice("Guide: no window on this device, Settings alone")
            openURL()
            return
        }
        began = .now
        let name = String(describing: variant)
        logger.notice("Guide: opened for \(name, privacy: .public)")
        phase = .preparing
        trip = Task { [weak self] in await self?.run(variant) }
    }

    /// Back in Murmur: the window lands on the card and goes.
    func appDidBecomeActive() {
        guard phase != .idle else { return }
        let active = controller?.isPictureInPictureActive ?? false
        let ms = elapsed
        let name = String(describing: phase)
        logger.notice("Guide: Murmur active at \(ms) ms, phase \(name, privacy: .public), window active \(active)")
        guard phase == .presenting else { return }
        guard let controller, active else {
            // Closed from the window itself, while in Settings.
            cleanup()
            return
        }
        phase = .returning
        controller.stopPictureInPicture()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled, let self, self.phase == .returning else { return }
            self.logger.error("The window didn't land in time")
            self.cleanup()
        }
    }

    // MARK: The trip

    private func run(_ variant: Variant) async {
        guard let frame = GuideFrame(variant), show(frame) else {
            logger.error("No frame for the guide")
            return fallback()
        }
        self.frame = frame
        card = frame.image
        do {
            try takeAudioSession()
        } catch {
            let reason = Self.describe(error)
            logger.error("No audio session for the guide: \(reason, privacy: .public)")
            return fallback()
        }
        let playback = GuidePlaybackDelegate()
        let events = GuideControllerDelegate(
            willStart: { [weak self] in self?.willStart() },
            didStart: { [weak self] in self?.didStart() },
            failed: { [weak self] error in self?.failed(error) },
            didStop: { [weak self] in self?.didStop() })
        self.playback = playback
        self.events = events
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayView.displayLayer, playbackDelegate: playback)
        let controller = AVPictureInPictureController(contentSource: source)
        // The frame doesn't move: this greys out the window's skip buttons (iOS still draws them).
        controller.requiresLinearPlayback = true
        controller.delegate = events
        self.controller = controller
        let possible = await waitUntilPossible(controller)
        // The trip may have ended while waiting.
        guard phase == .preparing, self.controller === controller else { return }
        logPossible(possible)
        guard possible else {
            logger.error("The window never became possible")
            return fallback()
        }
        phase = .starting
        askToStart(controller)
        awaitStart()
    }

    /// Asks the window to start, and again until it says it will. The controller says "possible"
    /// a moment before the system does, and a start asked in that moment is dropped without a
    /// word to the delegate (seen on iOS 26.6: "startPictureInPicture failed; status = 0").
    private func askToStart(_ controller: AVPictureInPictureController) {
        starter = Task { [weak self] in
            var asked = 0
            while !Task.isCancelled {
                guard let self, self.phase == .starting, self.controller === controller else { return }
                if controller.isPictureInPicturePossible {
                    asked += 1
                    let ms = self.elapsed
                    self.logger.notice("Guide: start asked (\(asked)) at \(ms) ms")
                    controller.startPictureInPicture()
                }
                try? await Task.sleep(for: Self.startRetry)
            }
        }
    }

    /// Settings alone, if the window isn't up in time.
    private func awaitStart() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled, let self, self.phase == .starting || self.phase == .lifting else { return }
            self.logger.error("The window didn't start in time")
            self.fallback()
        }
    }

    private func willStart() {
        guard phase == .starting else { return }
        starter?.cancel()
        starter = nil
        phase = .lifting
        let ms = elapsed
        logger.notice("Guide: window starting at \(ms) ms")
        // The lift-off gets its own time.
        awaitStart()
    }

    /// The window needs the layer on screen with a frame in it, which takes a few turns of the
    /// run loop; `isPictureInPicturePossible` says when.
    private func waitUntilPossible(_ controller: AVPictureInPictureController) async -> Bool {
        let step: Duration = .milliseconds(50)
        var waited: Duration = .zero
        while waited < Self.patience {
            if controller.isPictureInPicturePossible { return true }
            try? await Task.sleep(for: step)
            if Task.isCancelled { return false }
            waited += step
        }
        return controller.isPictureInPicturePossible
    }

    private func didStart() {
        guard phase == .starting || phase == .lifting else { return }
        starter?.cancel()
        starter = nil
        deadline?.cancel()
        phase = .presenting
        let ms = elapsed
        logger.notice("Guide: window started at \(ms) ms, opening Settings")
        openURL()
        // The same frame again now and then: a window left with one buffer has gone black on
        // some systems, and a renderer interrupted meanwhile is put right within a second.
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refreshFrame()
            }
        }
    }

    private func refreshFrame() {
        guard phase == .presenting, let frame else { return }
        show(frame)
    }

    /// Puts the frame in the layer. iOS interrupts the renderer whenever Murmur is suspended
    /// (after the window was closed over Settings, for one), and an interrupted renderer shows
    /// nothing, black, until it is flushed: so every frame checks first, the first one too.
    @discardableResult
    private func show(_ frame: GuideFrame) -> Bool {
        guard let buffer = frame.makeSampleBuffer() else { return false }
        let renderer = displayView.displayLayer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding || renderer.status == .failed { renderer.flush() }
        renderer.enqueue(buffer)
        return true
    }

    private func failed(_ error: any Error) {
        guard phase == .preparing || phase == .starting || phase == .lifting else { return }
        let reason = Self.describe(error)
        logger.error("The window failed to start: \(reason, privacy: .public)")
        fallback()
    }

    private func didStop() {
        guard phase != .idle else { return }
        let ms = elapsed
        let name = String(describing: phase)
        logger.notice("Guide: window stopped at \(ms) ms, phase \(name, privacy: .public)")
        cleanup()
    }

    /// Settings without the window.
    private func fallback() {
        let ms = elapsed
        logger.notice("Guide: Settings without the window at \(ms) ms")
        cleanup()
        openURL()
    }

    // MARK: The log

    /// Milliseconds since the tap.
    private var elapsed: Int {
        let passed = (ContinuousClock.now - began).components
        return Int(passed.seconds) * 1000 + Int(passed.attoseconds / 1_000_000_000_000_000)
    }

    /// What the window had to work with when the wait for it ended.
    private func logPossible(_ possible: Bool) {
        let ms = elapsed
        let audio = AVAudioSession.sharedInstance()
        let category = audio.category.rawValue
        let options = Int(audio.categoryOptions.rawValue)
        let onScreen = displayView.window != nil
        let status = displayView.displayLayer.sampleBufferRenderer.status.rawValue
        logger.notice("""
            Guide: window possible \(possible) at \(ms) ms; audio \(category, privacy: .public) options \(options); \
            card on screen \(onScreen); renderer \(status)
            """)
    }

    /// An error with its domain and code: the description alone often says too little.
    private nonisolated static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    /// The window needs an active audio session. Murmur's microphone session, when on, is one;
    /// otherwise a playback session that leaves the user's music alone.
    private func takeAudioSession() throws {
        guard !sessionIsLive() else { return }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try audio.setActive(true)
        ownsAudioSession = true
    }

    private func cleanup() {
        trip?.cancel()
        trip = nil
        starter?.cancel()
        starter = nil
        keepAlive?.cancel()
        keepAlive = nil
        deadline?.cancel()
        deadline = nil
        controller?.delegate = nil
        controller = nil
        events = nil
        playback = nil
        frame = nil
        card = nil
        displayView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        phase = .idle
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        // Not under a microphone session that began meanwhile.
        if !sessionIsLive() {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - The window's delegates

/// Playback, to the window's controls: live, always playing, nothing to skip to. AVKit says
/// nothing about the thread it asks on; there is no state to protect.
final class GuidePlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// The window's lifecycle, handed to the guide on the main actor.
final class GuideControllerDelegate: NSObject, AVPictureInPictureControllerDelegate {
    private let willStart: @MainActor @Sendable () -> Void
    private let didStart: @MainActor @Sendable () -> Void
    private let failed: @MainActor @Sendable (any Error) -> Void
    private let didStop: @MainActor @Sendable () -> Void

    init(willStart: @escaping @MainActor @Sendable () -> Void,
         didStart: @escaping @MainActor @Sendable () -> Void,
         failed: @escaping @MainActor @Sendable (any Error) -> Void,
         didStop: @escaping @MainActor @Sendable () -> Void) {
        self.willStart = willStart
        self.didStart = didStart
        self.failed = failed
        self.didStop = didStop
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let willStart = willStart
        Task { @MainActor in willStart() }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        let didStart = didStart
        Task { @MainActor in didStart() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        let failed = failed
        Task { @MainActor in failed(error) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        let didStop = didStop
        Task { @MainActor in didStop() }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler
                                    completionHandler: @escaping (Bool) -> Void) {
        // The window's button brings Murmur forward; there is nothing of ours to put back.
        completionHandler(true)
    }
}

// MARK: - The frame

/// The card as one video frame: the lines, drawn once at 3x in Murmur's dark colours. The window
/// floats over Settings in either appearance, and this is a bitmap, not text on a page.
struct GuideFrame {
    nonisolated static let size = CGSize(width: 360, height: 240)
    nonisolated static let scale: CGFloat = 3

    /// The card as drawn, for the page.
    let image: CGImage
    let pixelBuffer: CVPixelBuffer
    let formatDescription: CMVideoFormatDescription

    @MainActor
    init?(_ variant: SettingsGuide.Variant) {
        let renderer = ImageRenderer(content: GuideCard(variant: variant))
        renderer.scale = Self.scale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(Self.size)
        guard let image = renderer.cgImage, let pixelBuffer = Self.pixelBuffer(from: image),
              let description = try? CMVideoFormatDescription(imageBuffer: pixelBuffer) else { return nil }
        self.image = image
        self.pixelBuffer = pixelBuffer
        self.formatDescription = description
    }

    /// A buffer for the renderer, new each time: one that went through a flush can't be shown again.
    func makeSampleBuffer() -> CMSampleBuffer? {
        let timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClock.hostTimeClock.time,
                                        decodeTimeStamp: .invalid)
        guard let buffer = try? CMSampleBuffer(imageBuffer: pixelBuffer, formatDescription: formatDescription,
                                               sampleTiming: timing) else { return nil }
        // Shown as soon as it arrives: the layer keeps no clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }

    /// BGRA on an IOSurface, which is what the layer's renderer shows.
    private static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8,
            // Rows are padded; never assume width × 4.
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

/// The lines as the window shows them, in fixed sizes: the window is smaller than a page.
private struct GuideCard: View {
    let variant: SettingsGuide.Variant

    var body: some View {
        let lines = variant.lines
        let symbols = variant.symbols
        VStack(alignment: .leading, spacing: 16) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: symbols[index])
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color(rgb: BrandToken.second.dark))
                        .frame(width: 28)
                    (Text(verbatim: lines[index].lead) + Text(verbatim: lines[index].key).fontWeight(.bold)
                        + Text(verbatim: lines[index].tail))
                        .font(.system(size: 22))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .foregroundStyle(Color(rgb: BrandToken.ink.dark))
        .padding(.horizontal, 24)
        .frame(width: GuideFrame.size.width, height: GuideFrame.size.height, alignment: .leading)
        .background(Color(rgb: BrandToken.fill.dark))
        .environment(\.dynamicTypeSize, .large)
    }
}

// MARK: - On the page

/// The view behind the window: its layer is the sample-buffer layer the frame goes into.
final class GuideDisplayView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        displayLayer.videoGravity = .resizeAspect
        isOpaque = true
        backgroundColor = UIColor(rgb: BrandToken.fill.dark)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Over the onboarding pages: the card until the window takes it, a dim while the window lifts
/// off, and the card again for the window to land on. With the window over Settings nothing
/// shows, but the view stays mounted: its layer is what the window shows.
struct SettingsGuideOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let guide = model.settingsGuide
        ZStack {
            if guide.phase != .idle {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    ZStack {
                        // The window's source, under the picture: what iOS draws in it once the
                        // window is up isn't ours to show.
                        GuideDisplayRepresentable(view: guide.displayView)
                        if let card = guide.card {
                            Image(decorative: card, scale: GuideFrame.scale)
                                .resizable()
                        }
                    }
                    .aspectRatio(GuideFrame.size.width / GuideFrame.size.height, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 20))
                    .padding(.horizontal, 28)
                    .opacity(guide.showsCard ? 1 : 0)
                }
                .opacity(guide.showsBackdrop ? 1 : 0)
                .allowsHitTesting(guide.showsBackdrop)
                .accessibilityHidden(true)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: guide.phase)
    }
}

private struct GuideDisplayRepresentable: UIViewRepresentable {
    let view: GuideDisplayView

    func makeUIView(context: Context) -> GuideDisplayView { view }

    func updateUIView(_ uiView: GuideDisplayView, context: Context) {}
}
