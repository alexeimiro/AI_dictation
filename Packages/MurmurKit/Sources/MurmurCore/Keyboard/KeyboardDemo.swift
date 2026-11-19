import Foundation

/// Debug builds: one keyboard state to show instead of the live one, so every state can be
/// screenshotted in the simulator, where nothing records. Written as `<state>[@<layout>]`, e.g.
/// `listening@numbers`; without a layout the keyboard keeps the user's.
public struct KeyboardDemo: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable {
        /// `idle` has a live session; `off` has none, so the key layouts show Start.
        case idle, off, translate, starting, opening, reconnect, listening, processing, inserted
        case notice, pending, fullAccess, style, menu
        /// Listening with the dictation's words on screen: `wordsStart` before the first one,
        /// `wordsRunning` as they come, a word at a time.
        case words, wordsStart, wordsRunning
        /// "Type as I speak", played through the real `LiveTyping` into the focused field: the
        /// running words go in as they settle. `typing` ends with the final text replacing them
        /// (`typingFinalText`, after `typingWords` words); `typingCancel` with the cross taking
        /// them out again (after `typingCancelWords`).
        case typing, typingCancel
        /// Basic's weekly words are used up.
        case limit
        /// Nobody is signed in: "You are logged out" in place of the whole keyboard.
        case loggedOut
    }

    public var state: State
    public var layout: KeyboardLayoutPreference?

    public init(state: State, layout: KeyboardLayoutPreference? = nil) {
        self.state = state
        self.layout = layout
    }

    public init?(_ value: String) {
        let parts = value.split(separator: "@", maxSplits: 1).map(String.init)
        guard let state = parts.first.flatMap(State.init(rawValue:)) else { return nil }
        var layout: KeyboardLayoutPreference?
        if parts.count == 2 {
            guard let named = KeyboardLayoutPreference(rawValue: parts[1]) else { return nil }
            layout = named
        }
        self.init(state: state, layout: layout)
    }

    public var value: String {
        layout.map { "\(state.rawValue)@\($0.rawValue)" } ?? state.rawValue
    }

    /// What the `words` state shows for `requestId`: more than two lines on either listening
    /// screen, the last words unsettled.
    public static func sampleWords(for requestId: UUID) -> LivePreview {
        LivePreview(requestId: requestId,
                    settled: "So I was thinking we could meet on Thursday afternoon instead, because the morning is already full,",
                    unsettled: " and then go over the numbers")
    }

    /// What the `wordsRunning` state has heard after `count` words: the sample over and over, its
    /// last three words unsettled, cut to its end as the app cuts it (`LivePreview.tail`).
    public static func runningWords(for requestId: UUID, count: Int) -> LivePreview {
        let sample = sampleWords(for: requestId).text.split(separator: " ")
        let words = (0..<max(0, count)).map { String(sample[$0 % sample.count]) }
        let settled = words.dropLast(3).joined(separator: " ")
        let unsettled = words.suffix(3).joined(separator: " ")
        return LivePreview.tail(requestId: requestId, settled: settled,
                                unsettled: settled.isEmpty ? unsettled : " " + unsettled)
    }

    /// How many of the running words the `typing` state hears before its final text arrives.
    public static let typingWords = 24
    /// How many the `typingCancel` state hears before the cross.
    public static let typingCancelWords = 12

    /// The final text of the `typing` state's dictation: its `typingWords` running words as the
    /// cloud might write them, with another word near the start ("hoping" for "thinking") and
    /// other capitals and punctuation further on. So it begins as the typed words do and then
    /// differs, and the replacement shows that all of them are written again.
    public static let typingFinalText = """
        So I was hoping we could meet on Thursday afternoon instead, because the morning is already \
        full. And then go over the numbers, so.
        """
}
