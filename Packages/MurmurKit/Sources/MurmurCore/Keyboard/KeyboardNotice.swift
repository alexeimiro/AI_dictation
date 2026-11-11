import Foundation

/// A notice on the keyboard, as a title and a line: "We didn't catch anything. Try again a little
/// closer." reads as its first sentence, then the rest. Pure, so it's tested here; the keyboard
/// target has no tests.
public enum KeyboardNotice {
    public static func parts(of message: String) -> (title: String, detail: String?) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let ends = [". ", "! ", "? "].compactMap { message.range(of: $0) }
        guard let end = ends.min(by: { $0.lowerBound < $1.lowerBound }) else { return (message, nil) }
        let detail = message[end.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !detail.isEmpty else { return (message, nil) }
        // A title keeps its ? or !, and drops its full stop.
        let mark = message[end.lowerBound]
        let title = String(message[..<end.lowerBound]) + (mark == "." ? "" : String(mark))
        return (title, detail)
    }
}
