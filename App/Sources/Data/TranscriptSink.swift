import Foundation
import MurmurCore

/// Where finished dictations are kept. `SessionController` only knows this protocol, so it stays
/// free of SwiftData types.
@MainActor
protocol TranscriptSink: AnyObject {
    func record(_ transcript: Transcript)
}
