import Foundation

public enum TerminalColor: Sendable, Equatable, Hashable {
    /// ANSI colors 0...15 and the xterm 256-color palette.
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    public var rgbComponents: (UInt8, UInt8, UInt8) {
        switch self {
        case let .rgb(r, g, b): return (r, g, b)
        case .indexed(let index):
            let base: [UInt32] = [0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
                                  0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xffffff]
            let n = Int(index)
            if n < base.count {
                let color = base[n]
                return (UInt8(truncatingIfNeeded: color >> 16), UInt8(truncatingIfNeeded: color >> 8), UInt8(truncatingIfNeeded: color))
            }
            if n >= 232 {
                let level = UInt8(8 + 10 * (n - 232))
                return (level, level, level)
            }
            let cube = n - 16, levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return (levels[cube / 36], levels[(cube / 6) % 6], levels[cube % 6])
        }
    }

    init?(osc spec: String) {
        let fields: [Substring]
        if spec.hasPrefix("rgb:") {
            fields = spec.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
        } else if spec.hasPrefix("#"), [4, 7, 10, 13].contains(spec.count) {
            let hex = spec.dropFirst()
            let count = hex.count / 3
            fields = [hex.prefix(count), hex.dropFirst(count).prefix(count), hex.suffix(count)]
        } else { return nil }
        let components = fields.compactMap { digits -> UInt8? in
            guard (1...4).contains(digits.count), digits.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let value = Int(digits, radix: 16) else { return nil }
            let maximum = (1 << (digits.count * 4)) - 1
            return UInt8((value * 255 + maximum / 2) / maximum)
        }
        guard fields.count == 3, components.count == 3 else { return nil }
        self = .rgb(components[0], components[1], components[2])
    }

    var oscDescription: String {
        let (red, green, blue) = rgbComponents
        return String(format: "rgb:%04x/%04x/%04x", Int(red) * 257, Int(green) * 257, Int(blue) * 257)
    }
}

public enum TerminalCursorShape: Int, Sendable {
    case defaultBlock = 0, blinkBlock, steadyBlock, blinkUnderline, steadyUnderline, blinkBar, steadyBar
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

public struct TerminalDisplayCell: Sendable, Equatable {
    public let column: Int
    public let width: Int
    public let text: String
    public let attributes: TerminalAttributes
}

/// Foundation uses ICU's East_Asian_Width data. Swift defines the grapheme
/// boundary. Ambiguous characters use one cell, and emoji presentation uses two.
enum TerminalGraphemeWidth {
    private static let wide = try! NSRegularExpression(pattern: #"\p{ea=W}|\p{ea=F}"#)

    static func width(_ text: String) -> Int {
        guard text.utf8.contains(where: { $0 > 127 }) else { return 1 }
        let scalars = text.unicodeScalars
        if scalars.contains(where: { $0.value == 0xfe0f || $0.value == 0x20e3 }) { return 2 }
        let textPresentation = scalars.contains(where: { $0.value == 0xfe0e })
        if !textPresentation && scalars.contains(where: { $0.properties.isEmojiPresentation }) { return 2 }
        guard let base = scalars.first else { return 1 }
        if textPresentation && base.properties.isEmoji { return 1 }
        let value = String(base)
        return wide.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) == nil ? 1 : 2
    }
}
