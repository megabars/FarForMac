import Foundation

public enum TerminalColor: Sendable, Equatable, Hashable {
    /// ANSI colors 0...15 and the xterm 256-color palette.
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TerminalAttributes: Sendable, Equatable, Hashable {
    public var foreground: TerminalColor?
    public var background: TerminalColor?
    public var bold = false
    public var faint = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var hidden = false
    public var strikethrough = false
    public init() {}
}

public struct TerminalStyledRun: Sendable, Equatable {
    public let text: String
    public let attributes: TerminalAttributes
    /// Offsets in TerminalScreen.plainText, suitable for NSAttributedString.
    public let utf16Range: Range<Int>
}

/// A deliberately bounded practical terminal-width policy. Swift's grapheme
/// segmentation handles combining marks, emoji modifiers, flags and ZWJ groups;
/// ambiguous-width characters use one cell. This is not a Unicode conformance
/// implementation or a promise of identical glyph metrics across terminal fonts.
enum TerminalGraphemeWidth {
    static func width(_ text: String) -> Int {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { $0.value == 0xfe0f || $0.value == 0x20e3 }) { return 2 }
        let textPresentation = scalars.contains(where: { $0.value == 0xfe0e })
        for scalar in scalars {
            let v = scalar.value
            if !textPresentation && scalar.properties.isEmojiPresentation { return 2 }
            if (0x1100...0x115f).contains(v) || (0x2329...0x232a).contains(v)
                || (0x2e80...0xa4cf).contains(v) && v != 0x303f
                || (0xac00...0xd7a3).contains(v) || (0xf900...0xfaff).contains(v)
                || (0xfe10...0xfe19).contains(v) || (0xfe30...0xfe6f).contains(v)
                || (0xff01...0xff60).contains(v) || (0xffe0...0xffe6).contains(v)
                || (0x20000...0x3ffff).contains(v) { return 2 }
        }
        return 1
    }
}
