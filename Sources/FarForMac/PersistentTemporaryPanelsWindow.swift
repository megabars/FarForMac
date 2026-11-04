import AppKit
import FarCore

@MainActor
final class PersistentTemporaryPanelsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias Capture = (slot: Int?, items: [SearchMatch])
    private let store: PersistentTemporaryPanelsStore
    private let captureCurrent: () -> Capture?
    private let onOpen: (Int, [SavedSearchReference]) -> Void
    private let onError: (Error) -> Void
    private let onStored: (Int, [SavedSearchReference]) -> Void
    private var library: PersistentTemporaryPanels?
    private var ignoredLinkedSlot: Int?
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")

    init(store: PersistentTemporaryPanelsStore = .init(), captureCurrent: @escaping () -> Capture?,
         onOpen: @escaping (Int, [SavedSearchReference]) -> Void, onError: @escaping (Error) -> Void = { _ in },
         onStored: @escaping (Int, [SavedSearchReference]) -> Void = { _, _ in }) {
        self.store = store; self.captureCurrent = captureCurrent; self.onOpen = onOpen; self.onError = onError; self.onStored = onStored
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 510), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = L10n.text("Общие временные панели · 0–9")
        window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 620, height: 460); window.center(); window.delegate = self
        let help = NSTextField(wrappingLabelWithString: L10n.text("Десять списков локальных, архивных и сетевых ссылок. Открываются без проверки источников и входа в сеть. Источник восстанавливается только перед действием."))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("slot")); column.title = L10n.text("Панель"); column.width = 120
        let count = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("count")); count.title = L10n.text("Ссылок"); count.width = 90
        let origin = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("origins")); origin.title = L10n.text("Источники"); origin.width = 350
        table.addTableColumn(column); table.addTableColumn(count); table.addTableColumn(origin)
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
    func numberOfRows(in tableView: NSTableView) -> Int { PersistentTemporaryPanels.slotCount }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard (0..<PersistentTemporaryPanels.slotCount).contains(row) else { return nil }
        if tableColumn?.identifier.rawValue == "count" { return library.map { String($0.slots[row].count) } ?? "—" }
        if tableColumn?.identifier.rawValue == "origins" { return library.map { Self.originSummary($0.slots[row]) } ?? "—" }
        return "\(row)" + (library?.lastOpenedSlot == row ? "  ✓" : "")
    }
    var savedLastMixed: [SavedSearchReference] { library?.lastMixed ?? [] }
    var hasSavedLast: Bool { !savedLastMixed.isEmpty }
    func persistLastMixed(_ items: [SearchMatch]) {
        do { var candidate = try requireLibrary(); try candidate.setLastMixed(items); try commit(candidate) }
        catch { fail(error) }
    }
    private static func originSummary(_ items: [SavedSearchReference]) -> String {
        var local = 0, archive = 0, remote = 0
        for item in items { switch item { case .local: local += 1; case .archive: archive += 1; case .remote: remote += 1 } }
        return L10n.text("Локальные") + ": \(local) · " + L10n.text("Архивы") + ": \(archive) · " + L10n.text("Сеть") + ": \(remote)"
    }
    private var selectedSlot: Int { (0..<PersistentTemporaryPanels.slotCount).contains(table.selectedRow) ? table.selectedRow : 0 }
    private func setStatus(_ message: String, error: Bool = false) {
        status.stringValue = message; status.textColor = error ? .systemRed : .secondaryLabelColor
    }
    private func fail(_ error: Error) { setStatus(L10n.text(error.localizedDescription), error: true); onError(error) }
    private func requireLibrary() throws -> PersistentTemporaryPanels {
        guard let library else { throw PanelSessionError("Общие панели не загружены. Исправьте файл и нажмите «Перезагрузить».") }
        return library
    }
    private func captureLinked(into candidate: inout PersistentTemporaryPanels) throws {
        guard let capture = captureCurrent(), let slot = capture.slot, slot != ignoredLinkedSlot else { return }
        try candidate.replace(capture.items, in: slot)
    }
    private func commit(_ candidate: PersistentTemporaryPanels) throws {
        let changed = (0..<PersistentTemporaryPanels.slotCount).filter { library?.slots[$0] != candidate.slots[$0] }
        try store.save(candidate); library = candidate; table.reloadData()
        for slot in changed { onStored(slot, candidate.slots[slot]) }
    }
    /// Connect both file panels' onVirtualLibrarySnapshot to this method.
    /// Conflicts are reported without changing the stored file or recapturing sources.
    func updateLinkedSlot(_ slot: Int, items: [SearchMatch]) {
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
            setStatus(L10n.text("Общая панель открыта без проверки. Enter/F3/F4/F5 восстановят выбранный источник перед действием."))
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
    @objc private func clearSelected() { clearSlot(selectedSlot, confirming: true) }
    private func clearSlot(_ slot: Int, confirming: Bool) {
        do {
            if confirming {
                let alert = NSAlert(); alert.messageText = L10n.text("Очистить список ссылок общей панели?")
                alert.informativeText = L10n.text("Исходные файлы останутся на месте.")
                alert.addButton(withTitle: L10n.text("Очистить список")); alert.addButton(withTitle: L10n.text("Отмена"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
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
            for slot in 0..<PersistentTemporaryPanels.slotCount { onStored(slot, reloaded.slots[slot]) }
            setStatus(L10n.text("Списки перечитаны. Открытые общие панели синхронизированы с сохранённой версией."))
        } catch { fail(error) }
    }
    @objc private func closeLibrary() { window?.performClose(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        do { try persistLinkedPanel(); return true } catch { fail(error); return false }
    }

    static func runUISmokeChecks() throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Persistent panel smoke requires isolated state") }
        let directory = root.appendingPathComponent("persistent-panels-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("alpha.txt"); try Data("original".utf8).write(to: file)
        let local = try SearchResult.capture(file)
        let archive = try ArchiveWriter.create(sources: [file], destination: directory.appendingPathComponent("source.zip"), format: .zip)
        let provider = ProviderUISmokeFixture()
        var options = SearchOptions(roots: [directory]); options.namePattern = "alpha.txt"
        let request = SearchRequest(options: options)
        var matches: [SearchMatch] = [.local(local)]
        _ = ProviderSearchEngine.runArchive(archive, request: request, cancellation: ProviderSearchCancellation()) {
            if case .result(let result) = $0 { matches.append(.archive(result)) }
        }
        _ = ProviderSearchEngine.runRemote(provider: provider, root: "/docs", request: request, cancellation: ProviderSearchCancellation()) {
            if case .result(let result) = $0 { matches.append(.remote(result, provider)) }
        }
        guard matches.count == 3 else { throw PanelSessionError("Persistent mixed fixture missing source types") }
        let references = try matches.map { try SavedSearchReference(capturing: $0) }
        let store = PersistentTemporaryPanelsStore(url: directory.appendingPathComponent("library/mixed-panels.json"))
        var current: Capture? = (nil, matches), errors: [Error] = [], opens: [Int] = []
        let chooser = PersistentTemporaryPanelsWindow(store: store, captureCurrent: { current }, onOpen: { slot, references in
            current = (slot, references.map(SearchMatch.saved)); opens.append(slot)
        }, onError: { errors.append($0) })
        defer { chooser.window?.orderOut(nil) }
        guard opens.isEmpty else { throw PanelSessionError("Constructing saved chooser must not open a source") }
        for slot in 0..<10 { chooser.updateLinkedSlot(slot, items: matches) }
        chooser.persistLastMixed(matches)
        matches.removeAll()
        try FileManager.default.removeItem(at: file); try FileManager.default.removeItem(at: archive.sourceURL)
        for slot in 0..<10 { chooser.openSlot(slot) }
        chooser.saveCapture(append: false); chooser.saveCapture(append: true)
        let stored = try PersistentTemporaryPanelsStore(url: store.url).load()
        guard errors.isEmpty, opens == Array(0..<10), stored.slots.allSatisfy({ $0 == references }), stored.lastMixed == references,
              provider.downloads == 0, !FileManager.default.fileExists(atPath: file.path) else {
            throw PanelSessionError("Offline common slots lost missing sources, duplicates, or performed network/file actions")
        }
        var restartedOpen: [SavedSearchReference] = []
        let restarted = PersistentTemporaryPanelsWindow(store: PersistentTemporaryPanelsStore(url: store.url), captureCurrent: { nil }, onOpen: { _, refs in restartedOpen = refs })
        defer { restarted.window?.orderOut(nil) }
        restarted.openSlot(4)
        guard restartedOpen == references, restarted.savedLastMixed == references, restarted.hasSavedLast else { throw PanelSessionError("Recreated chooser lost offline common slots or last mixed results") }

        let panels = [PanelView(directory: directory, key: "persist-left-" + UUID().uuidString), PanelView(directory: directory, key: "persist-right-" + UUID().uuidString)]
        defer { panels.forEach { $0.leaveVirtualResults(focus: false) } }
        var active = 0, linkedErrors: [Error] = [], snapshots = 0
        let linkedStore = PersistentTemporaryPanelsStore(url: directory.appendingPathComponent("linked/mixed-panels.json"))
        let linked = PersistentTemporaryPanelsWindow(store: linkedStore, captureCurrent: {
            (panels[active].virtualLibrarySlot, panels[active].virtualResults)
        }, onOpen: { slot, refs in
            do { try panels[active].showVirtualLibrarySlot(slot, matches: refs.map(SearchMatch.saved), focusPanel: false) }
            catch { linkedErrors.append(error) }
        }, onError: { linkedErrors.append($0) }, onStored: { slot, refs in
            for panel in panels { do { try panel.refreshVirtualLibrarySlot(slot, references: refs) } catch { linkedErrors.append(error) } }
        })
        defer { linked.window?.orderOut(nil) }
        linked.updateLinkedSlot(0, items: references.map(SearchMatch.saved))
        for panel in panels {
            panel.onVirtualLibrarySnapshot = { slot, items in snapshots += 1; linked.updateLinkedSlot(slot, items: items) }
            try panel.showVirtualLibrarySlot(0, matches: references.map(SearchMatch.saved), focusPanel: false)
        }
        let firstID = panels[0].cursorVirtualResult?.id
        let restoreGeneration = panels[0].locationGeneration
        panels[0].markAll()
        try panels[0].applyRestoredVirtualMatches([.local(local)])
        try panels[0].refreshVirtualLibrarySlot(0, references: references)
        guard panels[0].locationGeneration == restoreGeneration, panels[0].virtualLibrarySlot == 0, panels[0].cursorVirtualResult?.id == firstID,
              panels[0].selectedVirtualResults.count == 3,
              panels[0].virtualResults.contains(where: { if case .local = $0 { return true }; return false }), snapshots == 3 else {
            throw PanelSessionError("Verified restoration or matching store sync lost live reference, marks, cursor or link")
        }
        panels[0].clearMarks()
        var revealed: String?
        panels[0].onVirtualReveal = { _, item in revealed = item.id }
        panels[0].openSelection()
        guard revealed == firstID else { throw PanelSessionError("Offline Enter lost typed saved reference") }
        panels[0].removeVirtualSelection()
        guard panels.allSatisfy({ $0.virtualResults.count == 2 }), snapshots == 4 else { throw PanelSessionError("Reference removal did not synchronize both linked panels exactly once") }
        linked.clearSlot(0, confirming: false)
        guard panels.allSatisfy({ $0.virtualResults.isEmpty && $0.virtualLibrarySlot == 0 }) else { throw PanelSessionError("Clear failed to synchronize both common panels") }
        linked.updateLinkedSlot(0, items: references.map(SearchMatch.saved))
        let external = PersistentTemporaryPanelsStore(url: linkedStore.url)
        var edited = try external.load(); try edited.clear(0); try external.save(edited)
        linked.updateLinkedSlot(0, items: references.map(SearchMatch.saved))
        guard linkedErrors.count == 1 else { throw PanelSessionError("External change was not reported as an optimistic conflict") }
        linked.reloadLibrary()
        guard panels.allSatisfy({ $0.virtualResults.isEmpty }), snapshots == 5 else { throw PanelSessionError("Explicit reload wrote back stale references") }
        linked.openSlot(9); active = 1; linked.openSlot(8)
        guard try PersistentTemporaryPanelsStore(url: linkedStore.url).load().slots[0].isEmpty else { throw PanelSessionError("Inactive linked panel resurrected deleted references") }

        // Synthetic offline descriptors test the UI boundary without creating 10,001 files.
        let template = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as! [String: Any]
        let oversized = (0...10_000).map { index -> [String: Any] in
            var item = template; let url = directory.appendingPathComponent("limit-\(index).txt")
            item["url"] = url.absoluteString; item["name"] = url.lastPathComponent; item["capturedIdentityPath"] = url.path; return item
        }
        let large = try JSONDecoder().decode([SearchResult].self, from: JSONSerialization.data(withJSONObject: oversized)).map { SearchMatch.saved(.local($0)) }
        var rejected = false
        do { try panels[0].showVirtualLibrarySlot(7, matches: large, focusPanel: false) } catch { rejected = true }
        guard rejected, panels[0].virtualLibrarySlot == 9, panels[0].virtualResults.isEmpty else { throw PanelSessionError("Common panel count cap changed the previous linked state") }
        let priorGeneration = panels[0].locationGeneration
        try panels[0].showVirtualResults([.saved(references[0])], focusPanel: false)
        guard panels[0].locationGeneration > priorGeneration, panels[0].virtualLibrarySlot == nil else { throw PanelSessionError("Independent virtual results retained the common-slot link") }
        return ["All ten mixed common slots and last results survive chooser recreation without file checks or network login",
                "Missing local/archive/network references remain visible and survive save and append unchanged",
                "Reference removal, clear and explicit reload synchronize both linked panels without stale resurrection",
                "External store conflicts are reported; 10,001 offline references are rejected without changing panel state"]
    }
}
