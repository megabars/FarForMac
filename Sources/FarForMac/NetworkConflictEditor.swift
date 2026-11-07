import AppKit
import FarCore

/// Edits decisions only. The immutable filesystem plan is resolved and verified
/// on a worker after this dialog, before the separate final confirmation.
@MainActor
final class NetworkConflictEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 360))
    private let table = NSTableView()
    private let conflicts: [RemoteDirectoryConflict]
    private var actions: [Int]
    private var names: [String]

    init(plan: RemoteDirectoryTransferPlan) {
        conflicts = plan.conflicts
        actions = Array(repeating: 0, count: plan.conflicts.count)
        names = plan.conflicts.map { Self.suggestedName($0.mapping.destination, directory: $0.sourceIsDirectory) }
        super.init()
        table.dataSource = self; table.delegate = self; table.rowHeight = 46
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel(L10n.text("Действия при сетевых конфликтах"))
        for (id, title, width) in [("path", "Источник → назначение", 425.0), ("action", "Действие", 180.0), ("name", "Новое имя", 215.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = L10n.text(title); column.width = width; column.minWidth = 100
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let skip = NSButton(title: L10n.text("Пропустить все"), target: self, action: #selector(skipAll))
        let replace = NSButton(title: L10n.text("Заменить обычные файлы"), target: self, action: #selector(replaceFiles))
        let controls = NSStackView(views: [skip, replace]); controls.orientation = .horizontal; controls.spacing = 10
        for child in [controls, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.topAnchor), controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func decisions() -> [String: RemoteDirectoryConflictDecision] {
        Dictionary(uniqueKeysWithValues: conflicts.indices.map { index in
            let decision: RemoteDirectoryConflictDecision
            switch actions[index] {
            case 1: decision = conflicts[index].canReplace ? .replace : .skip
            case 2: decision = .rename(names[index])
            case 3: decision = conflicts[index].canCompareDates ? .newer : .skip
            case 4: decision = conflicts[index].canReplace ? .append : .skip
            case 5: decision = conflicts[index].canResume ? .resume : .skip
            default: decision = .skip
            }
            return (conflicts[index].mapping.source, decision)
        })
    }
    func numberOfRows(in tableView: NSTableView) -> Int { conflicts.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard conflicts.indices.contains(row) else { return nil }
        let conflict = conflicts[row]
        switch tableColumn?.identifier.rawValue {
        case "action":
            let picker = NSPopUpButton()
            picker.addItems(withTitles: ["Пропустить", "Заменить", "Другое имя", "Если источник новее", "Добавить в конец", "Продолжить"].map(L10n.text))
            picker.autoenablesItems = false
            picker.item(at: 1)?.isEnabled = conflict.canReplace
            picker.item(at: 3)?.isEnabled = conflict.canCompareDates
            picker.item(at: 4)?.isEnabled = conflict.canReplace
            picker.item(at: 5)?.isEnabled = conflict.canResume
            picker.tag = row; picker.selectItem(at: actions[row])
            picker.target = self; picker.action = #selector(actionChanged(_:))
            picker.setAccessibilityLabel(L10n.text("Действие") + ": " + conflict.mapping.source)
            return picker
        case "name":
            let field = NSTextField(string: names[row]); field.tag = row; field.delegate = self
            field.isEnabled = actions[row] == 2
            field.setAccessibilityLabel(L10n.text("Новое имя") + ": " + conflict.mapping.source)
            return field
        default:
            let field = NSTextField(wrappingLabelWithString: conflict.mapping.source + "\n→ " + conflict.mapping.destination)
            field.font = .systemFont(ofSize: 11); field.isSelectable = true
            field.toolTip = field.stringValue
            return field
        }
    }
    @objc private func actionChanged(_ sender: NSPopUpButton) {
        guard conflicts.indices.contains(sender.tag) else { return }
        actions[sender.tag] = sender.selectedItem?.isEnabled == true ? sender.indexOfSelectedItem : 0
        table.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integer: 2))
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, conflicts.indices.contains(field.tag) else { return }
        names[field.tag] = field.stringValue
    }
    @objc private func skipAll() { actions = Array(repeating: 0, count: conflicts.count); table.reloadData() }
    @objc private func replaceFiles() { actions = conflicts.map { $0.canReplace ? 1 : 0 }; table.reloadData() }
    private static func suggestedName(_ path: String, directory: Bool) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = directory ? "" : (name as NSString).pathExtension
        if ext.isEmpty || name.hasPrefix(".") { return name + "-copy" }
        return (name as NSString).deletingPathExtension + "-copy." + ext
    }

    static func runUISmokeChecks() throws -> [String] {
        guard AppRuntime.isSmoke, let base = AppRuntime.smokeStateDirectory else { throw NetworkError.io("Missing smoke state") }
        let root = base.appendingPathComponent("conflict-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/beta.txt"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("docs/alpha.txt")
        try Data("untouched".utf8).write(to: existing)
        let provider = ProviderUISmokeFixture(), token = TransferCancellation()
        guard let entry = try provider.stat(path: "/docs", cancellation: token) else { throw NetworkError.io("Missing fixture entry") }
        let plan = try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: [entry], into: root, policy: .mergeSkippingExisting)
        let editor = NetworkConflictEditor(plan: plan)
        let window = NSWindow(contentRect: editor.view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view; window.orderFront(nil)
        defer { window.close() }
        editor.view.layoutSubtreeIfNeeded()
        guard let regular = plan.conflicts.firstIndex(where: { $0.mapping.source == "/docs/alpha.txt" }),
              let typeConflict = plan.conflicts.firstIndex(where: { $0.mapping.source == "/docs/beta.txt" }),
              let picker = editor.table.view(atColumn: 1, row: regular, makeIfNecessary: true) as? NSPopUpButton,
              let blocked = editor.table.view(atColumn: 1, row: typeConflict, makeIfNecessary: true) as? NSPopUpButton else { throw NetworkError.io("Conflict rows unavailable") }
        guard blocked.item(at: 1)?.isEnabled == false else { throw NetworkError.io("Type conflict replacement enabled") }
        picker.selectItem(at: 2); picker.sendAction(picker.action, to: picker.target)
        guard let name = editor.table.view(atColumn: 2, row: regular, makeIfNecessary: true) as? NSTextField, name.isEnabled else { throw NetworkError.io("Rename field not enabled") }
        name.stringValue = "reviewed.txt"; editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        guard editor.decisions()["/docs/alpha.txt"] == .rename("reviewed.txt"), editor.decisions()["/docs/beta.txt"] == .skip else { throw NetworkError.io("Per-conflict choices lost") }
        editor.replaceFiles()
        guard editor.decisions()["/docs/alpha.txt"] == .replace, editor.decisions()["/docs/beta.txt"] == .skip,
              try Data(contentsOf: existing) == Data("untouched".utf8), provider.downloads == 0 else { throw NetworkError.io("Conflict editor mutated source or lost type restriction") }
        editor.skipAll()
        guard editor.decisions().values.allSatisfy({ $0 == .skip }) else { throw NetworkError.io("Skip-all failed") }
        return ["Network conflict table supports per-item rename and skip without mutations", "Replace-all affects only regular file pairs; type conflicts stay skipped"]
    }
}
