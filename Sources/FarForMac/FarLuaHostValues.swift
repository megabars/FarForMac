import AppKit
import FarCore

extension FarLuaValue {
    var hostString: String? { if case .string(let value) = self { return value }; return nil }
    var hostInt: Int? {
        switch self {
        case .integer(let value): return Int(exactly: value)
        case .number(let value): return value.isFinite && value >= Double(Int.min) && value < Double(Int.max) ? Int(value) : nil
        default: return nil
        }
    }
    var hostBool: Bool { switch self { case .nilValue, .bool(false): return false; default: return true } }
    var hostTable: [String: FarLuaValue] { if case .table(let value) = self { return value }; return [:] }
    var hostArray: [FarLuaValue] { if case .array(let value) = self { return value }; return [] }
    static func hostInteger(_ value: Int) -> FarLuaValue { .integer(Int64(value)) }
}

extension Array where Element == FarLuaValue {
    func lua(_ index: Int) -> FarLuaValue { indices.contains(index) ? self[index] : .nilValue }
}

/// Names follow FAR macro input; positions follow the physical ANSI key map.
@MainActor enum FarLuaKeys {
    static let special: [UInt16: String] = [36:"Enter", 48:"Tab", 49:"Space", 51:"BS", 53:"Esc", 114:"Ins", 115:"Home", 116:"PgUp", 117:"Del", 119:"End", 121:"PgDn", 123:"Left", 124:"Right", 125:"Down", 126:"Up", 76:"NumEnter", 67:"Multiply", 69:"Add", 75:"Divide", 78:"Subtract", 65:"Decimal", 82:"Num0", 83:"Num1", 84:"Num2", 85:"Num3", 86:"Num4", 87:"Num5", 88:"Num6", 89:"Num7", 91:"Num8", 92:"Num9"]
    static func name(_ event: NSEvent) -> String? {
        guard let key = special[event.keyCode] ?? MacroShortcutAdapter.keyNames[event.keyCode]?.uppercased() else { return nil }
        let flags = event.modifierFlags
        return (flags.contains(.command) ? "Cmd" : "") + (flags.contains(.control) ? "Ctrl" : "") + (flags.contains(.option) ? "Alt" : "") + (flags.contains(.shift) ? "Shift" : "") + key
    }
    static func event(_ name: String, window: NSWindow?) throws -> NSEvent {
        var key = name.lowercased(), flags: NSEvent.ModifierFlags = []
        var changed = true
        while changed {
            changed = false
            for (prefix, flag) in [("rctrl", NSEvent.ModifierFlags.control), ("ctrl", .control), ("ralt", .option), ("alt", .option), ("shift", .shift), ("cmd", .command)] where key.hasPrefix(prefix) {
                flags.insert(flag); key.removeFirst(prefix.count); changed = true; break
            }
        }
        let aliases = ["escape":"esc", "return":"enter", "backspace":"bs", "delete":"del", "insert":"ins", "pageup":"pgup", "pagedown":"pgdn"]
        key = aliases[key] ?? key
        let code = special.first { $0.value.lowercased() == key }?.key ?? MacroShortcutAdapter.keyNames.first { $0.value == key }?.key
        guard let code else { throw ExtensionAPIError("Неизвестная клавиша FAR: \(name)") }
        let text: String
        let base: String
        if let number = Int(key.dropFirst()), key.hasPrefix("f"), (1...20).contains(number) {
            text = String(UnicodeScalar(0xF704 + number - 1)!); base = text
        } else {
            let chars: [String: String] = ["enter":"\r", "numenter":"\r", "tab":"\t", "space":" ", "bs":"\u{7f}", "esc":"\u{1b}", "up":"\u{f700}", "down":"\u{f701}", "left":"\u{f702}", "right":"\u{f703}", "del":"\u{f728}", "home":"\u{f729}", "end":"\u{f72b}", "pgup":"\u{f72c}", "pgdn":"\u{f72d}", "ins":"\u{f727}"]
            let shifted = ["1":"!", "2":"@", "3":"#", "4":"$", "5":"%", "6":"^", "7":"&", "8":"*", "9":"(", "0":")", "-":"_", "=":"+", "[":"{", "]":"}", ";":":", "'":"\"", ",":"<", ".":">", "/":"?", "\\":"|", "`":"~"]
            let keypad = ["multiply":"*", "divide":"/", "add":"+", "subtract":"-", "decimal":"."]
            base = chars[key] ?? keypad[key] ?? (key.hasPrefix("num") ? String(key.dropFirst(3)) : key)
            text = flags.contains(.shift) ? (shifted[base] ?? base.uppercased()) : base
        }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil, characters: text, charactersIgnoringModifiers: base, isARepeat: false, keyCode: code) else { throw ExtensionAPIError("Не удалось создать событие клавиши \(name)") }
        return event
    }
}
