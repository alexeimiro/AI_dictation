import Foundation

/// Debug builds: one keyboard state to show instead of the live one, so every state can be
/// screenshotted in the simulator, where nothing records. Written as `<state>[@<layout>]`, e.g.
/// `listening@numbers`; without a layout the keyboard keeps the user's.
public struct KeyboardDemo: Equatable, Sendable {
    public enum State: String, CaseIterable, Sendable {
        /// `idle` has a live session; `off` has none, so the key layouts show Start.
        case idle, off, translate, starting, opening, reconnect, listening, processing, inserted
        case notice, pending, fullAccess, style, menu
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
}
