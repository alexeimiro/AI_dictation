import UIKit

enum KeyboardPlane: Equatable {
    case numbers
    case symbols
    case letters
    /// The voice pad: a big talk button (see `VoicePad`) above one row of keys.
    case voice
}

enum ShiftState {
    case off
    case on
    case capsLock
}

enum KeyAction: Equatable {
    case character(String)
    case delete
    case space
    case returnKey
    case shift
    case plane(KeyboardPlane)
    /// ABC: the next keyboard for typing letters, as in Wispr Flow, or the keyboard's own letters
    /// when "Show full QWERTY keyboard" is on.
    case abc
    case globe
}

enum KeyStyle {
    case character
    case function
    case returnKey
}

struct KeySpec {
    let action: KeyAction
    var label: String?
    var systemImage: String?
    var weight: CGFloat = 1
    var style: KeyStyle = .character
    /// Extra space beside the key's face inside its touch area, like the gaps that set #+= and
    /// Delete apart from the punctuation in Wispr's keypad.
    var leadingGap: CGFloat = 0
    var trailingGap: CGFloat = 0

    static func char(_ value: String) -> KeySpec {
        KeySpec(action: .character(value), label: value)
    }
}

/// Key rows for each plane, sized like Wispr Flow's keypad. The voice pad is the default; the
/// numbers-first plane is Wispr's.
enum KeyboardLayouts {
    /// The space bar's label, as Wispr's reads "Wispr Flow".
    static let spaceTitle = "Murmur"

    /// `showsVoicePad` adds a key back to the pad, for the voice layout's full keys.
    static func rows(for plane: KeyboardPlane, shift: ShiftState, showsGlobe: Bool, showsVoicePad: Bool,
                     returnTitle: String, languageCode: String = "en") -> [[KeySpec]] {
        let bottom = bottomRow(plane: plane, showsGlobe: showsGlobe, showsVoicePad: showsVoicePad,
                               returnTitle: returnTitle, languageCode: languageCode)
        switch plane {
        case .voice:
            return [voiceRow(showsGlobe: showsGlobe, returnTitle: returnTitle, languageCode: languageCode)]
        case .numbers:
            return [
                "1234567890".map { .char(String($0)) },
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map(KeySpec.char),
                punctuationRow(planeKey: KeySpec(action: .plane(.symbols), label: "#+=", style: .function)),
                bottom,
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map(KeySpec.char),
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map(KeySpec.char),
                punctuationRow(planeKey: KeySpec(action: .plane(.numbers), label: "123", style: .function)),
                bottom,
            ]
        case .letters:
            let uppercase = shift != .off
            func letters(_ row: String) -> [KeySpec] {
                row.map { .char(uppercase ? String($0).uppercased() : String($0)) }
            }
            let shiftImage = switch shift {
            case .off: "shift"
            case .on: "shift.fill"
            case .capsLock: "capslock.fill"
            }
            let rows = letterRows(languageCode: languageCode)
            return [
                letters(rows[0]),
                letters(rows[1]),
                [KeySpec(action: .shift, systemImage: shiftImage, weight: 1.5, style: .function, trailingGap: 9)]
                    + letters(rows[2])
                    + [deleteKey],
                bottom,
            ]
        }
    }

    private static func letterRows(languageCode: String) -> [String] {
        switch languageCode {
        case "ru": ["йцукенгшщзх", "фывапролджэ", "ячсмитьбю"]
        case "uk": ["йцукенгшщзх", "фівапролджє", "ячсмитьбю"]
        default: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        }
    }

    private static let deleteKey = KeySpec(action: .delete, systemImage: "delete.left", weight: 1.5,
                                           style: .function, leadingGap: 9)

    /// Wispr's third keypad row: the plane key and Delete set apart from five wide punctuation keys.
    private static func punctuationRow(planeKey: KeySpec) -> [KeySpec] {
        var planeKey = planeKey
        planeKey.weight = 1.5
        planeKey.trailingGap = 9
        return [planeKey]
            + [".", ",", "?", "!", "'"].map { var key = KeySpec.char($0); key.weight = 1.4; return key }
            + [deleteKey]
    }

    /// Wispr's bottom row: ABC and return a quarter of the width each, space between. The voice
    /// layout's key back to the pad and the globe (phones without the system's) take from them.
    private static func bottomRow(plane: KeyboardPlane, showsGlobe: Bool, showsVoicePad: Bool,
                                  returnTitle: String, languageCode: String) -> [KeySpec] {
        let extraWidth = (showsVoicePad ? 1.4 : 0) + (showsGlobe ? 1.2 : 0)
        let side: CGFloat = extraWidth > 0 ? 2 : 2.5
        var row: [KeySpec] = []
        switch plane {
        case .letters:
            row.append(KeySpec(action: .plane(.numbers), label: "123", weight: side, style: .function))
        case .numbers, .symbols, .voice:
            row.append(KeySpec(action: .abc, label: lettersLabel(languageCode), weight: side, style: .function))
        }
        // Spelled out: a mic icon here read as "dictate", not "back to the pad".
        if showsVoicePad {
            row.append(KeySpec(action: .plane(.voice), label: "voice", weight: 1.4, style: .function))
        }
        if showsGlobe {
            row.append(KeySpec(action: .globe, systemImage: "globe", weight: 1.2, style: .function))
        }
        row.append(KeySpec(action: .space, label: spaceTitle, weight: 10 - 2 * side - extraWidth))
        row.append(returnKey(returnTitle, weight: side))
        return row
    }

    /// The voice keyboard's typing row, Wispr's bottom row: ABC, space and return. Delete sits in
    /// the toolbar.
    private static func voiceRow(showsGlobe: Bool, returnTitle: String, languageCode: String) -> [KeySpec] {
        let side: CGFloat = showsGlobe ? 2.2 : 2.5
        var row = [KeySpec(action: .abc, label: lettersLabel(languageCode), weight: side, style: .function)]
        if showsGlobe {
            row.append(KeySpec(action: .globe, systemImage: "globe", weight: 1.2, style: .function))
        }
        row.append(KeySpec(action: .space, label: spaceTitle, weight: 10 - 2 * side - (showsGlobe ? 1.2 : 0)))
        row.append(returnKey(returnTitle, weight: side))
        return row
    }

    /// ⏎ for an ordinary return key; the field's word ("send", "go", "search"…) otherwise.
    private static func returnKey(_ title: String, weight: CGFloat) -> KeySpec {
        title == returnTitle(for: .default)
            ? KeySpec(action: .returnKey, systemImage: "return.left", weight: weight, style: .returnKey)
            : KeySpec(action: .returnKey, label: title, weight: weight, style: .returnKey)
    }

    private static func lettersLabel(_ languageCode: String) -> String {
        switch languageCode {
        case "ru", "uk": "АБВ"
        default: "ABC"
        }
    }

    static func returnTitle(for type: UIReturnKeyType) -> String {
        switch type {
        case .go: "go"
        case .google, .search, .yahoo: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .emergencyCall: "emergency"
        case .continue: "continue"
        default: "return"
        }
    }
}
