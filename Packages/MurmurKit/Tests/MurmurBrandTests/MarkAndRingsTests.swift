import CoreGraphics
import Testing
@testable import MurmurBrand

struct MarkGeometryTests {
    @Test func theDotAndTheRingShareACentre() {
        let rect = CGRect(x: 10, y: 20, width: 48, height: 48)
        let dot = MarkGeometry.dot(in: rect), ring = MarkGeometry.ring(in: rect)
        #expect(abs(dot.midX - rect.midX) < 0.001 && abs(dot.midY - rect.midY) < 0.001)
        #expect(abs(ring.rect.midX - rect.midX) < 0.001 && abs(ring.rect.midY - rect.midY) < 0.001)
    }

    @Test func theRingStaysInsideAndClearOfTheDot() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        let dot = MarkGeometry.dot(in: rect), ring = MarkGeometry.ring(in: rect)
        let outer = ring.rect.width / 2 + ring.lineWidth / 2
        let inner = ring.rect.width / 2 - ring.lineWidth / 2
        #expect(outer <= 12)
        #expect(inner > dot.width / 2 + ring.lineWidth)
    }

    @Test func aWideFrameDoesNotStretchTheMark() {
        let dot = MarkGeometry.dot(in: CGRect(x: 0, y: 0, width: 200, height: 24))
        #expect(abs(dot.width - dot.height) < 0.001)
        #expect(abs(dot.midX - 100) < 0.001)
        #expect(abs(dot.width - 8.4) < 0.001)
    }
}

struct EchoRingsTests {
    @Test func silenceShowsNoRings() {
        for levels in [[Double](), Array(repeating: 0, count: 30)] {
            let rings = EchoRings.rings(levels: levels)
            #expect(rings.count == EchoRings.count)
            #expect(rings.allSatisfy { $0.scale == 1 && $0.opacity == 0 })
        }
    }

    @Test func aFullVoiceReachesTheOuterEdge() throws {
        let rings = EchoRings.rings(levels: Array(repeating: 1, count: 30))
        let outermost = try #require(rings.last)
        #expect(abs(outermost.scale - EchoRings.maxScale) < 0.0001)
        // Each ring is wider and fainter than the one inside it.
        for (inner, outer) in zip(rings, rings.dropFirst()) {
            #expect(outer.scale > inner.scale)
            #expect(outer.opacity < inner.opacity)
        }
    }

    @Test func louderIsWider() {
        let quiet = EchoRings.rings(levels: Array(repeating: 0.2, count: 30))
        let loud = EchoRings.rings(levels: Array(repeating: 0.7, count: 30))
        for (a, b) in zip(quiet, loud) {
            #expect(b.scale > a.scale)
            #expect(b.opacity > a.opacity)
        }
    }

    /// A syllable reaches the inner ring first; the outer ones follow.
    @Test func theOuterRingsTrailTheInner() {
        var levels = Array(repeating: 0.0, count: 30)
        levels[29] = 1
        let start = EchoRings.rings(levels: levels)
        #expect(start[0].scale > 1)
        #expect(start[1].scale == 1 && start[2].scale == 1)

        levels = Array(repeating: 0.0, count: 30)
        levels[29 - EchoRings.lag] = 1
        let later = EchoRings.rings(levels: levels)
        #expect(later[1].scale > 1)
        #expect(later[2].scale == 1)
    }

    @Test func underReduceMotionOnlyTheOpacityFollowsTheVoice() {
        let quiet = EchoRings.rings(levels: Array(repeating: 0.2, count: 30), reduceMotion: true)
        let loud = EchoRings.rings(levels: Array(repeating: 0.9, count: 30), reduceMotion: true)
        for (a, b) in zip(quiet, loud) {
            #expect(a.scale == b.scale)
            #expect(b.opacity > a.opacity)
        }
        #expect(EchoRings.rings(levels: [], reduceMotion: true).allSatisfy { $0.opacity == 0 })
    }

    @Test func oddInputStaysInBounds() {
        let levels: [Double] = [.nan, .infinity, -3, 7, 0.5, -.infinity, 2, .nan, 1, 0.3]
        for reduceMotion in [false, true] {
            for ring in EchoRings.rings(levels: levels, reduceMotion: reduceMotion) {
                #expect(ring.scale.isFinite && ring.scale >= 1 && ring.scale <= EchoRings.maxScale)
                #expect(ring.opacity.isFinite && ring.opacity >= 0 && ring.opacity <= 1)
            }
        }
    }
}
