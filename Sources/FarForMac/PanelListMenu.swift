import AppKit

/// A keyboard-driven menu presented over the file panels.
@MainActor
final class PanelListMenu: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        let title: String
        var selectable = true
    }
    struct SmokeKey {
        let code: UInt16
        var characters = "\r"
        var modifiers: NSEvent.ModifierFlags = []
    }

    var onKey: ((NSEvent) -> Bool)?
    var onActivate: ((Int) -> Void)?
    var macroArea = "Menu"
    private let table = FileTable()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var rows: [Row] = []
    private var modal = false
    private var smokeTrace = ""
    var selection: Int? { rows.indices.contains(table.selectedRow) ? table.selectedRow : nil }

    init(title: String, hint: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 360),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = title
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 400, height: 220)
        table.backgroundColor = Palette.panel
        table.rowHeight = 24
        table.headerView = nil
        table.focusRingType = .none
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(activate)
        table.setAccessibilityLabel(title)
        let column = NSTableColumn(identifier: .init("entry"))
        column.width = 650
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let hints = NSTextField(wrappingLabelWithString: hint)
        hints.font = .systemFont(ofSize: 11)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .systemRed
        status.isHidden = true
        let content = vertical([scroll, inset(hints, x: 10, y: 8), inset(status, x: 10, y: 4)])
        panel.contentView = content
        panel.initialFirstResponder = table
    }

    required init?(coder: NSCoder) { fatalError() }

    func replaceRows(_ rows: [Row], selection requested: Int = 0) {
        self.rows = rows
        table.reloadData()
        if let index = rows.indices.first(where: { $0 >= requested && rows[$0].selectable }) ??
            rows.indices.last(where: { $0 < requested && rows[$0].selectable }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    func run(relativeTo owner: NSWindow?, smokeKey: SmokeKey? = nil) {
        guard let window else { return }
        let responder = owner?.firstResponder
        if let owner {
            let frame = owner.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.midY - window.frame.height / 2))
        } else { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        modal = true
        // Functional keys may be handled as AppKit key equivalents before
        // NSWindow.sendEvent or the first responder sees them.
        smokeTrace = "no key event reached the menu monitor"
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, let window else { return event }
            let isMenuEvent = NSApp.modalWindow === window && (event.window == nil || event.window === window)
            if smokeKey != nil {
                self.smokeTrace = "code=\(event.keyCode), modifiers=\(event.modifierFlags.rawValue), modalMatch=\(NSApp.modalWindow === window), windowMatch=\(event.window === window), selection=\(self.selection ?? -1)"
            }
            if isMenuEvent, FarLuaWorkspace.shared.handle(event) { return nil }
            return isMenuEvent && self.process(event) ? nil : event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        var smokeTimeout: Timer?
        if AppRuntime.isSmoke, let key = smokeKey {
            let timeout = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    print("Menu smoke timed out for key \(key.code): \(self.smokeTrace)")
                    self.dismiss()
                }
            }
            RunLoop.current.add(timeout, forMode: RunLoop.Mode(rawValue: "NSModalPanelRunLoopMode"))
            smokeTimeout = timeout
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key.characters, charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code) {
                NSApp.postEvent(event, atStart: true)
            }
        }
        NSApp.runModal(for: window)
        smokeTimeout?.invalidate()
        modal = false
        window.orderOut(nil)
        if let owner, owner.isVisible {
            owner.makeKeyAndOrderFront(nil)
            if let responder { owner.makeFirstResponder(responder) }
        }
    }

    func dismiss() {
        if modal { NSApp.stopModal() }
    }

    func report(_ message: String) {
        status.stringValue = message
        status.isHidden = message.isEmpty
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return !modal }

    private func process(_ event: NSEvent) -> Bool {
        if onKey?(event) == true { return true }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76: activate()
        case 53: dismiss()
        default: return false
        }
        return true
    }

    @objc private func activate() {
        if let selection, rows[selection].selectable { onActivate?(selection) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].selectable }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let field = NSTextField(labelWithString: entry.title)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.textColor = entry.selectable ? Palette.text : Palette.muted
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
}
