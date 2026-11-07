import AppKit
import FarCore

@MainActor
final class FarLuaPluginPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var owner: PanelView?
    let plugin: FarLuaPlugins.Plugin
    private let object: FarLuaValue
    private let handle: FarLuaValue
    private let table = FileTable()
    private var entries: [[String: FarLuaValue]] = []
    private var info: [String: FarLuaValue] = [:]
    private var marks: IndexSet = []
    private var job: Task<Void, Never>?
    private var inputJob: Task<Void, Never>?
    private var commitJob: Task<Void, Error>?
    private var closeJob: Task<Void, Never>?
    private var externalJob: Task<Bool, Error>?
    private var listingGeneration = 0
    private var detached = false
    private var editLeases = 0
    private var closing = false
    private var closed = false
    private var active = false
    private var isBusy: Bool { job != nil || inputJob != nil || commitJob != nil || externalJob != nil }

    var caption: String { info["PanelTitle"]?.hostString ?? info["CurDir"]?.hostString ?? plugin.title }
    private var pair: [FarLuaValue] { [object, handle] }
    private var openFlags: Int64 { FarLuaPlugins.flags(info["Flags"]) }

    func ownsHandle(_ handle: FarLuaValue) -> Bool { self.handle == handle && !closed }

    var luaPanelProperties: FarLuaValue {
        let cursor = table.selectedRow
        let current = entries.indices.contains(cursor) ? entries[cursor] : [:]
        let path = info["CurDir"] ?? .string("")
        return .table([
            "Path": path, "Path0": path, "UNCPath": path, "Current": current["FileName"] ?? .string(""),
            "CurPos": .hostInteger(cursor + 1), "ItemCount": .hostInteger(entries.count),
            "SelCount": .hostInteger(marks.count), "Selected": .bool(!marks.isEmpty), "Plugin": .bool(true),
            "FilePanel": .bool(true), "Folder": .bool(isDirectory(current)), "Empty": .bool(entries.isEmpty),
            "Bof": .bool(cursor <= 0), "Eof": .bool(cursor + 1 >= entries.count), "Root": .bool(path.string == "/"),
            "Visible": .bool(!isHidden), "Left": .bool(owner?.locationKey == "left"), "LFN": .bool(true),
            "Filter": .bool(false), "Type": .integer(0), "Width": .hostInteger(Int(bounds.width / 8)),
            "Height": .hostInteger(Int(bounds.height / 16)), "ColumnCount": .hostInteger(table.tableColumns.count),
            "HostFile": info["HostFile"] ?? .string(""), "Prefix": .string(plugin.prefixes.first ?? ""),
            "Format": info["Format"] ?? .string(plugin.title), "OPIFlags": .integer(openFlags)
        ])
    }

    init(owner: PanelView, plugin: FarLuaPlugins.Plugin, object: FarLuaValue, handle: FarLuaValue) {
        self.owner = owner
        self.plugin = plugin
        self.object = object
        self.handle = handle
        super.init(frame: .zero)

        table.backgroundColor = Palette.panel
        table.rowHeight = 23
        table.focusRingType = .none
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(activateSelection)
        table.setAccessibilityLabel(plugin.title)
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Имя"
        name.width = 220
        name.minWidth = 90
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Размер"
        size.width = 90
        table.addTableColumn(name)
        table.addTableColumn(size)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        table.onKey = { [weak self] in self?.keyDownInPanel($0) ?? false }
        table.onFocus = { [weak self] in
            guard let self, let owner = self.owner, !self.active else { return }
            FarLuaPlugins.shared.activate(owner)
        }
        table.onSelectAll = { [weak self] in
            guard let self else { return }
            self.marks = IndexSet(self.entries.indices.filter { self.entries[$0]["FileName"]?.hostString != ".." })
            self.table.reloadData()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focus() { window?.makeFirstResponder(table) }

    func setActive(_ active: Bool) {
        self.active = active
        table.needsDisplay = true
    }

    func reload() async throws {
        guard !closing else { return }
        var nextInfo = info
        if plugin.runtime.hasExport("GetOpenPanelInfo") {
            nextInfo = try await plugin.invoke("GetOpenPanelInfo", pair).lua(0).hostTable
        }
        let result = try await plugin.invoke("GetFindData", pair + [.integer(0)]).lua(0)
        guard let rows = result.array ?? (result.table?.isEmpty == true ? [] : nil) else {
            throw ExtensionAPIError("\(plugin.title): GetFindData не вернул список файлов.")
        }
        var nextRows: [[String: FarLuaValue]] = []
        for row in rows {
            let item = row.hostTable
            guard let name = item["FileName"]?.hostString, !name.isEmpty, !name.contains("\0") else {
                if let value = item["UserData"] { plugin.runtime.releaseReference(value) }
                continue
            }
            nextRows.append(item)
        }
        guard !closing else { releaseRows(nextRows); return }
        if FarLuaPlugins.flags(nextInfo["Flags"]) & 0x8 != 0,
           !nextRows.contains(where: { $0["FileName"]?.hostString == ".." }) {
            nextRows.insert(["FileName": .string(".."), "FileAttributes": .string("d"), "FileSize": .integer(0)], at: 0)
        }
        let cursor = item(at: table.selectedRow).hostTable["FileName"]?.hostString
        let markedNames = Set(marks.compactMap { item(at: $0).hostTable["FileName"]?.hostString })
        releaseRows(entries)
        info = nextInfo
        entries = nextRows
        listingGeneration += 1
        marks = IndexSet(entries.indices.filter {
            guard let name = entries[$0]["FileName"]?.hostString, name != ".." else { return false }
            return markedNames.contains(name) || (entries[$0]["Flags"]?.hostInt ?? 0) & 0x40000000 != 0
        })
        table.reloadData()
        if let cursor, let row = entries.firstIndex(where: { $0["FileName"]?.hostString == cursor }) { moveCursor(row) }
        else if !entries.isEmpty { moveCursor(0) }
        if owner?.resourceView === self { owner?.updateResourceCaption(caption) }
    }

    func refresh() { run { try await self.reload() } }

    func parent() {
        if let row = entries.firstIndex(where: { $0["FileName"]?.hostString == ".." }) {
            changeDirectory("..", userData: entries[row]["UserData"] ?? .nilValue)
        } else {
            owner?.leaveResource()
        }
    }

    func cancelPending() {
        job?.cancel()
        inputJob?.cancel()
        commitJob?.cancel()
        externalJob?.cancel()
    }

    func stop() {
        detached = true
        guard !closing, editLeases == 0 else { return }
        _ = beginClosing()
    }

    private func releaseEditLease() {
        editLeases -= 1
        if detached && editLeases == 0 { stop() }
    }

    func finish() async {
        guard !closed else { return }
        await beginClosing().value
    }

    private func beginClosing() -> Task<Void, Never> {
        if let closeJob { return closeJob }
        closing = true
        cancelPending()
        let task = Task { @MainActor in
            if let job = self.job { await job.value }
            if let inputJob = self.inputJob { await inputJob.value }
            if let commitJob = self.commitJob { _ = await commitJob.result }
            if let externalJob = self.externalJob { _ = await externalJob.result }
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            while self.plugin.runtime.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if !self.closed {
                if self.plugin.runtime.hasExport("ClosePanel") {
                    do { _ = try await self.plugin.invoke("ClosePanel", self.pair) }
                    catch { FarLuaWorkspace.shared.report(error) }
                }
                self.closed = true
                self.releasePanel()
            }
            self.closeJob = nil
        }
        closeJob = task
        return task
    }

    func closeNow() {
        guard !closed else { return }
        closing = true
        closed = true
        cancelPending()
        if plugin.runtime.hasExport("ClosePanel"), !plugin.runtime.isRunning {
            _ = try? plugin.runtime.startExport("ClosePanel", arguments: pair, snapshot: FarLuaWorkspace.shared.snapshot())
            if plugin.runtime.isRunning { plugin.runtime.cancel() }
        }
        releasePanel()
    }

    func perform(function: Int, shifted: Bool) -> Bool {
        guard !closing, !isBusy else { return true }
        if (3...8).contains(function), !FarLuaPlugins.shared.canChangePanelResource { return true }
        switch function {
        case 3: openSelection(editable: false); return true
        case 4 where !shifted: openSelection(editable: true); return true
        case 5, 6: getFiles(move: function == 6, cursorOnly: shifted); return true
        case 7: makeDirectory(); return true
        case 8: deleteSelection(cursorOnly: shifted); return true
        default: return false
        }
    }

    @discardableResult
    func putFiles(from source: PanelView, move: Bool, cursorOnly: Bool = false) -> Bool {
        guard !closing, !isBusy, FarLuaPlugins.shared.canChangePanelResource else { return true }
        let files = cursorOnly ? source.cursorEntry.map { [$0] } ?? [] : source.selectedEntries
        guard !files.isEmpty, !source.isResource, !source.isRemote, !source.isArchive, !source.isVirtual else { return true }
        let directory = source.directory
        let generation = source.locationGeneration
        let listing = listingGeneration
        let captured: [FileToolItem]
        do { captured = try FileTools.snapshot(files.map(\.url)) }
        catch { FarLuaWorkspace.shared.report(error); return true }
        let operation = move ? "Переместить" : "Скопировать"
        guard confirm(operation + " на панель «\(plugin.title)»?", detail: "\(files.count) · \(directory.path)") else { return true }
        let items = files.map { entry in
            FarLuaValue.table([
                "FileName": .string(entry.name), "FileSize": .integer(entry.size), "Owner": .string(entry.owner),
                "Flags": .integer(0x40000000),
                "FileAttributes": .string((entry.isDirectory ? "d" : "") + (entry.isSymbolicLink ? "l" : ""))
            ])
        }
        run {
            guard FarLuaPlugins.shared.canChangePanelResource, self.listingGeneration == listing,
                  source.locationGeneration == generation, source.directory == directory else {
                throw ExtensionAPIError("Панель источника или назначения изменилась.")
            }
            try captured.forEach(FileTools.verify)
            let result = try await self.plugin.invoke("PutFiles", self.pair + [
                .array(items), .bool(move), .string(directory.path), .integer(0)
            ])
            try self.requireSuccess(result, callback: "PutFiles")
            if source.locationGeneration == generation { source.refresh() }
            try await self.reload()
        }
        return true
    }

    func panelCall(_ name: String, _ args: [FarLuaValue]) throws -> [FarLuaValue] {
        switch name {
        case "panel.GetPanelInfo":
            var flags = 0x800 | 0x1000
            if active { flags |= 0x2000 }
            if owner?.locationKey == "left" { flags |= 0x80 }
            if openFlags & 0x20 != 0 { flags |= 0x20 }
            let top = table.rows(in: table.visibleRect).location
            var values: [String: FarLuaValue] = [
                "PanelType": .integer(0), "ItemsNumber": .hostInteger(entries.count),
                "SelectedItemsNumber": .hostInteger(selectionIndices().count), "CurrentItem": .hostInteger(table.selectedRow + 1),
                "TopPanelItem": .hostInteger(top == NSNotFound ? 1 : top + 1), "Flags": .hostInteger(flags),
                "ViewMode": info["StartPanelMode"] ?? .integer(1), "SortMode": info["StartSortMode"] ?? .integer(0),
                "OwnerGuid": .string(plugin.guid.uuidString)
            ]
            if FarLuaHostContext.runtime === plugin.runtime {
                values["PluginHandle"] = handle
                values["PluginObject"] = object
            }
            return [.table(values)]
        case "panel.GetPanelDirectory":
            return [.table(["Name": info["CurDir"] ?? .string(""), "File": info["HostFile"] ?? .string(""),
                            "Param": info["ShortcutData"] ?? .string(""), "PluginId": .string(plugin.guid.uuidString)])]
        case "panel.GetCurrentPanelItem": return [item(at: table.selectedRow, includeUserData: FarLuaHostContext.runtime === plugin.runtime)]
        case "panel.GetPanelItem":
            let ordinal = args.lua(2).hostInt ?? 1
            guard ordinal > 0 else { return [.nilValue] }
            return [item(at: ordinal - 1, includeUserData: FarLuaHostContext.runtime === plugin.runtime)]
        case "panel.GetSelectedPanelItem":
            let ordinal = args.lua(2).hostInt ?? 1
            guard ordinal > 0 else { return [.nilValue] }
            let selected = selectionIndices(), row = ordinal - 1
            return [selected.indices.contains(row) ? item(at: selected[row], includeUserData: FarLuaHostContext.runtime === plugin.runtime) : .nilValue]
        case "panel.RedrawPanel":
            let options = args.lua(2).hostTable
            if let row = options["CurrentItem"]?.hostInt, row > 0 { moveCursor(row - 1) }
            if let row = options["TopPanelItem"]?.hostInt, row > 0, row <= entries.count { table.scrollRowToVisible(row - 1) }
            table.needsDisplay = true
            return [.bool(true)]
        case "panel.BeginSelection", "panel.EndSelection": return [.bool(true)]
        case "panel.SetSelection", "panel.ClearSelection":
            let indices = args.lua(2).hostInt.map { [$0] } ?? args.lua(2).hostArray.compactMap(\.hostInt)
            let selected = selectionIndices()
            for index in indices where index > 0 {
                if name == "panel.ClearSelection" {
                    if selected.indices.contains(index - 1) { marks.remove(selected[index - 1]) }
                } else if entries.indices.contains(index - 1), entries[index - 1]["FileName"]?.hostString != ".." {
                    if args.lua(3).hostBool { marks.insert(index - 1) }
                    else { marks.remove(index - 1) }
                }
            }
            table.reloadData()
            return [.bool(true)]
        case "panel.GetPanelFormat": return [info["Format"] ?? .string("")]
        case "panel.GetPanelHostFile": return [info["HostFile"] ?? .string("")]
        case "panel.GetPanelPrefix": return [.string(plugin.prefixes.first ?? "")]
        case "panel.GetColumnTypes": return [.string("N,S")]
        case "panel.GetColumnWidths": return [.string(table.tableColumns.map { String(Int($0.width / 8)) }.joined(separator: ","))]
        default: throw ExtensionAPIError("API панели LuaFar пока не перенесён: \(name)")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let item = entries[row]
        let directory = isDirectory(item)
        if tableColumn?.identifier.rawValue == "size" {
            return label(directory ? "<DIR>" : item["FileSize"]?.integer.map(String.init) ?? "0", color: Palette.muted)
        }
        let mark = marks.contains(row) ? "✓ " : "  "
        return label(mark + (item["FileName"]?.hostString ?? ""), color: directory ? Palette.accent : Palette.text)
    }

    @objc private func activateSelection() {
        guard entries.indices.contains(table.selectedRow) else { return }
        let item = entries[table.selectedRow]
        guard let name = item["FileName"]?.hostString else { return }
        if isDirectory(item) { changeDirectory(name, userData: item["UserData"] ?? .nilValue) }
        else { openSelection(editable: false) }
    }

    func navigate(_ path: String) async throws -> Bool {
        guard !path.isEmpty, plugin.runtime.hasExport("SetDirectory"), FarLuaPlugins.shared.canChangePanelResource else { return false }
        return try await runExternal {
            let data = self.entries.first(where: { $0["FileName"]?.hostString == path })?["UserData"] ?? .nilValue
            let result = try await self.plugin.invoke("SetDirectory", self.pair + [.string(path), .integer(1), data])
            if result.lua(0).hostBool {
                self.marks = []
                try await self.reload()
                return true
            }
            return false
        }
    }

    func refreshFromHost() async throws -> Bool {
        try await runExternal { try await self.reload(); return true }
    }

    private func runExternal(_ action: @escaping @MainActor () async throws -> Bool) async throws -> Bool {
        guard !closing, !isBusy, !plugin.runtime.isRunning else { return false }
        let task = Task { try await action() }
        externalJob = task
        defer { externalJob = nil }
        return try await task.value
    }

    private func changeDirectory(_ path: String, userData: FarLuaValue) {
        guard plugin.runtime.hasExport("SetDirectory") else {
            if path == ".." { owner?.leaveResource() }
            return
        }
        run {
            let result = try await self.plugin.invoke("SetDirectory", self.pair + [.string(path), .integer(0), userData])
            if result.lua(0).hostBool { self.marks = []; try await self.reload() }
            else if path == ".." { self.owner?.leaveResource() }
            else { NSSound.beep() }
        }
    }

    private func getFiles(move: Bool, cursorOnly: Bool) {
        guard let owner, let destination = FarLuaPlugins.shared.otherPanel(owner),
              !destination.isResource, !destination.isArchive, !destination.isRemote, !destination.isVirtual else {
            FarLuaWorkspace.shared.report(ExtensionAPIError("Панель назначения должна содержать локальную папку."))
            return
        }
        let selected = selectionIndices(cursorOnly: cursorOnly).map { item(at: $0) }
        guard !selected.isEmpty else { return }
        let directory = destination.directory
        let generation = destination.locationGeneration
        let listing = listingGeneration
        let operation = move ? "Переместить" : "Скопировать"
        guard confirm(operation + " из панели «\(plugin.title)»?", detail: directory.path) else { return }
        run {
            guard FarLuaPlugins.shared.canChangePanelResource, self.listingGeneration == listing,
                  destination.locationGeneration == generation, destination.directory == directory else {
                throw ExtensionAPIError("Панель источника или назначения изменилась.")
            }
            let result = try await self.plugin.invoke("GetFiles", self.pair + [
                .array(selected), .bool(move), .string(directory.path), .integer(0)
            ])
            try self.requireSuccess(result, callback: "GetFiles")
            if destination.locationGeneration == generation { destination.refresh() }
            try await self.reload()
        }
    }

    private func openSelection(editable: Bool) {
        guard FarLuaPlugins.shared.canChangePanelResource,
              entries.indices.contains(table.selectedRow), !isDirectory(entries[table.selectedRow]),
              let name = entries[table.selectedRow]["FileName"]?.hostString,
              (name as NSString).lastPathComponent == name, name != ".", name != ".." else { return }
        guard !editable || plugin.runtime.hasExport("PutFiles") else {
            FarLuaWorkspace.shared.report(ExtensionAPIError("Плагин не поддерживает PutFiles для записи изменений."))
            return
        }
        let value = item(at: table.selectedRow)
        let path = info["CurDir"]?.hostString ?? ""
        run {
            let (workspace, file) = try await self.downloadWorkFile(name: name, item: value, mode: editable ? 9 : 5)
            guard !self.closing else { return }
            if editable {
                let bytes = try FarLuaPluginEditSession.read(file)
                self.editLeases += 1
                do {
                    try FarLuaPlugins.shared.openEditor(file, workspace: workspace, original: bytes,
                                                         title: self.caption, pluginID: self.plugin.guid, commit: {
                        [self] expected, replacement, originalName, publishedName in
                        try await self.commitWorkingCopy(name: originalName, publishedName: publishedName, path: path,
                                                         expected: expected, replacement: replacement)
                    }, onClosed: { [self] in self.releaseEditLease() })
                } catch {
                    self.releaseEditLease()
                    throw error
                }
            } else if !FarLuaPlugins.shared.openViewer(file, workspace: workspace) {
                throw ExtensionAPIError("Не удалось открыть рабочую копию «\(name)».")
            }
        }
    }

    private func downloadWorkFile(name: String, item: FarLuaValue, mode: Int64) async throws -> (RemoteWorkspace, URL) {
        let workspace = try RemoteWorkspace()
        let result = try await plugin.invoke("GetFiles", pair + [
            .array([item]), .bool(false), .string(workspace.directory.path), .integer(mode)
        ])
        try requireSuccess(result, callback: "GetFiles")
        let expectedDirectory = workspace.directory.resolvingSymlinksInPath().standardizedFileURL
        if let path = result.lua(1).hostString,
           URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL != expectedDirectory {
            throw ExtensionAPIError("Плагин изменил каталог назначения рабочей копии.")
        }
        let file = workspace.directory.appendingPathComponent(name)
        let type = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard type.isRegularFile == true, type.isSymbolicLink != true else {
            throw ExtensionAPIError("Плагин не создал обычный файл «\(name)».")
        }
        return (workspace, file)
    }

    private func commitWorkingCopy(name: String, publishedName: String, path: String, expected: Data, replacement: Data) async throws {
        guard !publishedName.isEmpty, publishedName != ".", publishedName != "..",
              (publishedName as NSString).lastPathComponent == publishedName else {
            throw ExtensionAPIError("Недопустимое имя файла плагина.")
        }
        guard !closing, !isBusy, !plugin.runtime.isRunning, FarLuaPlugins.shared.canChangePanelResource else {
            throw ExtensionAPIError("Исходная панель плагина закрыта или занята.")
        }
        let task = Task { @MainActor in
            try await self.reload()
            guard !self.closing, (self.info["CurDir"]?.hostString ?? "") == path,
                  let index = self.entries.firstIndex(where: { $0["FileName"]?.hostString == name }),
                  !self.isDirectory(self.entries[index]) else {
                throw ExtensionAPIError("Исходный файл больше не доступен на панели плагина.")
            }
            let current = self.item(at: index)
            let (comparison, currentURL) = try await self.downloadWorkFile(name: name, item: current, mode: 9)
            defer { comparison.cleanup() }
            guard try FarLuaPluginEditSession.read(currentURL) == expected else {
                throw ExtensionAPIError("Файл на панели плагина изменился после открытия рабочей копии.")
            }
            try Task.checkCancellation()
            let staged = try RemoteWorkspace()
            defer { staged.cleanup() }
            try replacement.write(to: staged.directory.appendingPathComponent(publishedName), options: .atomic)
            var fields = current.hostTable
            fields["FileSize"] = .hostInteger(replacement.count)
            fields["FileName"] = .string(publishedName)
            if publishedName != name { fields["UserData"] = nil }
            let result = try await self.plugin.invoke("PutFiles", self.pair + [
                .array([.table(fields)]), .bool(false), .string(staged.directory.path), .integer(8)
            ])
            try self.requireSuccess(result, callback: "PutFiles")
            do { try await self.reload() }
            catch { FarLuaWorkspace.shared.report(error) }
        }
        commitJob = task
        defer { commitJob = nil }
        try await task.value
    }

    private func makeDirectory() {
        run {
            let result = try await self.plugin.invoke("MakeDirectory", self.pair + [.string(""), .integer(0)])
            try self.requireSuccess(result, callback: "MakeDirectory")
            try await self.reload()
            if let name = result.lua(1).hostString,
               let row = self.entries.firstIndex(where: { $0["FileName"]?.hostString == name }) { self.moveCursor(row) }
        }
    }

    private func deleteSelection(cursorOnly: Bool) {
        let selected = selectionIndices(cursorOnly: cursorOnly).map { item(at: $0) }
        let listing = listingGeneration
        guard !selected.isEmpty,
              confirm("Удалить выбранные элементы?", detail: "\(plugin.title) · \(selected.count)") else { return }
        run {
            guard FarLuaPlugins.shared.canChangePanelResource, self.listingGeneration == listing else {
                throw ExtensionAPIError("Панель плагина изменилась.")
            }
            let result = try await self.plugin.invoke("DeleteFiles", self.pair + [.array(selected), .integer(0)])
            guard result.lua(0).hostBool else { throw ExtensionAPIError("Плагин не удалил выбранные элементы.") }
            try await self.reload()
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, !closing else { return }
        job = Task { [weak self] in
            defer { self?.job = nil }
            do { try await action() }
            catch is CancellationError {}
            catch { FarLuaWorkspace.shared.report(error) }
        }
    }

    private func releaseRows(_ rows: [[String: FarLuaValue]]) {
        for row in rows {
            if let value = row["UserData"] { plugin.runtime.releaseReference(value) }
        }
    }

    private func releasePanel() {
        releaseRows(entries)
        entries = []
        plugin.runtime.releaseReference(object)
        plugin.runtime.releaseReference(handle)
        FarLuaPlugins.shared.detach(self)
    }

    private func selectionIndices(cursorOnly: Bool = false) -> [Int] {
        let cursor = table.selectedRow
        if !cursorOnly, !marks.isEmpty { return Array(marks) }
        guard entries.indices.contains(cursor), entries[cursor]["FileName"]?.hostString != ".." else { return [] }
        return [cursor]
    }

    private func item(at row: Int, includeUserData: Bool = true) -> FarLuaValue {
        guard entries.indices.contains(row) else { return .nilValue }
        var result = entries[row]
        if !includeUserData { result.removeValue(forKey: "UserData") }
        var flags = result["Flags"]?.hostInt ?? 0
        if marks.contains(row) { flags |= 0x40000000 } else { flags &= ~0x40000000 }
        result["Flags"] = .hostInteger(flags)
        return .table(result)
    }

    private func isDirectory(_ item: [String: FarLuaValue]) -> Bool {
        if let attributes = item["FileAttributes"]?.hostString { return attributes.lowercased().contains("d") }
        return (item["FileAttributes"]?.hostInt ?? 0) & 0x10 != 0
    }

    private func requireSuccess(_ result: [FarLuaValue], callback: String) throws {
        if result.lua(0).hostInt == -1 { throw CancellationError() }
        guard (result.lua(0).hostInt ?? 0) > 0 else {
            throw ExtensionAPIError("\(plugin.title): \(callback) не завершил операцию.")
        }
    }

    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Выполнить")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func moveCursor(_ row: Int) {
        guard entries.indices.contains(row) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func keyDownInPanel(_ event: NSEvent) -> Bool {
        guard !closing else { return true }
        if isBusy { return true }
        if plugin.runtime.hasExport("ProcessPanelInput") {
            let input = Self.inputRecord(event)
            inputJob = Task { [weak self] in
                guard let self else { return }
                var handled = true
                do {
                    let result = try await self.plugin.invoke("ProcessPanelInput", self.pair + [input])
                    handled = result.lua(0).hostBool
                } catch is CancellationError {}
                catch { FarLuaWorkspace.shared.report(error) }
                self.inputJob = nil
                if !handled, !self.closing { _ = self.defaultKey(event, forwardNavigation: true) }
            }
            return true
        }
        return defaultKey(event, forwardNavigation: false)
    }

    private func defaultKey(_ event: NSEvent, forwardNavigation: Bool) -> Bool {
        if event.modifierFlags.intersection([.control, .option, .command]).isEmpty {
            switch event.keyCode {
            case 36, 76: activateSelection(); return true
            case 51: parent(); return true
            case 49, 114:
                let row = table.selectedRow
                if entries.indices.contains(row), entries[row]["FileName"]?.hostString != ".." {
                    if marks.contains(row) { marks.remove(row) } else { marks.insert(row) }
                    table.reloadData()
                    if event.keyCode == 114 { moveCursor(min(row + 1, entries.count - 1)) }
                }
                return true
            case 125 where forwardNavigation: moveCursor(min(table.selectedRow + 1, entries.count - 1)); return true
            case 126 where forwardNavigation: moveCursor(max(0, table.selectedRow - 1)); return true
            case 115 where forwardNavigation: moveCursor(0); return true
            case 119 where forwardNavigation: moveCursor(entries.count - 1); return true
            default: break
            }
        }
        return false
    }

    private static func inputRecord(_ event: NSEvent) -> FarLuaValue {
        let special: [UInt16: Int] = [36: 0x0D, 76: 0x0D, 48: 0x09, 49: 0x20, 51: 0x08, 53: 0x1B,
            114: 0x2D, 115: 0x24, 116: 0x21, 117: 0x2E, 119: 0x23, 121: 0x22, 123: 0x25, 124: 0x27, 125: 0x28, 126: 0x26]
        let mapped = MacroShortcutAdapter.keyNames[event.keyCode]?.uppercased()
        let key: Int
        if let code = special[event.keyCode] { key = code }
        else if let mapped, mapped.hasPrefix("F"), let number = Int(mapped.dropFirst()), (1...24).contains(number) {
            key = 0x70 + number - 1
        } else { key = mapped?.unicodeScalars.first.map { Int($0.value) } ?? 0 }
        var state = 0
        if event.modifierFlags.contains(.shift) { state |= 0x10 }
        if event.modifierFlags.contains(.control) { state |= 0x8 }
        if event.modifierFlags.contains(.option) { state |= 0x2 }
        return .table([
            "EventType": .integer(1), "KeyDown": .bool(true), "RepeatCount": .integer(1),
            "VirtualKeyCode": .hostInteger(key), "VirtualScanCode": .integer(0),
            "UnicodeChar": .string(String(event.characters?.prefix(1) ?? "")), "ControlKeyState": .hostInteger(state)
        ])
    }
}

extension FarLuaPluginPanelView {
    func runCallbackSmoke(folder: URL) async throws {
        for name in ["panel.GetPanelItem", "panel.GetSelectedPanelItem"] {
            for ordinal in [Int64.min, 0, Int64.max] {
                guard try panelCall(name, [.nilValue, .integer(1), .integer(ordinal)]) == [.nilValue] else {
                    throw ExtensionAPIError("LuaFar panel accepted an out-of-range item index")
                }
            }
        }
        guard entries.count == 3, let data = entries[1]["UserData"],
              case .reference = data, entries[2]["FileName"] == .string("file.txt") else {
            throw ExtensionAPIError("LuaFar smoke: GetFindData rows or UserData missing")
        }
        let changed = try await plugin.invoke("SetDirectory", pair + [.string("folder"), .integer(0), data])
        guard changed == [.bool(true)] else { throw ExtensionAPIError("LuaFar smoke: SetDirectory failed") }
        try await reload()
        guard luaPanelProperties.table?["Path"] == .string("/folder") else {
            throw ExtensionAPIError("LuaFar smoke: refreshed panel path differs")
        }
        let get = try await plugin.invoke("GetFiles", pair + [.array([item(at: 2)]), .bool(false), .string(folder.path), .integer(4)])
        try requireSuccess(get, callback: "GetFiles")
        guard get.lua(1) == .string(folder.path),
              try Data(contentsOf: folder.appendingPathComponent("file.txt")) == Data("first\n".utf8) else {
            throw ExtensionAPIError("LuaFar smoke: GetFiles did not write expected bytes")
        }
        let put = try await plugin.invoke("PutFiles", pair + [
            .array([.table(["FileName": .string("new.txt")])]), .bool(false), .string(folder.path), .integer(0)
        ])
        try requireSuccess(put, callback: "PutFiles")
        guard try Data(contentsOf: folder.appendingPathComponent("backend/new.txt")) == Data("input\n".utf8) else {
            throw ExtensionAPIError("LuaFar smoke: PutFiles did not preserve bytes")
        }
        let created = try await plugin.invoke("MakeDirectory", pair + [.string(""), .integer(0)])
        try requireSuccess(created, callback: "MakeDirectory")
        try await reload()
        guard entries.last?["FileName"] == created.lua(1) else {
            throw ExtensionAPIError("LuaFar smoke: created folder not listed")
        }
        let removed = try await plugin.invoke("DeleteFiles", pair + [.array([item(at: entries.count - 1)]), .integer(0)])
        try await reload()
        let event = try FarLuaKeys.event("ShiftUp", window: window)
        let input = try await plugin.invoke("ProcessPanelInput", pair + [Self.inputRecord(event)])
        guard removed == [.bool(true)], input == [.bool(true)], entries.last?["FileName"] == .string("new.txt") else {
            throw ExtensionAPIError("LuaFar smoke: DeleteFiles or ProcessPanelInput failed")
        }
    }
    func runEditSmoke(backend: URL) async throws {
        let original = backend.appendingPathComponent("file.txt")
        do {
            try await commitWorkingCopy(name: "file.txt", publishedName: "file.txt", path: "/folder",
                                        expected: Data("stale".utf8), replacement: Data("unexpected".utf8))
            throw ExtensionAPIError("LuaFar smoke: expected conflicting source bytes to be rejected")
        } catch let error as ExtensionAPIError where error.localizedDescription.contains("изменился") {
            guard try Data(contentsOf: original) == Data("first\n".utf8) else { throw error }
        }
        guard let row = entries.firstIndex(where: { $0["FileName"]?.hostString == "file.txt" }) else {
            throw ExtensionAPIError("LuaFar smoke: missing editable file")
        }
        moveCursor(row)
        openSelection(editable: true)
        await job?.value
        guard let editor = NSApp.keyWindow?.windowController as? TextFileWindow,
              editor.extensionText == "first\n" else {
            throw ExtensionAPIError("LuaFar smoke: F4 did not open staged editor")
        }
        defer { if editor.window?.isVisible == true { editor.closeArchiveWorkingCopyWithoutSaving() } }
        try editor.applyExtensionText("updated\n", revision: editor.extensionRevision, title: "LuaFar smoke")
        guard editor.saveForArchiveCommit(), try Data(contentsOf: original) == Data("first\n".utf8) else {
            throw ExtensionAPIError("LuaFar smoke: F2 should save only the working copy")
        }
        owner?.leaveResource(focus: false)
        editor.window?.performClose(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while editor.window?.isVisible == true, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        guard editor.window?.isVisible == false, try Data(contentsOf: original) == Data("updated\n".utf8) else {
            throw ExtensionAPIError("LuaFar smoke: editor close did not publish saved bytes")
        }
    }

}
