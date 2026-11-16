import AVFoundation
import AVKit
import CoreVideo
import Testing
@testable import Murmur

struct SettingsGuideTests {
    /// The frame the window shows: the card at 3x, opaque, in the dark colours.
    @MainActor
    @Test(arguments: SettingsGuide.Variant.allCases)
    func frameIsAnOpaqueDarkCard(variant: SettingsGuide.Variant) throws {
        let frame = try #require(GuideFrame(variant))
        let buffer = frame.pixelBuffer
        #expect(CVPixelBufferGetWidth(buffer) == 1080)
        #expect(CVPixelBufferGetHeight(buffer) == 720)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        // BGRA: the fill of the dark appearance (#2C2C2E), fully opaque.
        #expect(base[3] == 255)
        #expect(abs(Int(base[2]) - 0x2C) <= 2, "red")
        #expect(abs(Int(base[1]) - 0x2C) <= 2, "green")
        #expect(abs(Int(base[0]) - 0x2E) <= 2, "blue")
        #expect(frame.makeSampleBuffer() != nil)
        #expect(frame.makeSampleBuffer() != nil, "a new buffer each time")
        // The same picture goes on the page, over the layer the window takes.
        #expect(frame.image.width == 1080)
        #expect(frame.image.height == 720)
    }

    /// No window (simulators, Picture in Picture not supported): Settings opens as before, and
    /// nothing is left half-way.
    @MainActor
    @Test func withoutAWindowSettingsOpensAsBefore() {
        var opened = 0
        let guide = SettingsGuide(isSupported: { false }, openURL: { opened += 1 }, sessionIsLive: { false })
        guide.open(.enableKeyboard)
        #expect(opened == 1)
        #expect(guide.phase == .idle)
        #expect(!guide.showsCard)
        #expect(!guide.showsBackdrop)
        #expect(guide.card == nil)
        guide.open(.fullAccess)
        #expect(opened == 2)
    }

    @Test func everyLineNamesWhatToFindInSettings() {
        for lines in [OnboardingCopy.Guide.enableKeyboard, OnboardingCopy.Guide.fullAccess] {
            #expect(lines.count == 4)
            #expect(lines.allSatisfy { !$0.key.isEmpty && $0.text == $0.lead + $0.key + $0.tail })
        }
        let enable = OnboardingCopy.Guide.enableKeyboard.map(\.key)
        #expect(enable.contains(OnboardingCopy.Keyboard.keyboards))
        #expect(enable.contains(OnboardingCopy.Keyboard.murmur))
        #expect(enable.contains(OnboardingCopy.Keyboard.fullAccess))
        #expect(OnboardingCopy.Guide.fullAccess.map(\.key).contains(OnboardingCopy.Keyboard.fullAccess))
        for variant in SettingsGuide.Variant.allCases {
            #expect(variant.symbols.count == variant.lines.count)
        }
    }

    /// The window's controls see live content that is always playing.
    @MainActor
    @Test func theWindowHasNothingToPauseOrSkip() {
        let delegate = GuidePlaybackDelegate()
        let controller = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(), playbackDelegate: delegate))
        let range = delegate.pictureInPictureControllerTimeRangeForPlayback(controller)
        #expect(range.duration.isPositiveInfinity)
        #expect(!delegate.pictureInPictureControllerIsPlaybackPaused(controller))
        var completed = false
        delegate.pictureInPictureController(controller, skipByInterval: .init(value: 15, timescale: 1)) {
            completed = true
        }
        #expect(completed)
    }
}
