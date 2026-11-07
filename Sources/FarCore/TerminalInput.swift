import Foundation

public struct TerminalModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = Self(rawValue: 1)
    public static let option = Self(rawValue: 2)
    public static let control = Self(rawValue: 4)
}

public enum TerminalKey: Sendable {
    case up, down, left, right, home, end, pageUp, pageDown, insert, delete
    case backspace, tab, enter, escape
    case function(Int), keypad(Character), text(String), control(UInt8)
}

public enum TerminalInput {
    public static func encode(_ key: TerminalKey, modifiers: TerminalModifiers = [],
                              applicationCursor: Bool = false, applicationKeypad: Bool = false) -> Data {
        let escape = "\u{1b}"
        let parameter = 1 + Int(modifiers.rawValue & 7)
        func cursor(_ final: String, application: Bool) -> String {
            if parameter > 1 { return escape + "[1;\(parameter)" + final }
            return escape + (application ? "O" : "[") + final
        }
        func tilde(_ number: Int) -> String {
            parameter == 1 ? escape + "[\(number)~" : escape + "[\(number);\(parameter)~"
        }
        let prefix = modifiers.contains(.option) ? escape : ""
        let sequence: String
        switch key {
        case .up: sequence = cursor("A", application: applicationCursor)
        case .down: sequence = cursor("B", application: applicationCursor)
        case .right: sequence = cursor("C", application: applicationCursor)
        case .left: sequence = cursor("D", application: applicationCursor)
        case .home: sequence = cursor("H", application: applicationCursor)
        case .end: sequence = cursor("F", application: applicationCursor)
        case .insert: sequence = tilde(2)
        case .delete: sequence = tilde(3)
        case .pageUp: sequence = tilde(5)
        case .pageDown: sequence = tilde(6)
        case .backspace: sequence = prefix + (modifiers.contains(.control) ? "\u{8}" : "\u{7f}")
        case .tab:
            sequence = modifiers.contains(.shift)
                ? (parameter == 2 ? escape + "[Z" : cursor("Z", application: false))
                : prefix + "\t"
        case .enter: sequence = prefix + "\r"
        case .escape: sequence = prefix + escape
        case .function(1...4):
            guard case let .function(number) = key else { return Data() }
            sequence = cursor(["P", "Q", "R", "S"][number - 1], application: true)
        case .function(5...12):
            guard case let .function(number) = key else { return Data() }
            sequence = tilde([15, 17, 18, 19, 20, 21, 23, 24][number - 5])
        case .function: return Data()
        case let .keypad(key):
            let finals: [Character: String] = ["0":"p", "1":"q", "2":"r", "3":"s", "4":"t", "5":"u",
                                                "6":"v", "7":"w", "8":"x", "9":"y", ".":"n", ",":"l",
                                                "+":"k", "-":"m", "*":"j", "/":"o", "=":"X", "\r":"M"]
            if applicationKeypad, let final = finals[key] { sequence = cursor(final, application: true) }
            else { sequence = prefix + String(key) }
        case let .text(text): sequence = prefix + text
        case let .control(byte): return Data(modifiers.contains(.option) ? [27, byte] : [byte])
        }
        return Data(sequence.utf8)
    }
}

public enum TerminalMouseButton: Int, Sendable, Hashable {
    case left = 0, middle = 1, right = 2
    case wheelUp = 64, wheelDown = 65, wheelLeft = 66, wheelRight = 67
}

public enum TerminalMouseEvent: Sendable, Equatable {
    case press(TerminalMouseButton), release(TerminalMouseButton)
    case move(TerminalMouseButton?), scroll(TerminalMouseButton)
}

public struct TerminalMouseReporting: Sendable, Equatable {
    public enum Tracking: Sendable, Equatable { case off, press, normal, drag, all }
    public enum Encoding: Sendable, Equatable { case legacy, utf8, sgr, urxvt, sgrPixels }
    public internal(set) var tracking: Tracking = .off
    public internal(set) var encoding: Encoding = .legacy
    public init() {}

    /// Cell and pixel coordinates are 1-based, relative to the active screen.
    public func encode(_ event: TerminalMouseEvent, column: Int, row: Int, pixelX: Int? = nil, pixelY: Int? = nil,
                       modifiers: TerminalModifiers = []) -> Data? {
        guard tracking != .off, column > 0, row > 0 else { return nil }
        let sgr = encoding == .sgr || encoding == .sgrPixels
        var code: Int
        var release = false
        switch event {
        case let .press(button): code = button.rawValue
        case let .scroll(button):
            guard tracking != .press, button.rawValue >= 64 else { return nil }
            code = button.rawValue
        case let .release(button):
            guard tracking != .press, button.rawValue < 64 else { return nil }
            code = sgr ? button.rawValue : 3
            release = true
        case let .move(button):
            guard tracking == .all || (tracking == .drag && button != nil) else { return nil }
            code = (button?.rawValue ?? 3) + 32
        }
        if tracking != .press { code += Int(modifiers.rawValue & 7) * 4 }
        switch encoding {
        case .legacy:
            guard column <= 223, row <= 223 else { return nil }
            return Data([27, 91, 77, UInt8(code + 32), UInt8(column + 32), UInt8(row + 32)])
        case .utf8:
            guard column <= 2015, row <= 2015 else { return nil }
            let coordinates = [code, column, row].compactMap { Unicode.Scalar($0 + 32) }
            return Data(("\u{1b}[M" + String(String.UnicodeScalarView(coordinates))).utf8)
        case .sgr, .sgrPixels:
            let x = encoding == .sgrPixels ? pixelX ?? 0 : column
            let y = encoding == .sgrPixels ? pixelY ?? 0 : row
            guard x > 0, y > 0 else { return nil }
            return Data("\u{1b}[<\(code);\(x);\(y)\(release ? "m" : "M")".utf8)
        case .urxvt:
            return Data("\u{1b}[\(code + 32);\(column);\(row)M".utf8)
        }
    }
}
