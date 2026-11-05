import AppKit
import FarCore

/// Typed runtime and persisted references. Display paths never become local operation URLs.
@MainActor
final class VirtualResultsPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    var onSwitchPanel: (() -> Void)?
    var onDelete: (() -> Void)?
    var onAction: ((NSEvent) -> Bool)?
    var onReveal: ((SearchMatch) -> Void)?
    var onChange: (() -> Void)?
    var onResultsChange: (([SearchMatch]) -> Void)?
    private(set) var collection: TemporarySearchCollection
    private(set) var visible: [SearchMatch] = []
    let table = FileTable()
    private let summary = label("", size: 10, color: Palette.muted)
    private var selection = PanelSelection()
    private var shiftMarking: Bool?
    private var active = false
    private var filter = ""
    private var options = FileSortOptions()
    var results: [SearchMatch] { collection.items }
    var cursorResult: SearchMatch? { visible.first { $0.id == selection.cursorID } }
    var selectedResults: [SearchMatch] {
        let ids = Set(selection.operationIDs(orderedIDs: visible.map(\.id)))
        return visible.filter { ids.contains($0.id) }
    }
    var markedResults: [SearchMatch] { visible.filter { selection.markedIDs.contains($0.id) } }

    init(results: [SearchMatch]) throws {
        try Self.checkCount(results)
        collection = TemporarySearchCollection(results)
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = Palette.panel.cgColor
        table.backgroundColor = Palette.panel; table.rowHeight = 29
        table.intercellSpacing = .zero; table.focusRingType = .none
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(revealSelection)
        table.setAccessibilityLabel(L10n.text("Временная панель результатов поиска"))
        for (id, title, width) in [("name", "Имя", CGFloat(240)), ("origin", "Полный исходный путь", CGFloat(380)), ("size", "Размер", CGFloat(95)), ("modified", "Изменён", CGFloat(145))] {
            let column = NSTableColumn(identifier: .init(id)); column.title = L10n.text(title); column.width = width
            column.minWidth = 70; table.addTableColumn(column)
        }
        table.onFocus = { [weak self] in self?.onFocus?() }
        table.onKey = { [weak self] in self?.handleKey($0) ?? false }
        table.onShiftRelease = { [weak self] in self?.shiftMarking = nil }
        table.onSelectAll = { [weak self] in self?.markAll() }
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.drawsBackground = false
        for view in [scroll, summary] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            summary.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// AppKit may keep a detached view alive until its current event/autorelease
    /// pool ends. End the source lease explicitly when the host closes the panel.
    func releaseReferences() {
        onDelete = nil; onFocus = nil; onClose = nil; onSwitchPanel = nil; onAction = nil
        onReveal = nil; onChange = nil; onResultsChange = nil
        collection.removeAll(); visible.removeAll(); selection = PanelSelection()
        table.reloadData()
    }
    func focus() { window?.makeFirstResponder(table) }
    func setActive(_ value: Bool) {
        active = value
        table.enumerateAvailableRowViews { view, _ in (view as? FileRow)?.active = value; view.needsDisplay = true }
    }
    private static func checkCount(_ results: [SearchMatch]) throws {
        guard Set(results.map(\.id)).count <= TemporarySearchCollection.maximumCount else {
            throw PanelSessionError(L10n.text("Во временной панели допускается не более 10 000 уникальных ссылок."))
        }
    }
    func replace(_ results: [SearchMatch]) throws { try Self.checkCount(results); collection.replace(results); rebuild(); onResultsChange?(collection.items) }
    /// Store reload and verified restoration may replace the original reference object.
    /// Selection is reconciled by the unchanged typed identity, without recapturing files.
    func replaceReferences(_ results: [SearchMatch]) throws {
        try Self.checkCount(results)
        collection.removeAll(); collection.replace(results); rebuild(); onResultsChange?(collection.items)
    }
    func append(_ results: [SearchMatch]) throws { try Self.checkCount(collection.items + results); collection.append(results); rebuild(); onResultsChange?(collection.items) }
    func setFilter(_ value: String) { filter = value; rebuild() }
    func setSortOptions(_ value: FileSortOptions) { options = value; rebuild() }
    func removeCompleted(ids: Set<String>) {
        collection.remove(ids: ids); rebuild(); onResultsChange?(collection.items)
    }
    func removeSelection() {
        collection.remove(ids: Set(selectedResults.map(\.id)))
        rebuild(); onResultsChange?(collection.items)
    }
    func saveSelectionForOperation() { selection.saveMarks(); shiftMarking = nil }
    func markAll() { selection.saveMarks(); selection.setMarked(visible.map(\.id), marked: true); rebuild() }
    func clearMarks() { selection.clearMarks(); rebuild() }
    func restoreMarks() { selection.restoreMarks(validIDs: visible.map(\.id)); rebuild() }
    func invertMarks(includeDirectories: Bool = false) {
        selection.saveMarks()
        selection.invert(visible.filter { includeDirectories || !$0.isDirectory || selection.markedIDs.contains($0.id) }.map(\.id)); rebuild()
    }
    func selectSameName(mark: Bool, byExtension: Bool) {
        guard let current = cursorResult else { return }
        let key: (SearchMatch) -> String = { byExtension ? ($0.name as NSString).pathExtension : ($0.name as NSString).deletingPathExtension }
        let name = key(current)
        selection.saveMarks()
        selection.setMarked(visible.filter { (!mark || !$0.isDirectory) && key($0).caseInsensitiveCompare(name) == .orderedSame }.map(\.id), marked: mark)
        rebuild()
    }
    func applyMask(_ expression: String, groups: [String: String], mark: Bool, includeDirectories: Bool) throws {
        let names = try FileMask(expression, groups: groups).matchingNames(visible.map(\.name), timeLimit: 0.25)
        selection.saveMarks()
        selection.setMarked(visible.filter { (!mark || includeDirectories || !$0.isDirectory) && names.contains($0.name) }.map(\.id), marked: mark)
        rebuild()
    }
    func toggleMarkAndAdvance() {
        guard let current = cursorResult else { return }
        let next = table.selectedRow + 1
        selection.saveMarks(); selection.toggle(current.id); rebuild(); moveCursor(to: next)
    }
    func moveCursor(by amount: Int) { moveCursor(to: table.selectedRow + amount) }
    func find(_ query: String, backwards: Bool, includeCurrent: Bool) throws {
        guard !query.isEmpty, !visible.isEmpty else { return }
        let prefix = query.precomposedStringWithCanonicalMapping.map { character -> String in
            switch character { case "*": return ".*"; case "?": return "."; default: return NSRegularExpression.escapedPattern(for: String(character)).replacingOccurrences(of: "/", with: "\\/") }
        }.joined()
        let names = try FileMask("/^" + prefix + "/i").matchingNames(visible.map(\.name), timeLimit: 0.25)
        let first = includeCurrent ? 0 : 1
        for step in first..<(visible.count + first) {
            let index = (max(0, table.selectedRow) + (backwards ? -step : step) + visible.count * 2) % visible.count
            if names.contains(visible[index].name) { moveCursor(to: index); return }
        }
    }
    private func rebuild() {
        let cursor = selection.cursorID, previousRow = table.selectedRow
        visible = collection.items.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) || $0.displayPath.localizedCaseInsensitiveContains(filter) }
        selection.reconcile(validIDs: visible.map(\.id))
        visible.sort { lhs, rhs in
            if options.directoriesFirst && lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order: ComparisonResult
            switch options.sort {
            case .size: order = lhs.size == rhs.size ? .orderedSame : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            case .modified: let left = lhs.modified ?? .distantPast, right = rhs.modified ?? .distantPast; order = left.compare(right)
            case .selected: let left = selection.markedIDs.contains(lhs.id), right = selection.markedIDs.contains(rhs.id); order = left == right ? .orderedSame : (left ? .orderedAscending : .orderedDescending)
            case .extension: order = compare((lhs.name as NSString).pathExtension, (rhs.name as NSString).pathExtension)
            default: order = compare(lhs.name, rhs.name)
            }
            let resolved = order == .orderedSame ? compare(lhs.displayPath, rhs.displayPath) : order
            if resolved == .orderedSame { return lhs.id < rhs.id }
            return options.ascending ? resolved == .orderedAscending : resolved == .orderedDescending
        }
        table.reloadData()
        moveCursor(to: cursor.flatMap { id in visible.firstIndex { $0.id == id } } ?? max(0, previousRow))
        updateSummary()
        onChange?()
    }
    private func updateSummary() {
        let savedCount = collection.items.filter { if case .saved = $0 { return true }; return false }.count
        let offline = savedCount == 0 ? "" : " · " + L10n.text("Не проверено") + ": \(savedCount) " + L10n.text("(проверка перед действием)")
        summary.stringValue = L10n.text("Показано") + ": \(visible.count)/\(collection.items.count) · " + L10n.text("Отмечено") + ": \(selection.markedIDs.count)" + L10n.text(" · Enter — к источнику · F7 — убрать ссылку · F8/Del — удалить объект · Esc — к папке") + offline
    }
    private func compare(_ left: String, _ right: String) -> ComparisonResult {
        var flags: String.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
        if options.naturalOrder { flags.insert(.numeric) }
        return left.compare(right, options: flags, locale: .current)
    }
    private func moveCursor(to requested: Int) {
        guard !visible.isEmpty else { table.deselectAll(nil); selection.focus(nil); onChange?(); return }
        let row = max(0, min(requested, visible.count - 1))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        selection.focus(visible[row].id); updateSummary(); onChange?()
    }
    @objc func revealSelection() { if let result = cursorResult { onReveal?(result) } }
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, modifiers.isEmpty { onClose?(); return true }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift { onSwitchPanel?(); return true }
        if [36, 76].contains(event.keyCode), modifiers.isEmpty { revealSelection(); return true }
        if event.keyCode == 98, modifiers.isEmpty { removeSelection(); return true }
        if [51, 117, 100].contains(event.keyCode), modifiers.isEmpty { onDelete?(); return true }
        if [49, 114].contains(event.keyCode), modifiers.isEmpty {
            if event.keyCode == 114 { toggleMarkAndAdvance() }
            else if let current = cursorResult { selection.saveMarks(); selection.toggle(current.id); rebuild() }
            return true
        }
        if [125, 126, 115, 119, 116, 121].contains(event.keyCode), modifiers.isEmpty || modifiers == .shift {
            if modifiers == .shift, let current = cursorResult {
                if shiftMarking == nil { selection.saveMarks(); shiftMarking = !selection.markedIDs.contains(current.id) }
                selection.setMarked([current.id], marked: shiftMarking == true); table.reloadData()
            }
            let page = max(1, Int((table.enclosingScrollView?.contentSize.height ?? 200) / table.rowHeight))
            switch event.keyCode { case 115: moveCursor(to: 0); case 119: moveCursor(to: visible.count - 1); case 116: moveCursor(by: -page); case 121: moveCursor(by: page); default: moveCursor(by: event.keyCode == 126 ? -1 : 1) }
            return true
        }
        if modifiers.isEmpty, event.charactersIgnoringModifiers == "+" { markAll(); return true }
        if modifiers.isEmpty, event.charactersIgnoringModifiers == "-" { clearMarks(); return true }
        if modifiers.isEmpty, event.charactersIgnoringModifiers == "*" { invertMarks(); return true }
        return onAction?(event) ?? false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableViewSelectionDidChange(_ notification: Notification) {
        selection.focus(visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].id : nil); onChange?()
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let view = FileRow(); view.active = active; return view }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let sort: FileSort
        switch tableColumn.identifier.rawValue { case "size": sort = .size; case "modified": sort = .modified; default: sort = .name }
        if options.sort == sort { options.ascending.toggle() } else { options.sort = sort }; rebuild()
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let item = visible[row], field = label("", size: 12)
        switch tableColumn?.identifier.rawValue {
        case "origin":
            let origin: String
            switch item {
            case .local: origin = "Локальный"
            case .archive: origin = "Архив"
            case .remote: origin = "Сеть"
            case .saved(let reference):
                switch reference { case .local: origin = "Локальный · не проверен"; case .archive: origin = "Архив · не проверен"; case .remote: origin = "Сеть · не проверена" }
            }
            field.stringValue = "[" + L10n.text(origin) + "] " + item.displayPath
            field.toolTip = field.stringValue; field.textColor = Palette.muted
        case "size": field.stringValue = item.isDirectory ? L10n.text("<ПАПКА>") : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file); field.alignment = .right
        case "modified": field.stringValue = item.modified?.formatted(date: .numeric, time: .shortened) ?? ""; field.textColor = Palette.muted
        default: field.stringValue = "\(selection.markedIDs.contains(item.id) ? "◆" : " ") \(item.isDirectory ? "▸ " : "")\(item.name)"; field.textColor = selection.markedIDs.contains(item.id) || item.isDirectory ? Palette.accent : Palette.text
        }
        return field
    }
}

extension PanelView {
    static func runVirtualResultsUISmokeChecks() throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Virtual results smoke requires isolated state") }
        let folder = root.appendingPathComponent("virtual-results-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("alpha.txt")
        try Data("local source".utf8).write(to: local)
        let inner = try ArchiveWriter.create(sources: [local], destination: folder.appendingPathComponent("inner.zip"), format: .zip)
        let outer = try ArchiveWriter.create(sources: [inner.sourceURL], destination: folder.appendingPathComponent("outer.zip"), format: .zip)
        weak var retainedProvider: ProviderUISmokeFixture?
        func makeResults() throws -> ([SearchMatch], URL) {
            let nested = try ArchiveNavigationFrame(snapshot: outer).openNested(path: "inner.zip")
            let provider = ProviderUISmokeFixture(); retainedProvider = provider
            var options = SearchOptions(roots: [folder]); options.namePattern = "alpha.txt"
            let request = SearchRequest(options: options)
            var items: [SearchMatch] = [.local(try SearchResult.capture(local))]
            _ = ProviderSearchEngine.runArchive(nested.snapshot, request: request, cancellation: ProviderSearchCancellation()) {
                if case .result(let result) = $0 { items.append(.archive(result)) }
            }
            _ = ProviderSearchEngine.runRemote(provider: provider, root: "/docs", request: request, cancellation: ProviderSearchCancellation()) {
                if case .result(let result) = $0 { items.append(.remote(result, provider)) }
            }
            return (items, nested.snapshot.sourceURL)
        }
        var (items, nestedCopy) = try makeResults()
        guard items.count == 3, Set(items.map(\.id)).count == 3 else { throw PanelSessionError("Mixed virtual references collide") }
        let key = "virtual-results-" + UUID().uuidString
        let panel = PanelView(directory: folder, key: key)
        panel.filterField.stringValue = "directory-filter"
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        defer { window.contentView = nil; window.close() }
        var mutationCounts: [Int] = []
        panel.onVirtualResultsChange = { mutationCounts.append($0.count) }
        try panel.showVirtualResults(items, focusPanel: false)
        items.removeAll()
        weak var browser = panel.virtualPanel
        window.contentView?.layoutSubtreeIfNeeded()
        guard panel.isVirtual, !panel.isTemporary, panel.virtualResults.count == 3,
              panel.selectedEntries.isEmpty, panel.cursorEntry == nil, panel.temporaryResults.isEmpty,
              FileManager.default.fileExists(atPath: nestedCopy.path), retainedProvider != nil,
              panel.virtualResults.contains(where: { $0.displayPath.contains("outer.zip !/inner.zip !/alpha.txt") }) else { throw PanelSessionError("Mixed panel lost source references or exposed local operation paths") }
        let generation = panel.locationGeneration
        panel.load(); panel.refresh(); panel.goToPath(); panel.persistSession()
        guard panel.isVirtual, panel.locationGeneration == generation,
              AppPreferences.defaults.data(forKey: "panel.\(key).session") == nil else { throw PanelSessionError("Virtual panel escaped through local refresh/path/persistence") }
        var revealedID: String?
        panel.onVirtualReveal = { _, result in revealedID = result.id }
        panel.openSelection()
        guard revealedID == panel.cursorVirtualResult?.id else { throw PanelSessionError("Virtual Enter lost typed identity") }
        panel.markAll()
        guard panel.selectedVirtualResults.count == 3 else { throw PanelSessionError("Virtual Select All lost marks") }
        panel.clearMarks()
        try panel.applyMask("alpha.txt", mark: true)
        guard panel.selectedVirtualResults.count == 3 else { throw PanelSessionError("Virtual mask selection lost source duplicates") }
        panel.clearMarks()
        panel.focusFilter(); panel.filterField.stringValue = "ui-smoke.invalid"; panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.filterField))
        guard panel.virtualPanel?.visible.count == 1 else { throw PanelSessionError("Virtual full-origin filter mismatch") }
        var deletionRequests = 0
        panel.virtualPanel?.onDelete = { deletionRequests += 1 }
        let beforeDeletion = panel.virtualResults.count
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 100) {
            panel.virtualPanel?.table.keyDown(with: event)
        }
        guard deletionRequests == 1, panel.virtualResults.count == beforeDeletion else { throw PanelSessionError("F8 removed a reference instead of requesting confirmed source deletion") }
        panel.removeVirtualSelection()
        guard panel.virtualResults.count == 2, mutationCounts == [3, 2],
              try Data(contentsOf: local) == Data("local source".utf8),
              FileManager.default.fileExists(atPath: outer.sourceURL.path),
              FileManager.default.fileExists(atPath: nestedCopy.path), retainedProvider == nil else { throw PanelSessionError("Removing a virtual reference deleted data or retained removed provider") }
        panel.leaveVirtualResults(focus: false)
        guard !panel.isVirtual, browser?.results.isEmpty ?? true else { throw PanelSessionError("Virtual exit retained source references in detached AppKit view") }
        guard !FileManager.default.fileExists(atPath: nestedCopy.path) else { throw PanelSessionError("Virtual exit retained nested workspace after releasing sources") }
        guard panel.filterField.stringValue == "directory-filter", mutationCounts == [3, 2] else { throw PanelSessionError("Virtual exit changed directory filter or result history") }
        return ["Mixed local/archive/network results occupy the actual panel with distinct typed identities and full origins",
                "Virtual cursor marks masks filtering Enter and reference-only removal preserve underlying files",
                "Virtual refresh/path/session guards prevent local operations or disk persistence",
                "Panel exit restores directory filter and releases nested workspace/provider references"]
    }
}
