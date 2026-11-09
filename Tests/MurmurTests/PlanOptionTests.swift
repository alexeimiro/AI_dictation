import Foundation
import MurmurCore
import Testing
@testable import Murmur

/// The annual card's saving. (StoreKit's test session loads no products under xcodebuild on the
/// iOS 26.5 simulator; screenshot runs show the cards with fixed plans, `PlanOption.fixtures`.)
struct PlanOptionTests {
    @Test func theSavingIsAgainstTwelveMonthsRoundedDown() {
        #expect(PlanOption.saving(annual: 79.99, monthly: 9.99) == "Save 33%")
        #expect(PlanOption.saving(annual: 99.99, monthly: 9.99) == "Save 16%")
        #expect(PlanOption.saving(annual: 115, monthly: 9.99) == nil)
        #expect(PlanOption.saving(annual: 10, monthly: 0) == nil)
    }
}
