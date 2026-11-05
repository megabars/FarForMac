import AppKit
import FarCore

private final class ProcessInfoLease {
    let root: URL, url: URL
    private var terminationObserver: NSObjectProtocol?
    init(text: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FarForMac-process-" + UUID().uuidString, isDirectory: true)
        url = root.appendingPathComponent("process.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try Data(text.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            if let root = self?.root { try? FileManager.default.removeItem(at: root) }
        }
    }
    deinit { if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }; try? FileManager.default.removeItem(at: root) }
}

/// ProcList is hosted in the selected file panel. The native metrics remain explicitly named.
@MainActor final class ProcessPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onFocus: (() -> Void)?, onClose: (() -> Void)?, onSwitchPanel: (() -> Void)?
    private let table = FileTable(), status = label("", size: 11, color: Palette.muted)
    private(set) var entries: [ProcessListEntry] = []
    private var token: TransferCancellation?, revision = UUID(), timer: Timer?
    private var active = false
    private var cursor: ProcessListEntry? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }
    init() {
        super.init(frame: .zero)
        for (id, title, width) in [("name", "Процесс", 230.0), ("pid", "PID", 70.0), ("cpu", "CPU %", 70.0), ("rss", "RSS", 100.0), ("uid", "UID", 70.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id != "cpu" && id != "rss"); table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.dataSource = self; table.delegate = self; table.rowHeight = 26; table.backgroundColor = Palette.panel
        table.allowsEmptySelection = true; table.setAccessibilityLabel("Панель процессов")
        table.target = self; table.doubleAction = #selector(activateProcess)
        table.onFocus = { [weak self] in self?.onFocus?() }
        table.onKey = { [weak self] in self?.key($0) ?? false }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let body = vertical([scroll, inset(status, x: 8, y: 6)])
        body.translatesAutoresizingMaskIntoConstraints = false; addSubview(body)
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor), body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() { window?.makeFirstResponder(table) }
    func setActive(_ value: Bool) { active = value; table.enumerateAvailableRowViews { view, _ in (view as? FileRow)?.active = value; view.needsDisplay = true } }
    func stop() { token?.cancel(); token = nil; revision = UUID(); timer?.invalidate(); timer = nil }
    func refresh() {
        guard token == nil else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.timer != nil, NSApp.modalWindow == nil else { return }
                    self.refresh()
                }
            }
        }
        let cancellation = TransferCancellation(), expected = UUID()
        token = cancellation; revision = expected
        Task {
            let result = await Task.detached { Result { try ProcessList.snapshot(cancellation: cancellation) } }.value
            guard revision == expected else { return }; token = nil
            switch result {
            case .success(let rows):
                let selected = cursor?.identity, firstLoad = entries.isEmpty
                entries = rows; sort(preserving: selected, selectFirst: firstLoad)

                status.stringValue = "Процессов: \(entries.count) · F3 сведения · F8 завершить"
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    func perform(function: Int, shifted: Bool = false) -> Bool {
        if shifted, function == 1 || function == 2 { changePriority(increase: function == 2); return true }
        guard !shifted else { return false }
        switch function {
        case 3: showInfo(); return true
        case 8: terminate(); return true
        default: return false
        }
    }
    private func key(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .control, event.keyCode == 15 { refresh(); return true }
        guard flags.isEmpty else { return false }
        if event.keyCode == 48 { onSwitchPanel?(); return true }
        if event.keyCode == 53 { onClose?(); return true }
        if event.keyCode == 36 { activateProcess(); return true }
        return false
    }
    @objc private func activateProcess() {
        guard let entry = cursor, let identity = entry.identity else { return }
        do {
            try ProcessControl.verify(identity)
            guard let app = NSRunningApplication(processIdentifier: entry.pid), app.activate(options: [.activateAllWindows]) else {
                status.stringValue = "У процесса нет доступного окна приложения."; return
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    private func showInfo() {
        guard let entry = cursor else { return }
        do {
            let priority = entry.identity.flatMap { try? ProcessControl.priority($0) }
            let text = "\(entry.name)\n\nPID: \(entry.pid)\nPPID: \(entry.parentPID)\nUID: \(entry.userID)\nCPU (macOS ps): \(entry.cpuPercent)%\nRSS: \(entry.residentBytes) bytes\nNice: \(priority.map(String.init) ?? "недоступно")\n\n\(entry.executable)\n"
            let lease = try ProcessInfoLease(text: text)
            let viewer = try ViewerWindow(url: lease.url, onEdit: { _, _, _ in false })
            viewer.retainedRemoteLease = lease; viewer.showWindow(nil)
        } catch { status.stringValue = error.localizedDescription }
    }
    private func terminate() {
        guard let entry = cursor, let identity = entry.identity else { status.stringValue = "Обновите панель перед завершением процесса."; return }
        let alert = NSAlert(); alert.messageText = "Завершить процесс?"
        alert.informativeText = "\(entry.name) · PID \(entry.pid)\n\(entry.executable)"
        alert.alertStyle = .warning; alert.addButton(withTitle: "Завершить"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try ProcessControl.terminate(identity); refresh() } catch { status.stringValue = error.localizedDescription }
    }
    private func changePriority(increase: Bool) {
        guard let identity = cursor?.identity else { return }
        do { try ProcessControl.changePriority(identity, increase: increase); refresh() }
        catch { status.stringValue = error.localizedDescription }
    }
    private func sort(preserving selected: ProcessIdentity?, selectFirst: Bool = false) {
        let descriptor = table.sortDescriptors.first
        let key = descriptor?.key ?? "name", ascending = descriptor?.ascending ?? true
        entries.sort { a, b in
            let result: ComparisonResult
            switch key {
            case "pid": result = a.pid == b.pid ? .orderedSame : a.pid < b.pid ? .orderedAscending : .orderedDescending
            case "uid": result = a.userID == b.userID ? .orderedSame : a.userID < b.userID ? .orderedAscending : .orderedDescending
            case "rss": result = a.residentBytes == b.residentBytes ? .orderedSame : a.residentBytes < b.residentBytes ? .orderedAscending : .orderedDescending
            case "cpu": result = a.cpuPercent == b.cpuPercent ? .orderedSame : a.cpuPercent < b.cpuPercent ? .orderedAscending : .orderedDescending
            default: result = a.name.localizedStandardCompare(b.name)
            }
            return result == .orderedSame ? a.pid < b.pid : result == (ascending ? .orderedAscending : .orderedDescending)
        }
        table.reloadData()
        if let index = selected.flatMap({ target in entries.firstIndex { $0.identity == target } }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if selectFirst, !entries.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { sort(preserving: cursor?.identity) }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { let view = FileRow(); view.active = active; return view }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard entries.indices.contains(row) else { return nil }; let entry = entries[row]
        switch tableColumn?.identifier.rawValue {
        case "pid": return entry.pid
        case "uid": return entry.userID
        case "cpu": return String(format: "%.1f", entry.cpuPercent)
        case "rss": return ByteCountFormatter.string(fromByteCount: entry.residentBytes, countStyle: .memory)
        default: return entry.name
        }
    }
}

