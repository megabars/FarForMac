import AppKit
import FarCore

@MainActor final class RemotePanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let provider: any RemoteProvider
    private(set) var currentPath: String
    private(set) var entries: [RemoteEntry]
    var onFocus: (() -> Void)?, onClose: (() -> Void)?, onSwitchPanel: (() -> Void)?
    var onNavigate: ((String) -> Void)?, onView: ((RemoteEntry) -> Void)?, onChange: (() -> Void)?
    private let table = FileTable(), summary = NSTextField(labelWithString: "")
    private var marks = Set<String>(), active = false
    var cursor: RemoteEntry? { let row = table.selectedRow - 1; return entries.indices.contains(row) ? entries[row] : nil }
    var selectedEntries: [RemoteEntry] { marks.isEmpty ? cursor.map { [$0] } ?? [] : entries.filter { marks.contains($0.path) } }
    var caption: String { "\(provider.connection.kind.rawValue)://\(provider.connection.host):\(provider.connection.port)\(currentPath)" }
    init(provider: any RemoteProvider, path: String, entries: [RemoteEntry]) {
        self.provider = provider; self.currentPath = path; self.entries = []
        super.init(frame: .zero)
        table.backgroundColor = Palette.panel; table.rowHeight = 29; table.intercellSpacing = .zero
        table.allowsMultipleSelection = false; table.allowsEmptySelection = false; table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelection)
        table.setAccessibilityLabel("Сетевая файловая панель")
        for (id, title, width) in [("name", "Имя", CGFloat(300)), ("size", "Размер", CGFloat(95)), ("date", "Изменён", CGFloat(145))] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = 70; table.addTableColumn(column)
        }
        table.onFocus = { [weak self] in self?.onFocus?() }
        table.onKey = { [weak self] event in self?.key(event) ?? false }
        table.onSelectAll = { [weak self] in self?.marks = Set(self?.entries.map(\.path) ?? []); self?.reload() }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let hint = NSTextField(labelWithString: "Enter — открыть · Пробел — отметка · Tab — другая панель · Esc — отключить")
        hint.font = .systemFont(ofSize: 10); summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let body = vertical([scroll, inset(summary, x: 10, y: 7), inset(hint, x: 10, y: 6)])
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor), body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)])
        update(path: path, entries: entries)
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() { window?.makeFirstResponder(table) }
    func setActive(_ value: Bool) { active = value; table.enumerateAvailableRowViews { view, _ in (view as? FileRow)?.active = value; view.needsDisplay = true } }
    func update(path: String, entries: [RemoteEntry]) {
        let previous = currentPath == path ? cursor?.path : nil
        if currentPath != path { marks.removeAll() }
        currentPath = path
        self.entries = entries.sorted { if $0.isDirectory != $1.isDirectory { return $0.isDirectory }; return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        marks.formIntersection(Set(entries.map(\.path))); reload()
        let index = previous.flatMap { name in self.entries.firstIndex { $0.path == name } }.map { $0 + 1 } ?? (entries.isEmpty ? 0 : 1)
        select(index); onChange?()
    }
    private func reload() { table.reloadData(); summary.stringValue = "Объектов: \(entries.count) · Отмечено: \(marks.count) · F5 копировать · F6 перенести · F8 удалить" }
    private func select(_ row: Int) { let value = max(0, min(row, entries.count)); table.selectRowIndexes(IndexSet(integer: value), byExtendingSelection: false); table.scrollRowToVisible(value) }
    @objc private func openSelection() {
        guard table.selectedRow > 0 else { parent(); return }
        guard let entry = cursor else { return }
        if entry.isSymbolicLink { NSSound.beep(); return }
        if entry.isDirectory { onNavigate?(entry.path) } else { onView?(entry) }
    }
    private func parent() { if currentPath == "/" { onClose?() } else { onNavigate?(RemotePath.parent(currentPath)) } }
    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.isEmpty || flags == .shift else { return false }
        switch event.keyCode {
        case 48: onSwitchPanel?()
        case 53: onClose?()
        case 51: parent()
        case 36, 76: openSelection()
        case 49, 114:
            if let entry = cursor { if marks.contains(entry.path) { marks.remove(entry.path) } else { marks.insert(entry.path) }; reload(); if event.keyCode == 114 { select(table.selectedRow + 1) } }
        case 125, 126:
            if flags == .shift, let entry = cursor { marks.insert(entry.path); reload() }
            select(table.selectedRow + (event.keyCode == 125 ? 1 : -1))
        case 115: select(0)
        case 119: select(entries.count)
        default: return false
        }
        return true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count + 1 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let view = FileRow(); view.active = active; return view }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "name"
        let label = NSTextField(labelWithString: ""); label.font = .monospacedSystemFont(ofSize: 12, weight: .regular); label.lineBreakMode = .byTruncatingMiddle
        label.textColor = Palette.text
        if row == 0 { label.stringValue = id == "name" ? "↰  .." : ""; return label }
        let entry = entries[row - 1]
        switch id {
        case "name": label.stringValue = (marks.contains(entry.path) ? "✓ " : "  ") + (entry.isSymbolicLink ? "↗ " : entry.isDirectory ? "▸ " : "") + entry.name
        case "size": label.stringValue = entry.isDirectory ? "<ПАПКА>" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        default: label.stringValue = entry.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        }
        return label
    }
}
