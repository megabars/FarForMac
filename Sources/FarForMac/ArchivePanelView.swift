import AppKit
import FarCore

/// An archive has its own virtual cursor and marks. Paths exposed to the host
/// are archive member names, never filesystem paths or executable commands.
@MainActor
final class ArchivePanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    var onSwitchPanel: (() -> Void)?
    var onAction: ((NSEvent) -> Bool)?
    var onView: ((String) -> Void)?
    var onOpenArchive: ((String) -> Void)?
    var frameDisplayPath: String? { didSet { updateHeading() } }
    var onDirectoryChange: (() -> Void)?
    private(set) var snapshot: ArchiveSnapshot
    private(set) var currentDirectory = ""
    private let table = FileTable()
    private let heading = label("", size: 11, color: Palette.accent, bold: true)
    private let summary = label("", size: 11, color: Palette.muted)
    private var marks = Set<String>()
    private var rows: [Row] = []
    private var directories = Set<String>()
    private var cursorByDirectory: [String: String] = [:]
    private var active = false
    private var shiftMarking: Bool?

    struct NavigationState {
        let directory: String
        let cursor: String?
        let marks: Set<String>
        let cursors: [String: String]
    }
    func captureNavigationState() -> NavigationState {
        NavigationState(directory: currentDirectory, cursor: cursorPath, marks: marks, cursors: cursorByDirectory)
    }
    func restoreNavigationState(_ state: NavigationState) {
        currentDirectory = state.directory; marks = state.marks; cursorByDirectory = state.cursors
        rebuild(preferredCursor: state.cursor)
    }

    private struct Row {
        let path: String
        let name: String
        let directory: Bool
        let size: Int64
        let modified: Date?
        let encrypted: Bool
    }

    var caption: String {
        "\(frameDisplayPath ?? snapshot.sourceURL.lastPathComponent) !/\(currentDirectory)"
    }
    var cursorPath: String? {
        guard table.selectedRow > 0, table.selectedRow < rows.count + 1 else { return nil }
        return rows[table.selectedRow - 1].path
    }
    var cursorIsDirectory: Bool {
        guard table.selectedRow > 0, table.selectedRow < rows.count + 1 else { return false }
        return rows[table.selectedRow - 1].directory
    }
    var selectedArchivePaths: [String] {
        marks.isEmpty ? cursorPath.map { [$0] } ?? [] : marks.sorted()
    }

    init(snapshot: ArchiveSnapshot) {
        self.snapshot = snapshot
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = Palette.panel.cgColor
        table.backgroundColor = Palette.panel; table.rowHeight = 29
        table.intercellSpacing = .zero; table.focusRingType = .none
        table.allowsMultipleSelection = false; table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openSelection)
        table.setAccessibilityLabel("Содержимое архива")
        for (id, title, width) in [("name", "Имя", CGFloat(300)), ("size", "Размер", CGFloat(95)), ("modified", "Изменён", CGFloat(145))] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "name" ? 120 : 70; table.addTableColumn(column)
        }
        table.onFocus = { [weak self] in self?.onFocus?() }
        table.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        table.onShiftRelease = { [weak self] in self?.shiftMarking = nil }
        table.onSelectAll = { [weak self] in self?.markAll() }
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.drawsBackground = false
        let help = label("Enter — открыть · Ins/Пробел — отметка · Tab — другая панель · Esc — выйти", size: 10, color: Palette.muted)
        for view in [heading, scroll, summary, help] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            help.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 5),
            help.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            help.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            help.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focus() { window?.makeFirstResponder(table) }
    func setActive(_ value: Bool) {
        active = value
        table.enumerateAvailableRowViews { view, _ in (view as? FileRow)?.active = value; view.needsDisplay = true }
    }
    func update(snapshot: ArchiveSnapshot) {
        let sameArchive = self.snapshot.sourceURL.standardizedFileURL == snapshot.sourceURL.standardizedFileURL
        let cursor = sameArchive ? cursorPath : nil
        if !sameArchive { currentDirectory = ""; marks.removeAll(); cursorByDirectory.removeAll() }
        self.snapshot = snapshot
        rebuild(preferredCursor: cursor)
    }

    func reveal(path: String) {
        currentDirectory = Self.parent(path)
        marks.removeAll()
        rebuild(preferredCursor: path)
    }

    private func rebuild(preferredCursor: String? = nil) {
        directories = [""]
        var items: [String: Row] = [:]
        for entry in snapshot.entries {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            for index in 1...parts.count where index < parts.count || entry.isDirectory {
                let path = parts.prefix(index).joined(separator: "/")
                directories.insert(path)
                if items[path] == nil { items[path] = Row(path: path, name: parts[index - 1], directory: true, size: 0, modified: nil, encrypted: false) }
            }
            items[entry.path] = Row(path: entry.path, name: parts.last!, directory: entry.isDirectory,
                                   size: entry.size, modified: entry.modificationDate, encrypted: entry.isEncrypted)
        }
        while !directories.contains(currentDirectory) { currentDirectory = Self.parent(currentDirectory) }
        marks.formIntersection(Set(items.keys))
        rows = items.values.filter { Self.parent($0.path) == currentDirectory }.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        updateHeading()
        table.reloadData()
        let wanted = preferredCursor ?? cursorByDirectory[currentDirectory]
        let index = wanted.flatMap { path in rows.firstIndex { $0.path == path } }.map { $0 + 1 } ?? (rows.isEmpty ? 0 : 1)
        select(index); updateSummary(); onDirectoryChange?()
    }

    private static func parent(_ path: String) -> String { path.split(separator: "/").dropLast().joined(separator: "/") }
    private func updateHeading() { heading.stringValue = "АРХИВ · \(snapshot.format.displayName) · \(caption)" }
    private func select(_ index: Int) {
        let row = max(0, min(index, rows.count))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
    }
    private func updateSummary() {
        summary.stringValue = "Объектов: \(rows.count) · Отмечено: \(marks.count) · \(snapshot.isReadOnly ? L10n.text("Архив только для чтения · F3 просмотр · F5 извлечь") : "F3 просмотр · F4 правка · F5 извлечение · F6 перенос · F7 папка · F8 удаление")"
    }
    private func toggleMark(move: Bool) {
        guard let path = cursorPath else { return }
        if marks.contains(path) { marks.remove(path) } else { marks.insert(path) }
        table.reloadData(); updateSummary()
        if move { select(table.selectedRow + 1) }
    }
    private func markAll() { marks.formUnion(rows.map(\.path)); table.reloadData(); updateSummary() }
    private func move(_ amount: Int, marking: Bool) {
        if marking, let path = cursorPath {
            if shiftMarking == nil { shiftMarking = !marks.contains(path) }
            if shiftMarking == true { marks.insert(path) } else { marks.remove(path) }
            table.reloadData(); updateSummary()
        }
        select(table.selectedRow + amount)
    }
    @objc func openSelection() {
        if table.selectedRow == 0 { parent(); return }
        guard let path = cursorPath else { return }
        if cursorIsDirectory {
            cursorByDirectory[currentDirectory] = path
            marks.removeAll()
            currentDirectory = path; rebuild()
        } else if Self.isArchiveName(path) { onOpenArchive?(path) }
        else { onView?(path) }
    }
    static func isArchiveName(_ path: String) -> Bool {
        ["zip", "tar", "7z", "rar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz"].contains((path as NSString).pathExtension.lowercased())
    }
    private func parent() {
        guard !currentDirectory.isEmpty else { onClose?(); return }
        let child = currentDirectory
        if let path = cursorPath { cursorByDirectory[currentDirectory] = path }
        marks.removeAll()
        currentDirectory = Self.parent(currentDirectory); rebuild(preferredCursor: child)
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 121, modifiers == .control, let path = cursorPath, !cursorIsDirectory { onOpenArchive?(path); return true }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift { onSwitchPanel?(); return true }
        if event.keyCode == 53, modifiers.isEmpty { onClose?(); return true }
        if event.keyCode == 51, modifiers.isEmpty { parent(); return true }
        if event.keyCode == 36 || event.keyCode == 76, modifiers.isEmpty { openSelection(); return true }
        if (event.keyCode == 49 || event.keyCode == 114), modifiers.isEmpty { toggleMark(move: event.keyCode == 114); return true }
        if event.keyCode == 126 || event.keyCode == 125, modifiers.isEmpty || modifiers == .shift {
            move(event.keyCode == 126 ? -1 : 1, marking: modifiers == .shift); return true
        }
        if event.keyCode == 115, modifiers.isEmpty { select(0); return true }
        if event.keyCode == 119, modifiers.isEmpty { select(rows.count); return true }
        if modifiers.isEmpty, event.charactersIgnoringModifiers == "+" { markAll(); return true }
        if modifiers.isEmpty, event.charactersIgnoringModifiers == "-" { marks.removeAll(); table.reloadData(); updateSummary(); return true }
        return onAction?(event) ?? false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + 1 }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRow(); view.active = active; return view
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if let path = cursorPath { cursorByDirectory[currentDirectory] = path }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "name"
        let field = label("", size: 12)
        if row == 0 { field.stringValue = id == "name" ? "↰  .." : ""; field.textColor = Palette.accent; return field }
        guard row - 1 < rows.count else { return field }
        let item = rows[row - 1]
        switch id {
        case "size": field.stringValue = item.directory ? "<ПАПКА>" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file); field.alignment = .right
        case "modified": field.stringValue = item.modified?.formatted(date: .numeric, time: .shortened) ?? ""; field.textColor = Palette.muted
        default:
            field.stringValue = "\(marks.contains(item.path) ? "◆" : " ") \(item.directory ? "▸ " : "")\(item.name)\(item.encrypted ? " 🔒" : "")"
            field.textColor = marks.contains(item.path) || item.directory ? Palette.accent : Palette.text
        }
        return field
    }
}
