import AppKit
import FarCore

@MainActor
func macroText(_ russian: String, _ english: String) -> String { L10n.language == .english ? english : russian }

/// Key codes deliberately bypass charactersIgnoringModifiers: a saved Latin label
/// continues to identify the same physical key when the input source changes.
@MainActor
enum MacroShortcutAdapter {
    static let keyNames: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`", 122: "f1", 120: "f2", 99: "f3",
        118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11",
        111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20"
    ]
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<MacroKeyModifier> {
        var result: Set<MacroKeyModifier> = []
        let mappings: [(NSEvent.ModifierFlags, MacroKeyModifier)] = [(.command, .command), (.control, .control), (.option, .option), (.shift, .shift)]
        for (native, value) in mappings {
            if flags.contains(native) { result.insert(value) }
        }
        return result
    }
    static func nativeModifiers(_ flags: Set<MacroKeyModifier>) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        let mappings: [(MacroKeyModifier, NSEvent.ModifierFlags)] = [(.command, .command), (.control, .control), (.option, .option), (.shift, .shift)]
        for (value, native) in mappings {
            if flags.contains(value) { result.insert(native) }
        }
        return result
    }
    static func label(_ binding: MacroKeyBinding) -> String {
        let symbols: [(MacroKeyModifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { binding.modifiers.contains($0.0) }.map(\.1).joined() + binding.key.uppercased()
    }
    static func matches(_ event: NSEvent, _ binding: MacroKeyBinding) -> Bool {
        keyNames[event.keyCode] == MacroShortcutPolicy.canonicalKey(binding.key) && modifiers(event.modifierFlags) == binding.modifiers
    }
    static func acceptsInput(_ responder: NSResponder?) -> Bool {
        guard let text = responder as? NSTextView else { return true }
        return !text.isFieldEditor && !text.hasMarkedText() && !(text is TerminalTextView)
    }
    static func conflict(_ binding: MacroKeyBinding) -> String? {
        do { try MacroShortcutPolicy.validate(binding) }
        catch let error as MacroBindingError { return explanation(error) }
        catch { return error.localizedDescription }
        if systemConflict(binding) { return explanation(.systemShortcut) }
        if let title = menuConflict(binding, in: NSApp.mainMenu) {
            return macroText("Клавиша занята командой меню: ", "Shortcut is used by a menu command: ") + title
        }
        return nil
    }
    static func explanation(_ error: MacroBindingError) -> String {
        switch error {
        case .invalidKey: return macroText("Укажите латинскую букву, цифру, знак US-клавиатуры или F1…F20.", "Enter a Latin letter, digit, US keyboard punctuation key, or F1…F20.")
        case .typingShortcut: return macroText("Нужен Command и ещё один модификатор: ввод текста, Option и Control зарезервированы для обычного ввода.", "Use Command with another modifier: text entry, Option and Control combinations remain available for native input.")
        case .nativeEditingShortcut: return macroText("Сочетание зарезервировано для обычных команд macOS и редактирования текста.", "This shortcut is reserved for standard macOS and text editing commands.")
        case .systemShortcut: return macroText("Сочетание занято системной командой macOS.", "This shortcut is used by a macOS system command.")
        case .applicationShortcut: return macroText("Сочетание занято палитрой, записью или остановкой макроса.", "This shortcut is reserved for the command palette, recording, or stopping a macro.")
        case .missingMacro, .emptyMacro: return macroText("Сначала запишите хотя бы одну команду макроса.", "Record at least one macro command first.")
        case .contextMismatch: return macroText("Контекст клавиши должен совпадать с первой командой макроса. Привязки в диалогах запрещены.", "The shortcut context must match the first macro command. Dialog bindings are disabled.")
        case .duplicateBinding: return macroText("В этом контексте клавиша уже назначена другому макросу. Сначала удалите прежнюю привязку.", "This shortcut already belongs to another macro in this context. Remove that binding first.")
        }
    }
    static func menuConflict(_ binding: MacroKeyBinding, in menu: NSMenu?) -> String? {
        for item in menu?.items ?? [] {
            if let title = menuConflict(binding, in: item.submenu) { return title }
            var flags = modifiers(item.keyEquivalentModifierMask)
            var key = item.keyEquivalent.lowercased()
            if let scalar = item.keyEquivalent.unicodeScalars.first, item.keyEquivalent.unicodeScalars.count == 1,
               (0xF704...0xF717).contains(scalar.value) { key = "f\(scalar.value - 0xF704 + 1)" }
            let shifted = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "|": "\\", "~": "`"]
            if let base = shifted[key] { key = base; flags.insert(.shift) }
            if item.keyEquivalent != item.keyEquivalent.lowercased() { flags.insert(.shift) }
            if key == MacroShortcutPolicy.canonicalKey(binding.key), flags == binding.modifiers { return item.title }
        }
        return nil
    }
    private static func systemConflict(_ binding: MacroKeyBinding) -> Bool {
        guard let code = keyNames.first(where: { $0.value == MacroShortcutPolicy.canonicalKey(binding.key) })?.key,
              let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let shortcuts = domain["AppleSymbolicHotKeys"] as? [String: Any] else { return false }
        let flags = nativeModifiers(binding.modifiers).rawValue
        return shortcuts.values.contains { entry in
            guard let entry = entry as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
                  let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else { return false }
            return parameters[1].uint16Value == code && parameters[2].uintValue == flags
        }
    }
    static func runUISmokeChecks() throws -> [String] {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw ExtensionAPIError(message) }
        }
        let binding = MacroKeyBinding(key: "n", modifiers: [.command, .control], context: .panel, macroID: UUID())
        guard let russian = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: "т", charactersIgnoringModifiers: "т", isARepeat: false, keyCode: 45),
              let english = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0,
                                            windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45),
              let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45) else {
            throw ExtensionAPIError("Could not construct macro shortcut smoke events")
        }
        try require(matches(russian, binding) && matches(english, binding) && !matches(typed, binding), "Macro binding follows physical key across RU/EN and preserves unmodified typing")
        let menu = NSMenu(title: "smoke")
        let item = NSMenuItem(title: "Existing command", action: nil, keyEquivalent: "n"); item.keyEquivalentModifierMask = [.control, .command]; menu.addItem(item)
        try require(menuConflict(binding, in: menu) == "Existing command", "Macro binding detects an existing menu equivalent")
        let text = NSTextView(); text.isFieldEditor = true
        try require(!acceptsInput(text) && !acceptsInput(TerminalTextView()), "Macro binding leaves field editor and terminal input untouched")
        text.isFieldEditor = false
        try require(acceptsInput(text), "Document text responder remains eligible for explicit macro chords")
        text.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(!acceptsInput(text), "Macro binding preserves active input-method composition")
        return ["Macro physical RU/EN shortcut routing and native input preservation", "Macro menu conflict detection", "Macro terminal, field editor and IME input protection"]
    }

}
