import Testing
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import MurmurCore

/// A style's icon is an SF Symbol by name, which the compiler can't check: a misspelt one draws
/// nothing. Kept apart from `CoreLogicTests`, which needs nothing but Foundation.
struct StyleSymbolTests {
    @Test(arguments: StylePreset.allCases)
    func theSystemHasTheStylesIcon(style: StylePreset) {
        #if canImport(UIKit)
        #expect(UIImage(systemName: style.symbolName) != nil, "\(style): \(style.symbolName)")
        #elseif canImport(AppKit)
        #expect(NSImage(systemSymbolName: style.symbolName, accessibilityDescription: nil) != nil,
                "\(style): \(style.symbolName)")
        #endif
    }
}
