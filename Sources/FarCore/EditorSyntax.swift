import Foundation

public enum EditorSyntaxKind: String, CaseIterable, Sendable {
    case keyword, string, number, comment, literal
}

public struct EditorSyntaxSpan: Equatable, Sendable {
    public let range: NSRange
    public let kind: EditorSyntaxKind

    public init(range: NSRange, kind: EditorSyntaxKind) { self.range = range; self.kind = kind }
}

/// A native Swift extension point. Providers receive text snapshots and return UTF-16
/// ranges; they do not load or execute Windows FAR plugins. Implementations must bound
/// their work and keep spans within their input. A provider may be called off the main thread.
public protocol EditorSyntaxProvider: Sendable {
    var id: String { get }
    var title: String { get }
    func supports(filename: String) -> Bool
    func highlights(text: String) -> [EditorSyntaxSpan]
}

public enum EditorSyntaxRegistry {
    public static let maximumHighlightBytes = 262_144
    public static let providers: [any EditorSyntaxProvider] = [
        EditorBuiltinSyntax(id: "swift", title: "Swift", extensions: ["swift"], mode: .swift),
        EditorBuiltinSyntax(id: "json", title: "JSON", extensions: ["json", "jsonc"], mode: .json),
        EditorBuiltinSyntax(id: "shell", title: "Shell", extensions: ["sh", "bash", "zsh"], mode: .shell),
        EditorBuiltinSyntax(id: "plain", title: "Обычный текст", extensions: [], mode: .plain)
    ]

    /// Additional native providers take priority over built-ins. The plain provider always
    /// supplies a fallback. This registry contains values, with no global plugin loading.
    public static func provider(for filename: String, additionalProviders: [any EditorSyntaxProvider] = []) -> any EditorSyntaxProvider {
        (additionalProviders + providers).first(where: { $0.supports(filename: filename) }) ?? providers[providers.count - 1]
    }
}

private struct EditorBuiltinSyntax: EditorSyntaxProvider {
    enum Mode: Sendable { case swift, json, shell, plain }
    let id: String
    let title: String
    let extensions: Set<String>
    let mode: Mode

    func supports(filename: String) -> Bool {
        if mode == .plain { return true }
        let name = (filename as NSString).lastPathComponent.lowercased()
        if mode == .shell, [".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile"].contains(name) { return true }
        return extensions.contains((name as NSString).pathExtension)
    }

    /// A bounded, linear lexical highlighter, not a language parser. Strings and comments
    /// have priority over keywords. Swift raw strings/interpolation and shell heredocs are
    /// intentionally left to richer native providers; ordinary strings/comments are safe.
    func highlights(text: String) -> [EditorSyntaxSpan] {
        guard mode != .plain, text.utf8.count <= EditorSyntaxRegistry.maximumHighlightBytes else { return [] }
        let units = Array(text.utf16)
        var cursor = 0
        var spans = [EditorSyntaxSpan]()
        let keywords: Set<String>
        switch mode {
        case .swift:
            keywords = ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience", "defer", "deinit", "didSet", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let", "mutating", "nonisolated", "nonmutating", "open", "operator", "override", "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet"]
        case .shell:
            keywords = ["if", "then", "else", "elif", "fi", "case", "esac", "for", "while", "until", "do", "done", "in", "function", "select", "time", "coproc", "export", "local", "readonly", "return", "break", "continue", "source"]
        default: keywords = []
        }
        func next(_ offset: Int) -> UInt16? { offset < units.count ? units[offset] : nil }
        func word(_ unit: UInt16) -> Bool {
            (65...90).contains(unit) || (97...122).contains(unit) || (48...57).contains(unit) || unit == 95 || unit > 127
        }
        func add(_ start: Int, _ kind: EditorSyntaxKind) {
            spans.append(EditorSyntaxSpan(range: NSRange(location: start, length: cursor - start), kind: kind))
        }
        while cursor < units.count {
            let start = cursor
            let unit = units[cursor]
            if (mode == .swift || mode == .json), unit == 47, next(cursor + 1) == 47 {
                cursor += 2
                while cursor < units.count, ![UInt16(10), 13, 0x85, 0x2028, 0x2029].contains(units[cursor]) { cursor += 1 }
                add(start, .comment)
            } else if (mode == .swift || mode == .json), unit == 47, next(cursor + 1) == 42 {
                cursor += 2
                var depth = 1
                while cursor < units.count {
                    if mode == .swift, units[cursor] == 47, next(cursor + 1) == 42 { depth += 1; cursor += 2 }
                    else if units[cursor] == 42, next(cursor + 1) == 47 {
                        depth -= 1; cursor += 2
                        if depth == 0 { break }
                    } else { cursor += 1 }
                }
                add(start, .comment)
            } else if mode == .shell, unit == 35, cursor == 0 || !word(units[cursor - 1]) {
                cursor += 1
                while cursor < units.count, ![UInt16(10), 13, 0x85, 0x2028, 0x2029].contains(units[cursor]) { cursor += 1 }
                add(start, .comment)
            } else if unit == 34 || mode == .shell && unit == 39 {
                let triple = mode == .swift && unit == 34 && next(cursor + 1) == 34 && next(cursor + 2) == 34
                cursor += triple ? 3 : 1
                while cursor < units.count {
                    if units[cursor] == 92, !(mode == .shell && unit == 39) { cursor = min(units.count, cursor + 2) }
                    else if units[cursor] == unit {
                        if !triple { cursor += 1; break }
                        if next(cursor + 1) == unit, next(cursor + 2) == unit { cursor += 3; break }
                        cursor += 1
                    } else { cursor += 1 }
                }
                add(start, .string)
            } else if (48...57).contains(unit), cursor == 0 || !word(units[cursor - 1]) {
                cursor += 1
                while cursor < units.count, (48...57).contains(units[cursor]) || [UInt16(46), 95].contains(units[cursor]) { cursor += 1 }
                if cursor < units.count, [UInt16(101), 69].contains(units[cursor]) {
                    cursor += 1
                    if cursor < units.count, [UInt16(43), 45].contains(units[cursor]) { cursor += 1 }
                    while cursor < units.count, (48...57).contains(units[cursor]) { cursor += 1 }
                }
                add(start, .number)
            } else if word(unit) {
                cursor += 1
                while cursor < units.count, word(units[cursor]) { cursor += 1 }
                let token = String(decoding: units[start..<cursor], as: UTF16.self)
                if keywords.contains(token) { add(start, .keyword) }
                else if ["true", "false", "nil", "null"].contains(token) { add(start, .literal) }
            } else { cursor += 1 }
        }
        return spans
    }
}
