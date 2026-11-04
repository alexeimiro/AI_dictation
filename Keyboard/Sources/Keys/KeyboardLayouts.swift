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

    static func char(_ value: String) -> KeySpec {
        KeySpec(action: .character(value), label: value)
    }
}

/// Key rows for each plane. The numbers-first plane is the default, like Wispr Flow's keyboard.
enum KeyboardLayouts {
    /// `showsVoicePad` adds a key back to the pad, for the voice layout's full keys.
    static func rows(for plane: KeyboardPlane, shift: ShiftState, showsGlobe: Bool, showsVoicePad: Bool,
                     returnTitle: String, languageCode: String = "en") -> [[KeySpec]] {
        let bottom = bottomRow(plane: plane, showsGlobe: showsGlobe, showsVoicePad: showsVoicePad,
                               returnTitle: returnTitle, languageCode: languageCode)
        switch plane {
        case .voice:
            return [voiceRow(showsGlobe: showsGlobe, languageCode: languageCode)]
        case .numbers:
            return [
                "1234567890".map { .char(String($0)) },
                ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""].map(KeySpec.char),
                [KeySpec(action: .plane(.symbols), label: "#+=", weight: 1.4, style: .function)]
                    + [".", ",", "?", "!", "'"].map { var key = KeySpec.char($0); key.weight = 1.4; return key }
                    + [deleteKey],
                bottom,
            ]
        case .symbols:
            return [
                ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map(KeySpec.char),
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map(KeySpec.char),
                [KeySpec(action: .plane(.numbers), label: "123", weight: 1.4, style: .function)]
                    + [".", ",", "?", "!", "'"].map { var key = KeySpec.char($0); key.weight = 1.4; return key }
                    + [deleteKey],
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
                [KeySpec(action: .shift, systemImage: shiftImage, weight: 1.35, style: .function)]
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

    private static let deleteKey = KeySpec(action: .delete, systemImage: "delete.left", weight: 1.4, style: .function)

    private static func bottomRow(plane: KeyboardPlane, showsGlobe: Bool, showsVoicePad: Bool,
                                  returnTitle: String, languageCode: String) -> [KeySpec] {
        var row: [KeySpec] = []
        switch plane {
        case .letters:
            row.append(KeySpec(action: .plane(.numbers), label: "123", weight: 1.3, style: .function))
        case .numbers, .symbols, .voice:
            row.append(KeySpec(action: .plane(.letters), label: lettersLabel(languageCode), weight: 1.3,
                               style: .function))
        }
        // Spelled out: a mic icon here read as "dictate", not "back to the pad".
        if showsVoicePad {
            row.append(KeySpec(action: .plane(.voice), label: "voice", weight: 1.4, style: .function))
        }
        if showsGlobe {
            row.append(KeySpec(action: .globe, systemImage: "globe", weight: 1.1, style: .function))
        }
        let extraWidth = (showsVoicePad ? 1.4 : 0) + (showsGlobe ? 1.1 : 0)
        row.append(KeySpec(action: .space, label: "space", weight: 5.7 - extraWidth))
        row.append(KeySpec(action: .returnKey, label: returnTitle, weight: 2.1, style: .returnKey))
        return row
    }

    /// The voice pad's one row: the ways out to the full keys, the punctuation dictation most
    /// often leaves out, and space. Delete and return sit beside the talk button.
    private static func voiceRow(showsGlobe: Bool, languageCode: String) -> [KeySpec] {
        var row = [
            KeySpec(action: .plane(.letters), label: lettersLabel(languageCode), weight: 1.3, style: .function),
            KeySpec(action: .plane(.numbers), label: "123", weight: 1.3, style: .function),
        ]
        if showsGlobe {
            row.append(KeySpec(action: .globe, systemImage: "globe", weight: 1.1, style: .function))
        }
        row += [",", ".", "?"].map(KeySpec.char)
        row.append(KeySpec(action: .space, label: "space", weight: showsGlobe ? 3.3 : 4.4))
        return row
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
