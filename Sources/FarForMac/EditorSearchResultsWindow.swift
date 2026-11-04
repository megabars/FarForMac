import AppKit
import FarCore

@MainActor
final class EditorSearchResultsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let result: EditorSearchMatches
    private let onSelect: (NSRange) -> Void
    private let table = NSTableView()
    private var retainedWhileOpen: EditorSearchResultsWindow?

    init(result: EditorSearchMatches, onSelect: @escaping (NSRange) -> Void) {
        self.result = result; self.onSelect = onSelect
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window); window.delegate = self; window.isReleasedWhenClosed = false
        window.title = "Совпадения: \(result.matches.count)\(result.truncated ? " (список ограничен)" : "")"
        window.minSize = NSSize(width: 500, height: 220); window.center()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        column.title = "Строка:столбец — фрагмент"; column.width = 780
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 25
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openMatch)
        table.setAccessibilityIdentifier("editor.searchResults")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let hint = NSTextField(labelWithString: result.truncated ? "Показаны первые 10 000 совпадений; уточните поиск. Двойной щелчок — перейти." : "Двойной щелчок или кнопка — перейти. При изменении документа выполните поиск заново.")
        hint.font = .systemFont(ofSize: 11); hint.lineBreakMode = .byTruncatingTail
        let button = NSButton(title: "Перейти к совпадению", target: self, action: #selector(openMatch))
        button.bezelStyle = .rounded; button.keyEquivalent = "\r"
        let stack = NSStackView(views: [scroll, hint, button]); stack.orientation = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)])
        }
        if !result.matches.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        if let content = window?.contentView { UIAccessibility.apply(to: content) }
        retainedWhileOpen = self; super.showWindow(sender); window?.makeFirstResponder(table)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { result.matches.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let match = result.matches[row]
        let label = NSTextField(labelWithString: "\(match.line):\(match.column) — \(match.excerpt.replacingOccurrences(of: "\t", with: "    "))")
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular); label.lineBreakMode = .byTruncatingTail
        return label
    }
    @objc private func openMatch() {
        guard result.matches.indices.contains(table.selectedRow) else { return }
        onSelect(result.matches[table.selectedRow].range)
    }
    func windowWillClose(_ notification: Notification) { retainedWhileOpen = nil }
}

extension EditorSearchResultsWindow {
    static func runUISmokeChecks() throws -> [String] {
        let result = try EditorEditing.allMatches(in: "one\none\none", query: .init(pattern: "one"), limit: 2)
        var selected: NSRange?
        let controller = EditorSearchResultsWindow(result: result) { selected = $0 }
        controller.showWindow(nil)
        defer { controller.window?.close() }
        guard controller.numberOfRows(in: controller.table) == 2,
              controller.window?.title.contains("список ограничен") == true else {
            throw NSError(domain: "EditorSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "All-match window exposes truncation"])
        }
        controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.openMatch()
        guard selected == NSRange(location: 4, length: 3) else {
            throw NSError(domain: "EditorSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "All-match selection passes document range"])
        }
        return ["Editor all-match list shows truncation", "Editor all-match list navigates selected result"]
    }
}
