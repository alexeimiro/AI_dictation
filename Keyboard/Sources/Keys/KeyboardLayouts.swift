import UIKit

enum KeyboardPlane: Equatable {
    case numbers
    case symbols
    case letters
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
    static func rows(for plane: KeyboardPlane, shift: ShiftState, showsGlobe: Bool, returnTitle: String) -> [[KeySpec]] {
        let bottom = bottomRow(plane: plane, showsGlobe: showsGlobe, returnTitle: returnTitle)
        switch plane {
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
            return [
                letters("qwertyuiop"),
                letters("asdfghjkl"),
                [KeySpec(action: .shift, systemImage: shiftImage, weight: 1.4, style: .function)]
                    + letters("zxcvbnm")
                    + [deleteKey],
                bottom,
            ]
        }
    }

    private static let deleteKey = KeySpec(action: .delete, systemImage: "delete.left", weight: 1.4, style: .function)

    private static func bottomRow(plane: KeyboardPlane, showsGlobe: Bool, returnTitle: String) -> [KeySpec] {
        var row: [KeySpec] = []
        switch plane {
        case .letters:
            row.append(KeySpec(action: .plane(.numbers), label: "123", weight: 1.3, style: .function))
        case .numbers, .symbols:
            row.append(KeySpec(action: .plane(.letters), label: "ABC", weight: 1.3, style: .function))
        }
        if showsGlobe {
            row.append(KeySpec(action: .globe, systemImage: "globe", weight: 1.1, style: .function))
        }
        row.append(KeySpec(action: .space, label: "space", weight: showsGlobe ? 4.6 : 5.7))
        row.append(KeySpec(action: .returnKey, label: returnTitle, weight: 2.1, style: .returnKey))
        return row
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
