import AppKit
import CoreText
import FarCore

@MainActor
enum TerminalRenderer {
    struct Geometry {
        let cellWidth: CGFloat
        let lineHeight: CGFloat
    }

    static func geometry(font: NSFont) -> Geometry {
        Geometry(cellWidth: ("M" as NSString).size(withAttributes: [.font: font]).width,
                 lineHeight: ceil(NSLayoutManager().defaultLineHeight(for: font)))
    }

    static func update(_ view: NSTextView, screen: TerminalScreen, font: NSFont) {
        view.backgroundColor = colors(screen).background
        view.insertionPointColor = screen.cursorVisible ? cursor(screen) : .clear
        view.textStorage?.setAttributedString(render(screen, font: font))
    }

    static func applyHostColors(to screen: inout TerminalScreen) {
        if let foreground = terminalColor(Palette.text) { screen.hostForeground = foreground }
        if let background = terminalColor(Palette.background) { screen.hostBackground = background }
    }

    static func cursor(_ screen: TerminalScreen) -> NSColor {
        screen.cursorColor.map(color) ?? colors(screen).foreground
    }

    static func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn: Bool,
                                   shape: TerminalCursorShape, cellWidth: CGFloat) {
        let steady = [.steadyBlock, .steadyUnderline, .steadyBar].contains(shape)
        guard turnedOn || steady else { return }
        var caret = rect
        switch shape {
        case .defaultBlock, .blinkBlock, .steadyBlock: caret.size.width = cellWidth
        case .blinkUnderline, .steadyUnderline:
            caret.origin.y = rect.maxY - 2
            caret.size = NSSize(width: cellWidth, height: 2)
        case .blinkBar, .steadyBar: caret.size.width = 2
        }
        let fill = shape == .defaultBlock || shape == .blinkBlock || shape == .steadyBlock
            ? color.withAlphaComponent(color.alphaComponent * 0.55) : color
        fill.setFill()
        NSBezierPath(rect: caret).fill()
    }

    static func render(_ screen: TerminalScreen, font: NSFont) -> NSAttributedString {
        let defaults = colors(screen)
        let geometry = geometry(font: font)
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = .leftToRight
        paragraph.minimumLineHeight = geometry.lineHeight
        paragraph.maximumLineHeight = geometry.lineHeight
        let result = NSMutableAttributedString(
            string: screen.plainText,
            attributes: [.font: font, .foregroundColor: defaults.foreground, .backgroundColor: defaults.background,
                         .ligature: 0, .paragraphStyle: paragraph]
        )
        for run in screen.styledRuns {
            let style = run.attributes
            let cellForeground = screen.reverseVideo ? defaults.background : defaults.foreground
            let cellBackground = screen.reverseVideo ? defaults.foreground : defaults.background
            var foreground = style.foreground.map { color(resolve($0, in: screen)) } ?? cellForeground
            var background = style.background.map { color(resolve($0, in: screen)) } ?? cellBackground
            if style.inverse != screen.reverseVideo { swap(&foreground, &background) }
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
        // TextKit preserves copy, accessibility and IME. Explicit advances
        // keep fallback glyphs in the same grid used for PTY mouse reports.
        var offset = 0
        var advances: [Glyph: CGFloat] = [:]
        for line in screen.displayCells {
            for cell in line {
                let length = cell.text.utf16.count
                let range = NSRange(location: offset, length: length)
                let cellFont = result.attribute(.font, at: offset, effectiveRange: nil) as? NSFont ?? font
                if cell.width != 1 || cellFont != font || cell.text.utf8.contains(where: { $0 > 127 }) {
                    let key = Glyph(text: cell.text, font: cellFont)
                    let width: CGFloat
                    if let cached = advances[key] { width = cached }
                    else {
                        let text = NSAttributedString(string: cell.text, attributes: [.font: cellFont, .ligature: 0])
                        width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text as CFAttributedString), nil, nil, nil)
                        if advances.count < 2048 { advances[key] = width }
                    }
                    let correction = CGFloat(cell.width) * geometry.cellWidth - width
                    if abs(correction) > 0.01 { result.addAttribute(.kern, value: correction, range: range) }
                    if cell.text.utf8.contains(where: { $0 > 127 }) {
                        result.addAttribute(.writingDirection, value: [2], range: range)
                    }
                }
                offset += length
            }
            offset += 1
        }
        return result
    }

    private struct Glyph: Hashable {
        let text: String
        let font: NSFont
    }

    private static func colors(_ screen: TerminalScreen) -> (foreground: NSColor, background: NSColor) {
        let foreground = screen.defaultForeground.map(color) ?? Palette.text
        let background = screen.defaultBackground.map(color) ?? Palette.background
        return screen.reverseVideo ? (background, foreground) : (foreground, background)
    }

    private static func resolve(_ color: TerminalColor, in screen: TerminalScreen) -> TerminalColor {
        guard case .indexed(let index) = color else { return color }
        return screen.palette[index] ?? color
    }

    private static func color(_ color: TerminalColor) -> NSColor {
        let (r, g, b) = color.rgbComponents
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    private static func terminalColor(_ color: NSColor) -> TerminalColor? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        return .rgb(byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
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
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let size = geometry(font: font)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        screen.append("\u{1b}[?1000;1006h")
        view.updateTerminalModes(screen)
        view.updateTerminalGeometry(screen, geometry: size)
        let mousePoint = view.convert(NSPoint(x: view.textContainerOrigin.x + (view.textContainer?.lineFragmentPadding ?? 0) + size.cellWidth * 2.5,
                                              y: view.textContainerOrigin.y + size.lineHeight * 1.5), to: nil)
        var reports = Data()
        view.onReport = { reports.append($0) }
        guard let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: mousePoint, modifierFlags: [.shift],
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: 1, pressure: 1),
              let function = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 103)
        else { throw NetworkError.io("Terminal input events could not be created") }
        sent.removeAll()
        view.keyDown(with: function)
        view.mouseDown(with: mouse)
        guard sent == Data("\u{1b}[23;6~".utf8), reports == Data("\u{1b}[<4;3;2M".utf8) else {
            throw NetworkError.io("AppKit must deliver function-key modifiers and terminal-grid mouse coordinates")
        }
        return ["Terminal SGR styles render as native attributed text",
                "Bracketed paste preserves text without an embedded escape terminator",
                "AppKit terminal input encodes a modified function key and an SGR mouse click"]
    }
}
