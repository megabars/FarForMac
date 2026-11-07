/// Translates the portable keyboard subset of LuaFar's Windows INPUT_RECORD ABI.
public enum FarLuaInputRecord {
    private static let keys: [Int: String] = [
        0x03: "Break", 0x08: "BS", 0x09: "Tab", 0x0C: "Clear", 0x0D: "Enter",
        0x13: "Pause", 0x14: "CapsLock", 0x1B: "Esc", 0x20: "Space", 0x21: "PgUp",
        0x22: "PgDn", 0x23: "End", 0x24: "Home", 0x25: "Left", 0x26: "Up",
        0x27: "Right", 0x28: "Down", 0x2C: "PrntScrn", 0x2D: "Ins", 0x2E: "Del",
        0x5B: "LWin", 0x5C: "RWin", 0x5D: "Apps", 0x6A: "Multiply", 0x6B: "Add",
        0x6D: "Subtract", 0x6E: "Decimal", 0x6F: "Divide", 0x90: "NumLock", 0x91: "ScrollLock"
    ]
    private static let enhancedKeys: Set<Int> = [0x03, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2C, 0x2D, 0x2E, 0x5B, 0x5C, 0x5D, 0x6F, 0x90]
    private static let modifiers = [("RCtrl", 0x04), ("Ctrl", 0x08), ("RAlt", 0x01), ("Alt", 0x02), ("Shift", 0x10)]
    private static let punctuation: [Int: String] = [
        0xBA: ";:", 0xBB: "=+", 0xBC: ",<", 0xBD: "-_", 0xBE: ".>", 0xBF: "/?", 0xC0: "`~",
        0xDB: "[{", 0xDC: "\\|", 0xDD: "]}", 0xDE: "'\""
    ]
    private static let digits = Array(")!@#$%^&*(")

    public static func record(named name: String) -> FarLuaValue {
        var key = name[...]
        var state = 0
        while let modifier = modifiers.first(where: { key.lowercased().hasPrefix($0.0.lowercased()) }) {
            guard state & modifier.1 == 0 else { return .nilValue }
            key = key.dropFirst(modifier.0.count)
            state |= modifier.1
        }
        if key.lowercased() == "backslash" { key = "\\"[...] }

        let lower = key.lowercased()
        let virtualKey: Int
        var character = "\0"
        if lower == "numenter" {
            virtualKey = 0x0D; state |= 0x100
        } else if lower == "numdel" {
            virtualKey = 0x2E
        } else if lower == "num5" || lower == "clear" {
            virtualKey = 0x0C
        } else if let named = keys.first(where: { $0.value.lowercased() == lower }) {
            virtualKey = named.key
            if enhancedKeys.contains(virtualKey) { state |= 0x100 }
            if virtualKey == 0x6E { state |= 0x20 }
            character = [0x08: "\u{8}", 0x09: "\t", 0x0D: "\r", 0x1B: "\u{1B}", 0x20: " "][virtualKey] ?? character
        } else if lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...24).contains(number), lower == "f\(number)" {
            virtualKey = 0x6F + number
        } else if lower.hasPrefix("num"), let number = Int(lower.dropFirst(3)), (0...9).contains(number), lower == "num\(number)" {
            virtualKey = 0x60 + number
        } else if key.isEmpty, state != 0 {
            virtualKey = state & 0x10 != 0 ? 0x10 : state & 0x03 != 0 ? 0x12 : 0x11
            if state & 0x05 != 0 && virtualKey != 0x10 { state |= 0x100 }
        } else if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first, isPrintable(scalar) {
            character = String(scalar)
            let ascii = Int(scalar.value)
            if (65...90).contains(ascii) || (97...122).contains(ascii) {
                virtualKey = ascii >= 97 ? ascii - 32 : ascii
                if ascii < 97 && state == 0 { state |= 0x10 }
                if state & 0x0F != 0 || state & 0x10 != 0 { character = character.uppercased() }
            } else if (48...57).contains(ascii) {
                virtualKey = ascii
                if state & 0x10 != 0 { character = String(digits[ascii - 48]) }
            } else if let index = digits.firstIndex(of: Character(scalar)) {
                virtualKey = 48 + index; state |= 0x10
            } else if let match = punctuation.first(where: { $0.value.contains(Character(scalar)) }) {
                virtualKey = match.key
                if match.value.last == Character(scalar) { state |= 0x10 }
                if state & 0x10 != 0, let shifted = match.value.last { character = String(shifted) }
            } else {
                virtualKey = 0
            }
        } else {
            return .nilValue
        }

        return .table([
            "EventType": .integer(1), "KeyDown": .bool(true), "RepeatCount": .integer(1),
            "VirtualKeyCode": .integer(Int64(virtualKey)), "VirtualScanCode": .integer(0),
            "UnicodeChar": .string(character), "ControlKeyState": .integer(Int64(state))
        ])
    }

    public static func name(of value: FarLuaValue, split: Bool = false) -> [FarLuaValue] {
        guard let record = value.table else { return [.nilValue] }
        let type = record["EventType"] ?? .nilValue
        guard type == .nilValue || type.integer == 0 || type.integer == 1 || type.string == "KEY_EVENT" else { return [.nilValue] }
        guard record["KeyDown"] != .bool(false) else { return [.nilValue] }

        let code = Int(record["VirtualKeyCode"]?.integer ?? 0)
        let state = Int(record["ControlKeyState"]?.integer ?? 0)
        var control = state & 0x08 != 0 ? "Ctrl" : state & 0x04 != 0 ? "RCtrl" : ""
        var alt = state & 0x02 != 0 ? "Alt" : state & 0x01 != 0 ? "RAlt" : ""
        var shift = state & 0x10 != 0 ? "Shift" : ""
        let character = record["UnicodeChar"]?.string?.unicodeScalars.first.flatMap { isPrintable($0) ? String($0) : nil }
        let key: String
        if code == 0x0D && state & 0x100 != 0 { key = "NumEnter" }
        else if code == 0x2E && state & 0x100 == 0 && record["UnicodeChar"]?.string != "\u{F728}" { key = "NumDel" }
        else if (0x70...0x87).contains(code) { key = "F\(code - 0x6F)" }
        else if (0x60...0x69).contains(code) { key = code == 0x65 ? "Clear" : "Num\(code - 0x60)" }
        else if let named = keys[code] { key = named }
        else if [0x10, 0x11, 0x12, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5].contains(code) { key = "" }
        else if let character, (control.isEmpty && alt.isEmpty) || state & 0x09 == 0x09 {
            key = character == "\\" ? "BackSlash" : character
            control = ""; alt = ""; shift = ""
        } else if (48...57).contains(code) || (65...90).contains(code), let scalar = UnicodeScalar(code) {
            key = String(scalar)
        } else if let symbol = punctuation[code]?.first {
            key = symbol == "\\" ? "BackSlash" : String(symbol)
        } else if let character {
            key = character == "\\" ? "BackSlash" : character
        } else { return [.nilValue] }
        let name = control + alt + shift + key
        guard !name.isEmpty else { return [.nilValue] }
        return split ? [control, alt, shift, key].map { $0.isEmpty ? .bool(false) : .string($0) } : [.string(name)]
    }

    private static func isPrintable(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 32 && scalar.value != 127 && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
