import AppKit
import FarCore

@MainActor
final class SavedConnectionsPanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?
    var onSwitchPanel: (() -> Void)?
    var onChange: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onConnect: ((NetworkConnection) -> Void)?
    var onConnectEdited: ((NetworkConnection, String?) -> Void)?
    var canConnect: () -> Bool = { true }
    var exportDirectory: (() -> URL?)?
    var caption: String { label("Сохранённые подключения", "Stored sessions") + " [/" + group.joined(separator: "/") + "]" }

    private enum Row: Hashable {
        case parent, group(String), profile(UUID), hint
    }

    private let storeURL: URL
    private let table = FileTable()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var group: [String] = []
    private var pendingGroup: String?
    private var rows: [Row] = []
    private var profiles: [NetworkConnection] = []
    private var marks = Set<Row>()
    private var active = false
    private var editor: NetworkConnectionWindow?
    private var cursor: Row? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil }

    init(storeURL: URL = NetworkProfileStore.defaultURL) {
        self.storeURL = storeURL
        super.init(frame: .zero)
        table.backgroundColor = Palette.panel
        table.rowHeight = 29
        table.intercellSpacing = .zero
        table.allowsEmptySelection = false
        table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.setAccessibilityLabel(label("Сохранённые подключения", "Stored sessions"))
        let column = NSTableColumn(identifier: .init("session"))
        column.title = label("Имя сессии", "Session name")
        column.width = 280
        table.addTableColumn(column)
        table.onFocus = { [weak self] in self?.onFocus?() }
        table.onKey = { [weak self] in self?.handleKey($0) ?? false }
        table.onSelectAll = { [weak self] in
            guard let self else { return }
            self.marks = Set(self.rows.filter(self.canMark))
            self.redraw()
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        status.font = .systemFont(ofSize: 11)
        let body = vertical([scroll, inset(status, x: 10, y: 7)])
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() {
        if window?.firstResponder !== table { refresh() }
        window?.makeFirstResponder(table)
    }

    func setActive(_ value: Bool) {
        active = value
        table.enumerateAvailableRowViews { view, _ in
            (view as? FileRow)?.active = value
            view.needsDisplay = true
        }
    }

    func refresh() {
        do {
            profiles = try NetworkProfileStore.load(from: storeURL)
            redraw()
        } catch {
            profiles = []
            redraw()
            status.stringValue = error.localizedDescription
        }
    }

    @discardableResult
    func perform(function: Int, shifted: Bool = false) -> Bool {
        if shifted {
            switch function {
            case 4: edit(nil)
            case 5: changeName(duplicate: true)
            case 6: changeName(duplicate: false)
            default: return false
            }
        } else {
            switch function {
            case 4:
                if case .profile(let id) = cursor, let profile = profiles.first(where: { $0.id == id }) {
                    edit(profile)
                } else if profiles.isEmpty { edit(nil) }
            case 5: exportSelection()
            case 6: break
            case 7: createGroup()
            case 8: deleteSelection()
            default: return false
            }
        }
        return true
    }

    /// Called when the opposite file panel copies local exports to this panel.
    func importProfiles(from urls: [URL]) {
        do {
            var imported: [NetworkConnection] = []
            for url in urls where url.pathExtension.caseInsensitiveCompare("netbox") == .orderedSame {
                imported += try NetBoxSessionFile.read(from: url)
                guard imported.count <= 100 else {
                    throw NetworkError.limitExceeded(label("Не более 100 подключений за один импорт.", "Import at most 100 sessions at a time."))
                }
            }
            guard !imported.isEmpty else {
                throw NetworkError.invalidConnection(label("Выберите файлы сессий .netbox.", "Select .netbox session files."))
            }
            let names = imported.map(SavedNetworkProfiles.path(for:))
            guard Set(names.map { $0.lowercased() }).count == imported.count else {
                throw NetworkError.conflict(label("В импортируемых файлах повторяется имя сессии.", "The imported files contain duplicate session names."))
            }
            let existing = try NetworkProfileStore.load(from: storeURL)
            let replaced = existing.filter { old in imported.contains { SavedNetworkProfiles.sameName(old, $0) } }
            let preview = names.prefix(5).joined(separator: "\n") + (names.count > 5 ? "\n…" : "")
            let replacement = replaced.isEmpty ? "" : "\n" + label("Сессии с совпадающими именами будут заменены.", "Sessions with matching names will be replaced.")
            guard confirm(label("Импортировать сессии NetBox?", "Import NetBox sessions?"), detail: preview + replacement) else { return }
            guard try NetworkProfileStore.load(from: storeURL) == existing else { throw NetworkError.changedSource }
            let replacedIDs = Set(replaced.map(\.id))
            try NetworkProfileStore.save(existing.filter { !replacedIDs.contains($0.id) } + imported, to: storeURL)
            if let last = imported.last {
                navigate(to: last.profileGroup, selecting: .profile(last.id))
            }
            clearCredentials(for: replaced)
        } catch { report(error) }
    }

    private func label(_ ru: String, _ en: String) -> String { L10n.language == .english ? en : ru }

    private func canMark(_ row: Row) -> Bool { row != .parent && row != .hint }

    private func redraw(selecting preferred: Row? = nil) {
        let previous = preferred ?? cursor
        let localProfiles = profiles.filter { $0.profileGroup.count == group.count && SavedNetworkProfiles.matches($0.profileGroup, prefix: group) }
        var groups: [String] = []
        let children = profiles.compactMap { profile in
            SavedNetworkProfiles.matches(profile.profileGroup, prefix: group) && profile.profileGroup.count > group.count
                ? profile.profileGroup[group.count] : nil
        }
        for child in children + (pendingGroup.map { [$0] } ?? []) {
            if !groups.contains(where: { $0.caseInsensitiveCompare(child) == .orderedSame }) { groups.append(child) }
        }
        rows = [.parent]
        rows += groups.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(Row.group)
        rows += localProfiles.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }.map { .profile($0.id) }
        if rows.count == 1 { rows.append(.hint) }
        marks.formIntersection(rows)
        table.reloadData()
        select(previous.flatMap { rows.firstIndex(of: $0) } ?? 1)
        status.stringValue = label(
            "F4 Правка · Shift+F4 Новая · F5 Экспорт · F7 Группа · F8 Удалить",
            "F4 Edit · Shift+F4 New · F5 Export · F7 Group · F8 Delete")
        onChange?()
    }

    private func select(_ row: Int) {
        let index = max(0, min(row, rows.count - 1))
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    private func navigate(to next: [String], selecting preferred: Row? = nil) {
        if group != next {
            group = next
            pendingGroup = nil
            marks.removeAll()
        }
        refresh()
        if let preferred, let index = rows.firstIndex(of: preferred) { select(index) }
    }

    private func parent() {
        guard let previous = group.last else { onClose?(); return }
        navigate(to: Array(group.dropLast()), selecting: .group(previous))
    }

    @objc private func openSelection() {
        switch cursor {
        case .parent: parent()
        case .group(let name): navigate(to: group + [name], selecting: .hint)
        case .profile(let id):
            do {
                guard let profile = try NetworkProfileStore.load(from: storeURL).first(where: { $0.id == id }) else {
                    refresh()
                    throw NetworkError.changedSource
                }
                onConnect?(profile)
            } catch { report(error) }
        default: break
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .control && event.keyCode == 15 { refresh(); return true }
        if flags == .control && event.keyCode == 121 { parent(); return true }
        guard flags.isEmpty || flags == .shift else { return false }
        if let function = [118: 4, 96: 5, 97: 6, 98: 7, 100: 8][Int(event.keyCode)] {
            return perform(function: function, shifted: flags == .shift)
        }
        switch event.keyCode {
        case 48: onSwitchPanel?()
        case 53: onClose?()
        case 51: parent()
        case 117: deleteSelection()
        case 36, 76: openSelection()
        case 49, 114:
            if let cursor, canMark(cursor) {
                if marks.remove(cursor) == nil { marks.insert(cursor) }
                redraw()
                if event.keyCode == 114 { select(table.selectedRow + 1) }
            }
        case 125, 126:
            if flags == .shift, let cursor, canMark(cursor) { marks.insert(cursor); redraw() }
            select(table.selectedRow + (event.keyCode == 125 ? 1 : -1))
        case 115: select(0)
        case 119: select(rows.count - 1)
        default: return false
        }
        return true
    }

    private func edit(_ profile: NetworkConnection?) {
        if editor?.window?.isVisible == true { editor?.window?.makeKeyAndOrderFront(nil); return }
        let path = profile.map(SavedNetworkProfiles.path(for:)) ?? (group.isEmpty ? "" : group.joined(separator: "/") + "/")
        let controller = NetworkConnectionWindow(connection: profile, sessionPath: path)
        controller.canConnect = { [weak self] in self?.canConnect() ?? false }
        controller.onSaveSession = { [weak self] edited, password, savePassword in
            guard let self else { throw NetworkError.cancelled }
            try self.save(edited, replacing: profile, password: password, savePassword: savePassword)
        }
        controller.onConnect = { [weak self] edited, password, _, _ in self?.onConnectEdited?(edited, password) }
        editor = controller
        controller.showWindow(nil)
    }

    private func save(_ edited: NetworkConnection, replacing original: NetworkConnection?, password: String?, savePassword: Bool) throws {
        let previous = try NetworkProfileStore.load(from: storeURL)
        var current = previous
        guard current.first(where: { $0.id == edited.id }) == original else { throw NetworkError.changedSource }
        try SavedNetworkProfiles.upsert(edited, in: &current)
        let changesCredentialScope = original.map { old in
            old.kind != edited.kind || old.host != edited.host || old.port != edited.port || old.username != edited.username ||
            old.privateKeyPath != edited.privateKeyPath || old.sftpAuthenticationMode != edited.sftpAuthenticationMode ||
            old.sftpJumpHosts != edited.sftpJumpHosts
        } ?? false
        // Clear the old credential before publishing metadata for a different endpoint or route.
        if changesCredentialScope { try NetworkCredentials.remove(for: edited.id) }
        try NetworkProfileStore.save(current, to: storeURL)
        do {
            if savePassword, let password, !password.isEmpty {
                try NetworkCredentials.save(password: password, for: edited.id)
            } else if original != nil, !changesCredentialScope {
                try NetworkCredentials.remove(for: edited.id)
            }
        } catch {
            let credentialError = error
            do { try NetworkProfileStore.save(previous, to: storeURL) }
            catch {
                throw NetworkError.io(credentialError.localizedDescription + "\n" + error.localizedDescription)
            }
            throw credentialError
        }
        navigate(to: edited.profileGroup, selecting: .profile(edited.id))
    }

    private func changeName(duplicate: Bool) {
        guard case .profile(let id) = cursor, let original = profiles.first(where: { $0.id == id }) else { return }
        let oldPath = SavedNetworkProfiles.path(for: original)
        guard let path = input(duplicate ? label("Копирование сессии", "Duplicate session") : label("Переименование сессии", "Rename session"), value: oldPath),
              !path.isEmpty, path != oldPath else { return }
        do {
            var updated = try SavedNetworkProfiles.assigningPath(path, to: original)
            var current = try NetworkProfileStore.load(from: storeURL)
            guard current.first(where: { $0.id == original.id }) == original else { throw NetworkError.changedSource }
            let makeCopy = duplicate && !SavedNetworkProfiles.sameName(updated, original)
            if makeCopy { updated.id = UUID() }
            try SavedNetworkProfiles.upsert(updated, in: &current)
            let password = makeCopy ? try NetworkCredentials.password(for: original.id) : nil
            if let password { try NetworkCredentials.save(password: password, for: updated.id) }
            do { try NetworkProfileStore.save(current, to: storeURL) }
            catch {
                if password != nil { try? NetworkCredentials.remove(for: updated.id) }
                throw error
            }
            navigate(to: updated.profileGroup, selecting: .profile(updated.id))
        } catch { report(error) }
    }

    private func createGroup() {
        guard let name = input(label("Создание группы", "Create session folder"), value: ""), !name.isEmpty else { return }
        do {
            try SavedNetworkProfiles.validateGroup(group + [name])
            if profiles.contains(where: { SavedNetworkProfiles.matches($0.profileGroup, prefix: group + [name]) }) {
                throw NetworkError.conflict(name)
            }
            pendingGroup = name
            redraw(selecting: .group(name))
        } catch { report(error) }
    }

    private var selectedRows: Set<Row> { marks.isEmpty ? Set(cursor.map { [$0] } ?? []) : marks }

    private func selectedProfiles(in list: [NetworkConnection], selected: Set<Row>) -> [NetworkConnection] {
        let groups = selected.compactMap { row -> [String]? in
            if case .group(let name) = row { return group + [name] }
            return nil
        }
        return list.filter { profile in
            selected.contains(.profile(profile.id)) || groups.contains { SavedNetworkProfiles.matches(profile.profileGroup, prefix: $0) }
        }
    }

    private func deleteSelection() {
        let selected = selectedRows
        guard selected.contains(where: canMark) else { return }
        do {
            let current = try NetworkProfileStore.load(from: storeURL)
            let targets = selectedProfiles(in: current, selected: selected)
            guard confirm(label("Удалить выбранные сессии?", "Delete selected sessions?"),
                          detail: label("Подключений: ", "Sessions: ") + String(targets.count)) else { return }
            guard try NetworkProfileStore.load(from: storeURL) == current else { throw NetworkError.changedSource }
            if !targets.isEmpty {
                let ids = Set(targets.map(\.id))
                try NetworkProfileStore.save(current.filter { !ids.contains($0.id) }, to: storeURL)
            }
            if let pendingGroup, selected.contains(.group(pendingGroup)) { self.pendingGroup = nil }
            marks.removeAll()
            refresh()
            clearCredentials(for: targets)
        } catch { report(error) }
    }

    private func clearCredentials(for profiles: [NetworkConnection]) {
        for profile in profiles {
            do { try NetworkCredentials.remove(for: profile.id) }
            catch { report(error) }
        }
    }

    private func exportSelection() {
        do {
            let current = try NetworkProfileStore.load(from: storeURL)
            let profiles = selectedProfiles(in: current, selected: selectedRows)
            guard !profiles.isEmpty else { return }
            let exports = try profiles.map { (NetBoxSessionFile.fileName(for: $0), try NetBoxSessionFile.encode($0)) }
            guard Set(exports.map { $0.0.lowercased() }).count == exports.count else {
                throw NetworkError.conflict(label("Имена экспортируемых файлов совпадают.", "The exported file names collide."))
            }
            let chooser = NSOpenPanel()
            chooser.title = label("Экспорт сессий NetBox", "Export NetBox sessions")
            chooser.canChooseDirectories = true
            chooser.canChooseFiles = false
            chooser.canCreateDirectories = true
            chooser.directoryURL = exportDirectory?()
            guard chooser.runModal() == .OK, let directory = chooser.url else { return }
            for (name, data) in exports {
                let url = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path),
                   !confirm(label("Заменить файл сессии?", "Replace session file?"), detail: name) { continue }
                try data.write(to: url, options: .atomic)
            }
            marks.removeAll()
            refresh()
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        status.stringValue = error.localizedDescription
        onError?(error)
    }

    private func confirm(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: label("Да", "Yes"))
        alert.addButton(withTitle: label("Отмена", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func input(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 390, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: label("ОК", "OK"))
        alert.addButton(withTitle: label("Отмена", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRow()
        view.active = active
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let text: String
        switch item {
        case .parent: text = "↰  .."
        case .group(let name): text = "▸ " + name
        case .profile(let id): text = profiles.first(where: { $0.id == id })?.displayName ?? ""
        case .hint: text = label("Shift+F4 — создать сессию", "Shift+F4 — create a session")
        }
        let cell = NSTextField(labelWithString: (marks.contains(item) ? "✓ " : "  ") + text)
        cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.lineBreakMode = .byTruncatingMiddle
        cell.textColor = Palette.text
        return cell
    }
}
