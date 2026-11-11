import Testing
@testable import MurmurBrand

/// Every place text or a mark sits on a colour, in both appearances: WCAG AA (4.5:1) for text,
/// 3:1 for graphics. A new pairing in the UI belongs here first.
struct BrandContrastTests {
    static let text: [(text: BrandToken, on: BrandToken)] = [
        (.ink, .canvas), (.second, .canvas), (.third, .canvas),
        (.ink, .fill), (.second, .fill), (.third, .fill),
        (.ink, .fillPressed),
        (.onInk, .ink), (.onLive, .live),
        (.ink, .keyboardPanel), (.second, .keyboardPanel),
        (.ink, .key), (.second, .key), (.ink, .keyPressed), (.ink, .functionKey),
        (.ink, .keyboardCard), (.second, .keyboardCard),
        // A timer or a word in the live colour.
        (.live, .canvas),
    ]

    static let graphics: [(mark: BrandToken, on: BrandToken)] = [
        (.graphic, .canvas), (.graphic, .fill),
        (.live, .canvas), (.live, .fill), (.live, .keyboardPanel),
    ]

    @Test(arguments: [false, true], [false, true])
    func textReadsOnItsBackground(dark: Bool, highContrast: Bool) {
        for (text, background) in Self.text {
            let ratio = BrandContrast.ratio(text.value(dark: dark, highContrast: highContrast),
                                            background.value(dark: dark, highContrast: highContrast))
            #expect(ratio >= 4.5, "\(text) on \(background), dark \(dark), high contrast \(highContrast): \(ratio)")
        }
    }

    @Test(arguments: [false, true], [false, true])
    func graphicsStandOut(dark: Bool, highContrast: Bool) {
        for (mark, background) in Self.graphics {
            let ratio = BrandContrast.ratio(mark.value(dark: dark, highContrast: highContrast),
                                            background.value(dark: dark, highContrast: highContrast))
            #expect(ratio >= 3, "\(mark) on \(background), dark \(dark), high contrast \(highContrast): \(ratio)")
        }
    }

    /// The Live Activity is dark in both appearances: white labels, grey status, a red timer.
    @Test func theLiveActivityReads() {
        let surface = BrandToken.activity.light
        #expect(BrandToken.activity.dark == surface)
        #expect(BrandContrast.ratio(BrandRGB(0xFFFFFF), surface) >= 4.5)
        #expect(BrandContrast.ratio(BrandRGB(0xC9C9C9), surface) >= 4.5)
        #expect(BrandContrast.ratio(BrandToken.live.dark, surface) >= 4.5)
        #expect(BrandContrast.ratio(BrandToken.onLive.dark, BrandToken.live.dark) >= 4.5)
    }

    /// Sign in with Apple is black with a white label, as Apple asks.
    @Test func blackAndWhiteAreTheEnds() {
        let black = BrandRGB(0x000000), white = BrandRGB(0xFFFFFF)
        #expect(abs(BrandContrast.ratio(black, white) - 21) < 0.01)
        #expect(BrandContrast.ratio(white, black) == BrandContrast.ratio(black, white))
        #expect(BrandContrast.ratio(white, white) == 1)
    }

    /// Red means an open microphone, so no other token may be red.
    @Test func onlyTheLiveTokenIsRed() {
        for token in BrandToken.allCases where token != .live {
            for value in [token.light, token.dark] {
                let spread = max(value.red, value.green, value.blue) - min(value.red, value.green, value.blue)
                #expect(spread < 0.08, "\(token) should be a grey: \(String(value.hex, radix: 16))")
            }
        }
    }
}
