import AppKit
import FarCore

@MainActor
final class TerminalTextView: NSTextView {
    var onInput: ((Data) -> Void)?
    var onReport: ((Data) -> Void)?
    var onToggle: (() -> Void)?
    var onCompositionEnd: (() -> Void)?
    var hasActiveProcess = false
    var applicationCursorKeys = false
    var bracketedPasteEnabled = false
    private var applicationKeypad = false
    private var reporting = TerminalMouseReporting()
    private var focusReporting = false
    private var reportedFocus = false
    private var alternateScroll = false
    private var pointerArea: NSTrackingArea?
    private var reportedButtons: Set<TerminalMouseButton> = []
    private var lastMotion: Motion?
    private var scrollRemainder: CGFloat = 0
    private var scrollAxisIsHorizontal = false
    private var gridGeometry = TerminalRenderer.Geometry(cellWidth: 8, lineHeight: 16)
    private var gridColumns = 1
    private var gridRows = 1
    private var scrollbackRows = 0
    private var cursorRow = 0
    private var cursorColumn = 0
    private var cursorShape: TerminalCursorShape = .defaultBlock
    private var terminalCursorVisible = true

    private struct Motion: Equatable {
        let column: Int
        let row: Int
        let button: TerminalMouseButton?
        let modifiers: TerminalModifiers
    }

    var horizontalTextInset: CGFloat { 2 * (textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0)) }
    var verticalTextInset: CGFloat { 2 * textContainerInset.height }
    private var hasTerminalFocus: Bool { window?.isKeyWindow == true && window?.firstResponder === self }
    private var gridOrigin: NSPoint {
        NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                y: textContainerOrigin.y + CGFloat(scrollbackRows) * gridGeometry.lineHeight)
    }

    func updateTerminalModes(_ screen: TerminalScreen) {
        applicationCursorKeys = screen.applicationCursorKeys
        applicationKeypad = screen.applicationKeypad
        bracketedPasteEnabled = screen.bracketedPasteEnabled
        if focusReporting != screen.focusReportingEnabled { reportedFocus = hasTerminalFocus }
        focusReporting = screen.focusReportingEnabled
        if reporting != screen.mouseReporting {
            reportedButtons.removeAll()
            lastMotion = nil
            scrollRemainder = 0
        }
        reporting = screen.mouseReporting
        if reporting.tracking == .all { window?.acceptsMouseMovedEvents = true }
        let scroll = screen.isAlternateScreen && screen.alternateScrollEnabled
        if alternateScroll != scroll { scrollRemainder = 0 }
        alternateScroll = scroll
    }

    func updateTerminalGeometry(_ screen: TerminalScreen, geometry: TerminalRenderer.Geometry) {
        gridGeometry = geometry
        gridColumns = screen.columns; gridRows = screen.rows
        scrollbackRows = screen.scrollbackCount
        cursorRow = screen.cursorRow; cursorColumn = screen.cursorColumn
        cursorShape = screen.cursorShape; terminalCursorVisible = screen.cursorVisible
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { super.keyDown(with: event); return }
        if flags == .control, event.keyCode == 31 { onToggle?(); return }
        if hasMarkedText() { interpretKeyEvents([event]); return }
        let modifiers = Self.modifiers(flags)
        if let key = Self.specialKeys[event.keyCode] {
            onInput?(TerminalInput.encode(key, modifiers: modifiers, applicationCursor: applicationCursorKeys,
                                         applicationKeypad: applicationKeypad))
            return
        }
        if flags.contains(.control) {
            let raw = event.characters?.unicodeScalars
            let byte = raw?.count == 1 ? raw?.first.flatMap { $0.value < 32 || $0.value == 127 ? UInt8($0.value) : nil } : nil
            if let byte = byte ?? Self.controlKeys[event.keyCode] {
                onInput?(TerminalInput.encode(.control(byte), modifiers: modifiers))
                return
            }
        }
        interpretKeyEvents([event])
    }

    private static let specialKeys: [UInt16: TerminalKey] = [
        36:.enter, 51:.backspace, 117:.delete, 48:.tab, 53:.escape, 114:.insert,
        123:.left, 124:.right, 125:.down, 126:.up, 115:.home, 119:.end, 116:.pageUp, 121:.pageDown,
        122:.function(1), 120:.function(2), 99:.function(3), 118:.function(4), 96:.function(5), 97:.function(6),
        98:.function(7), 100:.function(8), 101:.function(9), 109:.function(10), 103:.function(11), 111:.function(12),
        82:.keypad("0"), 83:.keypad("1"), 84:.keypad("2"), 85:.keypad("3"), 86:.keypad("4"), 87:.keypad("5"),
        88:.keypad("6"), 89:.keypad("7"), 91:.keypad("8"), 92:.keypad("9"), 65:.keypad("."), 95:.keypad(","),
        69:.keypad("+"), 78:.keypad("-"), 67:.keypad("*"), 75:.keypad("/"), 81:.keypad("="), 76:.keypad("\r")
    ]

    private static let controlKeys: [UInt16: UInt8] = [
        0:1, 11:2, 8:3, 2:4, 14:5, 3:6, 5:7, 4:8, 34:9, 38:10, 40:11, 37:12, 46:13, 45:14,
        31:15, 35:16, 12:17, 15:18, 1:19, 17:20, 32:21, 9:22, 13:23, 7:24, 16:25, 6:26,
        49:0, 19:0, 33:27, 42:28, 30:29, 22:30, 27:31
    ]

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> TerminalModifiers {
        var result: TerminalModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let text = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        if hasMarkedText() { unmarkText() }
        if !text.isEmpty { onInput?(Data(text.utf8)) }
    }

    override func unmarkText() {
        let composing = hasMarkedText()
        super.unmarkText()
        if composing { onCompositionEnd?() }
    }

    override func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string) { pasteText(value) }
    }

    func pasteText(_ value: String) {
        // An embedded escape could terminate bracketed paste.
        let clean = value.replacingOccurrences(of: "\u{1b}", with: "")
        onInput?(Data((bracketedPasteEnabled ? "\u{1b}[200~" + clean + "\u{1b}[201~" : clean).utf8))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            if let window { center.removeObserver(self, name: name, object: window) }
            if let newWindow { center.addObserver(self, selector: #selector(windowFocusChanged(_:)), name: name, object: newWindow) }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowFocusChanged(_ notification: Notification) { reportFocusChange() }

    override func becomeFirstResponder() -> Bool {
        let changed = super.becomeFirstResponder()
        if changed { DispatchQueue.main.async { [weak self] in self?.reportFocusChange() } }
        return changed
    }

    override func resignFirstResponder() -> Bool {
        let changed = super.resignFirstResponder()
        if changed { DispatchQueue.main.async { [weak self] in self?.reportFocusChange() } }
        return changed
    }

    private func reportFocusChange() {
        let focused = hasTerminalFocus
        guard reportedFocus != focused else { return }
        reportedFocus = focused
        if !focused { lastMotion = nil; scrollRemainder = 0 }
        if focusReporting { onReport?(Data((focused ? "\u{1b}[I" : "\u{1b}[O").utf8)) }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard terminalCursorVisible, hasTerminalFocus else { return }
        let origin = gridOrigin
        let cell = NSRect(x: origin.x + CGFloat(cursorColumn) * gridGeometry.cellWidth,
                          y: origin.y + CGFloat(cursorRow) * gridGeometry.lineHeight,
                          width: gridGeometry.cellWidth, height: gridGeometry.lineHeight)
        TerminalRenderer.drawInsertionPoint(in: cell, color: color, turnedOn: flag,
                                            shape: cursorShape, cellWidth: gridGeometry.cellWidth)
    }

    override func updateTrackingAreas() {
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved], owner: self, userInfo: nil)
        addTrackingArea(area); pointerArea = area
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) { if !press(.left, event) { super.mouseDown(with: event) } }
    override func rightMouseDown(with event: NSEvent) { if !press(.right, event) { super.rightMouseDown(with: event) } }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber != 2 || !press(.middle, event) { super.otherMouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) { if !release(.left, event) { super.mouseUp(with: event) } }
    override func rightMouseUp(with event: NSEvent) { if !release(.right, event) { super.rightMouseUp(with: event) } }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber != 2 || !release(.middle, event) { super.otherMouseUp(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { if !drag(.left, event) { super.mouseDragged(with: event) } }
    override func rightMouseDragged(with event: NSEvent) { if !drag(.right, event) { super.rightMouseDragged(with: event) } }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber != 2 || !drag(.middle, event) { super.otherMouseDragged(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if !hasTerminalFocus || !reportMouse(.move(nil), event: event) { super.mouseMoved(with: event) }
    }

    private func press(_ button: TerminalMouseButton, _ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), reporting.tracking != .off else { return false }
        guard mousePosition(event, clamp: false) != nil else { return false }
        window?.makeFirstResponder(self)
        reportFocusChange()
        guard reportMouse(.press(button), event: event) else { return false }
        reportedButtons.insert(button)
        return true
    }

    private func release(_ button: TerminalMouseButton, _ event: NSEvent) -> Bool {
        guard reportedButtons.remove(button) != nil else { return false }
        _ = reportMouse(.release(button), event: event, clamp: true)
        return true
    }

    private func drag(_ button: TerminalMouseButton, _ event: NSEvent) -> Bool {
        guard reportedButtons.contains(button) else { return false }
        _ = reportMouse(.move(button), event: event, clamp: true)
        return true
    }

    override func scrollWheel(with event: NSEvent) {
        let tracksWheel = reporting.tracking != .off && reporting.tracking != .press
        guard !event.modifierFlags.contains(.command), tracksWheel || alternateScroll,
              tracksWheel ? mousePosition(event, clamp: false) != nil : true else {
            super.scrollWheel(with: event)
            return
        }
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        guard delta != 0, tracksWheel || !horizontal else { return }
        if horizontal != scrollAxisIsHorizontal || event.phase == .began || delta * scrollRemainder < 0 {
            scrollRemainder = 0
        }
        scrollAxisIsHorizontal = horizontal
        scrollRemainder += event.hasPreciseScrollingDeltas ? delta / gridGeometry.lineHeight : delta
        let steps = min(16, Int(abs(scrollRemainder)))
        guard steps > 0 else { return }
        let positive = scrollRemainder > 0
        scrollRemainder -= positive ? CGFloat(steps) : -CGFloat(steps)
        if tracksWheel {
            let button: TerminalMouseButton = horizontal ? (positive ? .wheelLeft : .wheelRight) : (positive ? .wheelUp : .wheelDown)
            for _ in 0..<steps { _ = reportMouse(.scroll(button), event: event) }
        } else {
            let bytes = TerminalInput.encode(positive ? .up : .down, applicationCursor: applicationCursorKeys)
            onReport?(Data(repeating: bytes, count: steps))
        }
    }

    private func mousePosition(_ event: NSEvent, clamp: Bool) -> (column: Int, row: Int, x: Int, y: Int)? {
        let point = convert(event.locationInWindow, from: nil), origin = gridOrigin
        let width = CGFloat(gridColumns) * gridGeometry.cellWidth
        let height = CGFloat(gridRows) * gridGeometry.lineHeight
        let x = point.x - origin.x, y = point.y - origin.y
        guard clamp || (x >= 0 && x < width && y >= 0 && y < height) else { return nil }
        let scale = window?.backingScaleFactor ?? 1
        return (min(gridColumns, max(1, Int(floor(x / gridGeometry.cellWidth)) + 1)),
                min(gridRows, max(1, Int(floor(y / gridGeometry.lineHeight)) + 1)),
                min(Int(ceil(width * scale)), max(1, Int(floor(x * scale)) + 1)),
                min(Int(ceil(height * scale)), max(1, Int(floor(y * scale)) + 1)))
    }

    @discardableResult
    private func reportMouse(_ action: TerminalMouseEvent, event: NSEvent, clamp: Bool = false) -> Bool {
        guard clamp || !event.modifierFlags.contains(.command),
              let position = mousePosition(event, clamp: clamp) else { return false }
        let modifiers = Self.modifiers(event.modifierFlags)
        guard let bytes = reporting.encode(action, column: position.column, row: position.row,
                                           pixelX: position.x, pixelY: position.y, modifiers: modifiers) else { return false }
        if case let .move(button) = action {
            let pixels = reporting.encoding == .sgrPixels
            let motion = Motion(column: pixels ? position.x : position.column, row: pixels ? position.y : position.row,
                                button: button, modifiers: modifiers)
            if lastMotion == motion { return true }
            lastMotion = motion
        } else {
            lastMotion = nil
        }
        onReport?(bytes)
        return true
    }
}

private extension Data {
    init(repeating data: Data, count: Int) {
        self.init(capacity: data.count * count)
        for _ in 0..<count { append(data) }
    }
}
