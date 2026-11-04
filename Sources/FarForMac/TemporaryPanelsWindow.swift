import AppKit
import FarCore

@MainActor
final class TemporaryPanelsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias Capture = (slot: Int?, items: [SearchResult])
    private let store: TemporaryPanelLibraryStore
    private let captureCurrent: () -> Capture?
    private let onOpen: (Int, [SearchResult]) -> Void
    private let onError: (Error) -> Void
    private let onStored: (Int, [SearchResult]) -> Void
    private var library: TemporaryPanelLibrary?
    private var ignoredLinkedSlot: Int?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(store: TemporaryPanelLibraryStore = .init(), captureCurrent: @escaping () -> Capture?,
         onOpen: @escaping (Int, [SearchResult]) -> Void, onError: @escaping (Error) -> Void = { _ in },
         onStored: @escaping (Int, [SearchResult]) -> Void = { _, _ in }) {
        self.store = store; self.captureCurrent = captureCurrent; self.onOpen = onOpen; self.onError = onError; self.onStored = onStored
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 510), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.text("Общие временные панели · 0–9")
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 620, height: 460); window.center(); window.delegate = self
        let help = NSTextField(wrappingLabelWithString: L10n.text("Десять отдельных списков ссылок. Открытие меняет активную панель; сохранение и очистка списка не изменяют исходные файлы."))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("slot")); column.title = L10n.text("Панель"); column.width = 180
        let count = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("count")); count.title = L10n.text("Снимков"); count.width = 180
        table.addTableColumn(column); table.addTableColumn(count)
        table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = false
        table.rowHeight = 25; table.target = self; table.doubleAction = #selector(openSelected)
        table.setAccessibilityLabel(L10n.text("Десять общих временных панелей"))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let open = NSButton(title: L10n.text("Открыть"), target: self, action: #selector(openSelected)); open.keyEquivalent = "\r"
        let save = NSButton(title: L10n.text("Сохранить текущую"), target: self, action: #selector(saveCurrent))
        let append = NSButton(title: L10n.text("Добавить текущую"), target: self, action: #selector(appendCurrent))
        let clear = NSButton(title: L10n.text("Очистить список"), target: self, action: #selector(clearSelected))
        let reload = NSButton(title: L10n.text("Перезагрузить"), target: self, action: #selector(reloadLibrary))
        let close = NSButton(title: L10n.text("Закрыть"), target: self, action: #selector(closeLibrary))
        let first = NSStackView(views: [open, save, append, NSView()]); first.spacing = 8
        let second = NSStackView(views: [clear, reload, NSView(), close]); second.spacing = 8
        let content = NSView()
        for view in [help, scroll, status, first, second] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            help.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 12),
            status.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 9),
            first.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            second.topAnchor.constraint(equalTo: first.bottomAnchor, constant: 8),
            second.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ] + [help, scroll, status, first, second].flatMap { view in [view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)] })
        window.contentView = content; window.initialFirstResponder = table
        do {
            library = try store.load(); table.reloadData()
            table.selectRowIndexes(IndexSet(integer: library?.lastOpenedSlot ?? 0), byExtendingSelection: false)
            setStatus(L10n.text("Списки загружены. Файлы не открывались и не изменялись."))
        } catch { fail(error) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(table)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { TemporaryPanelLibrary.slotCount }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard (0..<TemporaryPanelLibrary.slotCount).contains(row) else { return nil }
        if tableColumn?.identifier.rawValue == "count" { return library.map { String($0.slots[row].count) } ?? "—" }
        return "\(row)" + (library?.lastOpenedSlot == row ? "  ✓" : "")
    }
    private var selectedSlot: Int { (0..<TemporaryPanelLibrary.slotCount).contains(table.selectedRow) ? table.selectedRow : 0 }
    private func setStatus(_ message: String, error: Bool = false) {
        status.stringValue = message; status.textColor = error ? .systemRed : .secondaryLabelColor
    }
    private func fail(_ error: Error) { setStatus(error.localizedDescription, error: true); onError(error) }
    private func requireLibrary() throws -> TemporaryPanelLibrary {
        guard let library else { throw PanelSessionError("Общие панели не загружены. Исправьте файл и нажмите «Перезагрузить».") }
        return library
    }
    private func captureLinked(into candidate: inout TemporaryPanelLibrary) throws {
        guard let capture = captureCurrent(), let slot = capture.slot, slot != ignoredLinkedSlot else { return }
        try candidate.replace(capture.items, in: slot)
    }
    private func commit(_ candidate: TemporaryPanelLibrary) throws {
        let changed = (0..<TemporaryPanelLibrary.slotCount).filter { library?.slots[$0].map(\.id) != candidate.slots[$0].map(\.id) }
        try store.save(candidate); library = candidate; table.reloadData()
        for slot in changed { onStored(slot, candidate.slots[slot]) }
    }
    /// Connect both file panels' onTemporaryLibrarySnapshot to this method.
    /// Conflicts are reported without changing the stored file or recapturing sources.
    func updateLinkedSlot(_ slot: Int, items: [SearchResult]) {
        guard slot != ignoredLinkedSlot else { return }
        do {
            var candidate = try requireLibrary(); try candidate.replace(items, in: slot); try commit(candidate)
            setStatus(L10n.text("Список сохранён; исходные снимки файлов сохранены."))
        } catch { fail(error) }
    }
    func persistLinkedPanel() throws {
        guard let capture = captureCurrent(), capture.slot != nil, capture.slot != ignoredLinkedSlot else { return }
        var candidate = try requireLibrary()
        try captureLinked(into: &candidate); try commit(candidate)
    }
    /// Also supports a parent menu command selecting a particular numbered slot.
    func openSlot(_ slot: Int) {
        do {
            var candidate = try requireLibrary()
            try captureLinked(into: &candidate); try candidate.select(slot)
            let items = try candidate.items(in: slot)
            try commit(candidate)
            onOpen(slot, items); ignoredLinkedSlot = nil
            table.selectRowIndexes(IndexSet(integer: slot), byExtendingSelection: false)
            setStatus(L10n.text("Общая панель открыта. Исходники проверяются перед действиями."))
        } catch { fail(error) }
    }
    @objc private func openSelected() { openSlot(selectedSlot) }
    @objc private func saveCurrent() { saveCapture(append: false) }
    @objc private func appendCurrent() { saveCapture(append: true) }
    private func saveCapture(append: Bool) {
        do {
            guard let capture = captureCurrent() else { throw PanelSessionError("Сначала откройте временную панель с нужными ссылками.") }
            let slot = selectedSlot
            var candidate = try requireLibrary()
            if !append, !candidate.slots[slot].isEmpty, capture.slot != slot {
                let alert = NSAlert(); alert.messageText = L10n.text("Заменить содержимое общей панели?")
                alert.informativeText = "\(slot): \(candidate.slots[slot].count) → \(capture.items.count)"
                alert.addButton(withTitle: L10n.text("Заменить список")); alert.addButton(withTitle: L10n.text("Отмена"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            try captureLinked(into: &candidate)
            if append { try candidate.append(capture.items, to: slot) }
            else { try candidate.replace(capture.items, in: slot) }
            try commit(candidate)
            setStatus(L10n.text("Список сохранён; исходные снимки файлов сохранены."))
        } catch { fail(error) }
    }
    @objc private func clearSelected() {
        do {
            let slot = selectedSlot
            let alert = NSAlert(); alert.messageText = L10n.text("Очистить список ссылок общей панели?")
            alert.informativeText = L10n.text("Исходные файлы останутся на месте.")
            alert.addButton(withTitle: L10n.text("Очистить список")); alert.addButton(withTitle: L10n.text("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            var candidate = try requireLibrary(); try candidate.clear(slot); try commit(candidate)
            // Replace the active common panel with the same empty list, without file operations.
            if captureCurrent()?.slot == slot {
                let previousIgnore = ignoredLinkedSlot; ignoredLinkedSlot = slot
                onOpen(slot, [])
                ignoredLinkedSlot = previousIgnore == slot ? nil : previousIgnore
            }
            setStatus(L10n.text("Список очищен. Исходные файлы не изменялись."))
        } catch { fail(error) }
    }
    @objc private func reloadLibrary() {
        do {
            let reloaded = try store.load()
            ignoredLinkedSlot = nil
            library = reloaded; table.reloadData()
            // Reload is an explicit decision to use the disk version. Refresh every
            // linked view, including an inactive one, before it can save an old list.
            for slot in 0..<TemporaryPanelLibrary.slotCount { onStored(slot, reloaded.slots[slot]) }
            setStatus(L10n.text("Списки перечитаны. Открытые общие панели синхронизированы с сохранённой версией."))
        } catch { fail(error) }
    }
    @objc private func closeLibrary() { window?.performClose(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try persistLinkedPanel(); return true } catch { fail(error); return false }
    }

    static func runUISmokeChecks() throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FarCommonPanelUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("source.txt"); try Data("original".utf8).write(to: file)
        let item = try SearchResult.capture(file)
        let store = TemporaryPanelLibraryStore(url: directory.appendingPathComponent("library/panels.json"))
        var current: Capture? = (nil, [item]), opens: [(Int, [SearchResult])] = [], errors: [Error] = []
        let controller = TemporaryPanelsWindow(store: store, captureCurrent: { current }, onOpen: { slot, items in current = (slot, items); opens.append((slot, items)) }, onError: { errors.append($0) })
        defer { controller.window?.orderOut(nil) }
        guard opens.isEmpty else { throw PanelSessionError("Constructing common panel chooser must not open files or panels") }
        controller.saveCapture(append: false)
        controller.openSlot(0); controller.openSlot(9)
        guard opens.map({ $0.0 }) == [0, 9], opens[0].1.count == 1, opens[1].1.isEmpty else { throw PanelSessionError("Common panel slots did not switch independently") }
        current = (9, [item]); controller.updateLinkedSlot(9, items: [item])
        controller.openSlot(0)
        let restarted = try TemporaryPanelLibraryStore(url: store.url).load()
        guard errors.isEmpty, restarted.slots[0].count == 1, restarted.slots[9].count == 1, FileManager.default.fileExists(atPath: file.path) else { throw PanelSessionError("Common panel persistence changed sources or lost a slot") }
        var panes: [Capture?] = [(0, [item]), (0, [item])], activePane = 0
        let reloadStore = TemporaryPanelLibraryStore(url: directory.appendingPathComponent("reload/panels.json"))
        var initial = try reloadStore.load(); try initial.replace([item], in: 0); try reloadStore.save(initial)
        var reloadErrors: [Error] = []
        let reloader = TemporaryPanelsWindow(store: reloadStore, captureCurrent: { panes[activePane] }, onOpen: { slot, items in panes[activePane] = (slot, items) }, onError: { reloadErrors.append($0) }, onStored: { slot, items in
            for pane in panes.indices where panes[pane]?.slot == slot { panes[pane] = (slot, items) }
        })
        defer { reloader.window?.orderOut(nil) }
        let external = TemporaryPanelLibraryStore(url: reloadStore.url)
        var changed = try external.load(); try changed.clear(0); try external.save(changed)
        reloader.reloadLibrary()
        guard panes.allSatisfy({ $0?.items.isEmpty == true }) else { throw PanelSessionError("Reload must synchronize both linked panels") }
        reloader.openSlot(9); activePane = 1; reloader.openSlot(8)
        guard reloadErrors.isEmpty, try TemporaryPanelLibraryStore(url: reloadStore.url).load().slots[0].isEmpty else {
            throw PanelSessionError("Inactive linked panel resurrected entries after explicit reload")
        }
        return ["Ten common panel slots open independently without automatic file actions", "Common panel chooser persists original snapshots and keeps source files intact", "Explicit reload synchronizes both linked panels before switching without resurrecting removed references"]
    }
}
