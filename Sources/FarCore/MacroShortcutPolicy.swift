import Foundation

public enum MacroBindingError: Error, Equatable, Sendable {
    case invalidKey, typingShortcut, nativeEditingShortcut, systemShortcut, applicationShortcut
    case missingMacro, emptyMacro, contextMismatch, duplicateBinding
}

/// Shortcut names refer to physical positions on an ANSI US keyboard, independent
/// of the active input source. This also gives imported bindings one unambiguous meaning.
public enum MacroShortcutPolicy {
    private static let characterKeys = Set("abcdefghijklmnopqrstuvwxyz0123456789`-=[]\\;',./".map(String.init))
    public static func canonicalKey(_ key: String) -> String? {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if characterKeys.contains(value) || (1...20).contains(where: { value == "f\($0)" }) { return value }
        return nil
    }
    public static func validate(_ binding: MacroKeyBinding) throws {
        guard let key = canonicalKey(binding.key) else { throw MacroBindingError.invalidKey }
        let flags = binding.modifiers
        // Bare characters, Option dead keys and Control editing/navigation keys
        // must always continue to the native responder (including terminal input).
        guard flags.contains(.command) else { throw MacroBindingError.typingShortcut }
        if flags == [.command] { throw MacroBindingError.nativeEditingShortcut }
        if flags == [.command, .shift], Set("acdfghinopsvwxzy".map(String.init)).contains(key) {
            throw MacroBindingError.nativeEditingShortcut
        }
        if flags == [.command, .option], Set("acdfhilmnpsvwt".map(String.init)).contains(key) {
            throw MacroBindingError.nativeEditingShortcut
        }
        if flags == [.command, .option, .shift], key == "v" { throw MacroBindingError.nativeEditingShortcut }
        // Standard macOS shortcuts: lock, full screen, definition, screenshots,
        // accessibility, focus/menu navigation, input-source and zoom controls.
        if (flags == [.command, .control] && ["q", "f", "d"].contains(key)) ||
            (flags.contains(.command) && flags.contains(.shift) && ["3", "4", "5", "6"].contains(key)) ||
            (flags.contains(.command) && flags.contains(.option) && ["=", "-", "8"].contains(key)) ||
            (["f1", "f2", "f5"].contains(key)) ||
            (flags.contains(.command) && flags.contains(.shift) && key == "q") {
            throw MacroBindingError.systemShortcut
        }
        if flags == [.command, .control], ["p", "r", "."].contains(key) { throw MacroBindingError.applicationShortcut }
        guard binding.context != .dialog else { throw MacroBindingError.contextMismatch }
    }
    public static func validate(_ binding: MacroKeyBinding, in configuration: MacroConfiguration, replacingMacro: Bool = false) throws {
        try validate(binding)
        guard let macro = configuration.macros.first(where: { $0.id == binding.macroID }) else { throw MacroBindingError.missingMacro }
        guard let first = macro.steps.first else { throw MacroBindingError.emptyMacro }
        guard first.context == binding.context else { throw MacroBindingError.contextMismatch }
        guard !configuration.bindings.contains(where: {
            $0.context == binding.context && $0.modifiers == binding.modifiers && canonicalKey($0.key) == canonicalKey(binding.key) &&
            (!replacingMacro || $0.macroID != binding.macroID)
        }) else { throw MacroBindingError.duplicateBinding }
    }
}
