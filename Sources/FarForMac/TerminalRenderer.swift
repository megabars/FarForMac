import AppKit
import FarCore

@MainActor
enum TerminalRenderer {
    static func render(_ screen: TerminalScreen, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: screen.plainText, attributes: [.font: font, .foregroundColor: Palette.text, .backgroundColor: Palette.background])
        for run in screen.styledRuns {
            let style = run.attributes
            var foreground = style.foreground.map(color) ?? Palette.text
            var background = style.background.map(color) ?? Palette.background
            if style.inverse { swap(&foreground, &background) }
            if style.hidden { foreground = background }
            else if style.faint { foreground = foreground.blended(withFraction: 0.5, of: background) ?? foreground }
            var traits: NSFontTraitMask = []
            if style.bold { traits.insert(.boldFontMask) }
            if style.italic { traits.insert(.italicFontMask) }
            let styledFont = traits.isEmpty ? font : NSFontManager.shared.convert(font, toHaveTrait: traits)
            result.addAttributes([.font: styledFont, .foregroundColor: foreground, .backgroundColor: background,
                                  .underlineStyle: style.underline ? NSUnderlineStyle.single.rawValue : 0,
                                  .strikethroughStyle: style.strikethrough ? NSUnderlineStyle.single.rawValue : 0],
                                 range: NSRange(location: run.utf16Range.lowerBound, length: run.utf16Range.count))
        }
        return result
    }
    private static func color(_ color: TerminalColor) -> NSColor {
        switch color {
        case let .rgb(r, g, b): return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .indexed(let index):
            let base: [UInt32] = [0x000000,0xcd3131,0x0dbc79,0xe5e510,0x2472c8,0xbc3fbc,0x11a8cd,0xe5e5e5,0x666666,0xf14c4c,0x23d18b,0xf5f543,0x3b8eea,0xd670d6,0x29b8db,0xffffff]
            let n = Int(index)
            if n < 16 { let value = base[n]; return self.color(.rgb(UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255))) }
            if n >= 232 { let level = UInt8(8 + 10 * (n - 232)); return self.color(.rgb(level, level, level)) }
            let cube = n - 16, levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return self.color(.rgb(levels[cube / 36], levels[(cube / 6) % 6], levels[cube % 6]))
        }
    }
    static func runUISmokeChecks() throws -> [String] {
        var screen = TerminalScreen(columns: 20, rows: 2)
        screen.append("\u{1b}[31;1mred\u{1b}[0m plain")
        let text = render(screen, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        guard text.string.hasPrefix("red plain"),
              let red = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
              let plain = text.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor,
              red != plain else { throw NetworkError.io("Terminal SGR colors must reach AppKit attributes") }
        let view = TerminalTextView()
        var sent = Data()
        view.onInput = { sent.append($0) }
        view.bracketedPasteEnabled = true
        view.pasteText("first\nsecond\u{1b}[201~")
        guard String(decoding: sent, as: UTF8.self) == "\u{1b}[200~first\nsecond[201~\u{1b}[201~" else {
            throw NetworkError.io("Terminal paste must preserve newlines and prevent embedded bracket termination")
        }
        return ["Terminal SGR styles render as native attributed text", "Bracketed paste preserves text without an embedded escape terminator"]
    }
}
