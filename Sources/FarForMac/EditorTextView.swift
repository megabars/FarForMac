import AppKit

/// Text-system commands stay in the responder chain; the controller supplies
/// document-aware indentation and preserves one undo step for compound edits.
@MainActor
final class EditorTextView: NSTextView {
    var indentSelection: ((Bool) -> Void)?
    var tabSize = 4
    var usesSpaces = true
    var overtype = false
    var autoIndentNewline = false
    var beforeUserInput: (() -> (() -> Void)?)?
    private var processingUserInput = false

    private func trackInput(_ operation: () -> Void) {
        guard !processingUserInput else { operation(); return }
        let finished = beforeUserInput?()
        processingUserInput = true
        operation()
        processingUserInput = false
        if !hasMarkedText() { finished?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 122 { super.keyDown(with: event); return }
        trackInput { super.keyDown(with: event) }
    }

    override func paste(_ sender: Any?) { trackInput { super.paste(sender) } }
    override func cut(_ sender: Any?) { trackInput { super.cut(sender) } }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        var range = replacementRange
        if overtype, !hasMarkedText(), selectedRange().length == 0, range.location == NSNotFound,
           let value = insertString as? String, value.count == 1, value.first?.isNewline == false {
            let source = string as NSString
            let caret = selectedRange().location
            if caret < source.length, ![10, 13].contains(source.character(at: caret)) {
                range = source.rangeOfComposedCharacterSequence(at: caret)
            }
        }
        trackInput { super.insertText(insertString, replacementRange: range) }
    }

    override func insertNewline(_ sender: Any?) {
        guard autoIndentNewline, isEditable else { super.insertNewline(sender); return }
        let source = string as NSString
        let caret = selectedRange().location
        let start = source.lineRange(for: NSRange(location: caret, length: 0)).location
        let prefix = source.substring(with: NSRange(location: start, length: caret - start))
        let indent = prefix.prefix(while: { $0 == " " || $0 == "\t" })
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        guard isEditable else { return }
        if selectedRange().length > 0 { indentSelection?(false); return }
        if usesSpaces {
            let ns = string as NSString
            let position = selectedRange().location
            let start = ns.lineRange(for: NSRange(location: position, length: 0)).location
            let prefix = ns.substring(with: NSRange(location: start, length: position - start))
            var column = 0
            for character in prefix { column += character == "\t" ? tabSize - column % tabSize : 1 }
            insertText(String(repeating: " ", count: tabSize - column % tabSize), replacementRange: selectedRange())
        } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) { indentSelection?(true) }
}

@MainActor
final class EditorLineRuler: NSRulerView {
    weak var editor: NSTextView?

    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        ruleThickness = 64
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let visible = editor.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -editor.textContainerOrigin.x, dy: -editor.textContainerOrigin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = editor.string as NSString
        var position = 0, line = 1
        while position < characters.location {
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: position, length: 0)))
            guard end > position, end <= characters.location else { break }
            position = end; line += 1
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        while position <= min(ns.length, NSMaxRange(characters)) {
            let glyph = ns.length == 0 ? 0 : layout.glyphIndexForCharacter(at: min(position, ns.length - 1))
            var lineRect = ns.length == 0 ? NSRect(x: 0, y: 0, width: 0, height: 16) : layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if position == ns.length, ns.length > 0, ns.character(at: ns.length - 1) == 10 { lineRect = layout.extraLineFragmentRect }
            let label = "\(line)" as NSString
            let width = label.size(withAttributes: attrs).width
            label.draw(at: NSPoint(x: ruleThickness - width - 10, y: lineRect.minY + editor.textContainerOrigin.y - visible.minY + 1), withAttributes: attrs)
            if position == ns.length { break }
            let end = NSMaxRange(ns.lineRange(for: NSRange(location: position, length: 0)))
            guard end > position else { break }
            position = end; line += 1
        }
    }
}
