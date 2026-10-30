import AppKit
import UniformTypeIdentifiers
import FarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var left: PanelView!
    var right: PanelView!
    var active: PanelView!
    var passive: PanelView { active === left ? right : left }
    let status = label("Готово", size: 11, color: Palette.accent)
    private var editors: [TextFileWindow] = []
    private var viewers: [ViewerWindow] = []
    private let network = NetworkCoordinator()
    private let archiveOperations = ArchiveOperationController()
    private var archiveEdits: [ArchiveEditCommitWindow] = []

    private var restoredDrafts: Set<UUID> = []
    private var shellWorkspace: ShellWorkspace!
    private var panelsContainer: NSView!
    private var terminalVisible = false
    private var recordedPanelPaths: [ObjectIdentifier: String] = [:]
    private var folderFunctionButton: NSButton?
    private var archiveFunctionButtons: [Int: NSButton] = [:]
    private var comparisonWindow: DirectoryComparisonWindow?
    private var keyMonitor: Any?
    private var busy = false
    var settingsWindow: PanelSettingsWindow?
    var groupsWindow: MaskGroupsWindow?
    private var searchWindow: SearchWindow?
    private var toolWindows: [NSWindowController] = []
    private var toolMutationPending: Bool {
        network.isWorking || archiveOperations.isWorking || archiveEdits.contains(where: { $0.isWorking }) || toolWindows.contains { ($0 as? FileToolsWindowController)?.hasPendingMutation == true }
    }
    private lazy var operationQueue: FileOperationQueue = {
        let queue = FileOperationQueue()
        queue.canEnqueue = { [weak self] in
            guard let self else { return false }
            return !self.busy && !self.toolMutationPending
        }
        queue.onFinished = { [weak self] result in
            self?.status.stringValue = result.summary
            self?.refresh()
        }
        return queue
    }()
    private lazy var contextHelp = HelpWindow()
    private var dialogHelp = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FarForMac"
        window.subtitle = "Файловый менеджер"
        window.minSize = NSSize(width: 900, height: 480)
        window.backgroundColor = Palette.background
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FarMac.main")
        window.center()

        let brand = label("FarForMac", size: 23, color: Palette.accent, bold: true)
        let branding = horizontal([brand], spacing: 5)
        let spacer = NSView()
        let home = toolbarButton("Домой", symbol: "house", action: "home")
        let volumes = toolbarButton("Диски", symbol: "externaldrive", action: "volumes")
        let terminal = toolbarButton("Терминал", symbol: "terminal", action: "terminal")
        let hidden = toolbarButton("Скрытые", symbol: "eye", action: "hidden")
        let operations = toolbarButton("Операции", symbol: "list.bullet.rectangle", action: "operations")
        let toolbar = inset(horizontal([branding, spacer, home, volumes, terminal, hidden, operations], spacing: 12), x: 18, y: 15)

        let defaults = UserDefaults.standard
        func location(_ key: String) -> URL {
            if let path = defaults.string(forKey: "panel.\(key)"), FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            return FileManager.default.homeDirectoryForCurrentUser
        }
        left = PanelView(directory: location("left"), key: "left")
        right = PanelView(directory: location("right"), key: "right")
        network.canStart = { [weak self] in guard let self else { return false }; return !self.busy && !self.toolMutationPending && !self.operationQueue.hasPendingOperations }
        network.onStatus = { [weak self] text in self?.status.stringValue = text }
        network.onError = { [weak self] error in self?.showError(error) }
        network.onChanged = { [weak self] in self?.refresh() }
        for panel in [left!, right!] {
            panel.onRemoteRefresh = { [weak self] panel in self?.network.refresh(panel) }
            panel.showHidden = defaults.bool(forKey: "showHidden")
            panel.maskGroups = maskGroups
            if let data = defaults.data(forKey: "panel.sortGroups"), let groups = try? SortGroups.decode(data, maskGroups: maskGroups) { panel.sortGroups = groups }
            panel.onFocus = { [weak self] pane in self?.activate(pane) }
            panel.onError = { [weak self] error in self?.showError(error) }
            panel.onArchiveView = { [weak self] panel, path in self?.openArchiveMember(panel, path: path, editable: false) }
            panel.onArchiveRefresh = { [weak self] panel in self?.refreshArchive(panel) }
            panel.onArchiveSwitchPanel = { [weak self] in guard let self else { return }; self.activate(self.passive); self.active.focus() }
            panel.onFileOpen = { [weak self, weak panel] entry in
                guard let self, let panel else { return }
                if ["zip", "tar", "7z", "rar", "tgz", "gz", "bz2", "xz"].contains(entry.url.pathExtension.lowercased()) {
                    self.openArchive(entry.url, in: panel); return
                }
                if !self.shellWorkspace.association(for: entry.url, action: .execute) { NSWorkspace.shared.open(entry.url) }
            }
            panel.onContentModeChange = { [weak self] _ in self?.updateAuxiliaryPanels() }
            panel.onSelectionChange = { [weak self] _ in self?.updateAuxiliaryPanels() }
            panel.onDirectoryChange = { [weak self] panel in
                guard let self, let shell = self.shellWorkspace else { return }
                let key = ObjectIdentifier(panel)
                if self.recordedPanelPaths[key] != panel.directory.path {
                    self.recordedPanelPaths[key] = panel.directory.path
                    shell.recordActivity(.folder, value: panel.directory.path)
                }
                if panel === self.active { shell.updateDirectory() }
                self.updateAuxiliaryPanels()
            }
            panel.onKey = { [weak self] event in self?.panelKey(event) ?? false }
        }
        let panels = horizontal([left, right], spacing: 10)
        panels.distribution = .fillEqually
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        left.heightAnchor.constraint(equalTo: panels.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: panels.heightAnchor).isActive = true
        let panelsWrapper = inset(panels, x: 14, y: 0)
        panelsWrapper.setContentHuggingPriority(.defaultLow, for: .vertical)
        panelsContainer = panelsWrapper
        shellWorkspace = ShellWorkspace(context: { [weak self] in
            guard let self else { return UserCommandContext(currentFile: nil, markedFiles: [], activeDirectory: URL(fileURLWithPath: "/"), passiveDirectory: URL(fileURLWithPath: "/")) }
            return UserCommandContext(currentFile: self.active.cursorEntry?.url, markedFiles: self.active.markedEntries.map(\.url), activeDirectory: self.active.directory, passiveDirectory: self.passive.directory)
        }, navigate: { [weak self] url in self?.active.load(url, preserveSelection: false) }, openFile: { [weak self] url, editable in
            _ = self?.openDocument(url, editable: editable)
        }, showTerminal: { [weak self] in self?.setTerminalVisible(true) }, togglePanels: { [weak self] in self?.toggleTerminal() }, refreshPanels: { [weak self] in self?.refresh() }, report: { [weak self] text in self?.status.stringValue = text })
        shellWorkspace.terminalView.isHidden = true

        let hints = horizontal([status, NSView(), label("Space  пометка    Tab  панель    ⌘L  путь    ⌘F  фильтр", size: 11, color: Palette.muted)])
        let statusBar = inset(hints, x: 18, y: 11)
        let actions = horizontal([], spacing: 5)
        let names = ["Помощь", "Польз. меню", "Просмотр", "Правка", "Копия", "Перенос", "Папка", "Корзина", "Меню", "Выход"]
        for (index, title) in names.enumerated() {
            let button = NSButton(title: "F\(index + 1)  \(title)", target: self, action: #selector(functionButton(_:)))
            button.tag = index + 1
            if [4, 5, 6, 8].contains(button.tag) { archiveFunctionButtons[button.tag] = button }
            if index == 6 { folderFunctionButton = button }
            button.bezelStyle = .recessed
            button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = index == 4 ? Palette.accent : Palette.text
            button.toolTip = "F\(index + 1) — \(title). На Mac может потребоваться Fn."
            actions.addArrangedSubview(button)
        }
        actions.distribution = .fillEqually
        let footer = inset(actions, x: 12, y: 10, color: Palette.raised)
        window.contentView = vertical([toolbar, panelsWrapper, shellWorkspace.terminalView, shellWorkspace.commandBar, statusBar, footer])
        activate(defaults.string(forKey: "session.activePanel") == "right" ? right : left)
        left.load()
        right.load()
        window.makeKeyAndOrderFront(nil)
        active.focus()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.offerEditorRecovery(automatic: true) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow != nil else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if self.window.isKeyWindow, self.terminalVisible, self.shellWorkspace.isRunning,
               !flags.contains(.command) {
                if event.keyCode == 31, flags.intersection([.command, .control, .option, .shift]) == [.control] { self.toggleTerminal(); return nil }
                return event
            }
            if event.keyCode == 122 && flags.intersection([.command, .control, .option, .shift]).isEmpty {
                self.help(); return nil
            }
            if event.keyCode == 118 && flags.intersection([.command, .control, .option, .shift]) == [.shift], NSApp.keyWindow?.attachedSheet == nil {
                self.newEditor(nil); return nil
            }
            guard self.window.isKeyWindow, self.window.attachedSheet == nil else { return event }
            let modifiers = flags.intersection([.command, .control, .option, .shift])
            if !self.terminalVisible, modifiers == [.control], [17, 37, 12].contains(event.keyCode) {
                let mode: PanelContentMode = event.keyCode == 17 ? .tree : (event.keyCode == 37 ? .info : .quickView)
                self.active.setContentMode(self.active.contentMode == mode ? .files : mode)
                self.active.focus(); return nil
            }
            if modifiers == [.control], event.keyCode == 31 { self.toggleTerminal(); return nil }
            if self.terminalVisible, self.shellWorkspace.isRunning { return event }
            if modifiers == [.command], event.keyCode == 36 { self.shellWorkspace.focusCommand(); return nil }
            if modifiers == [.control], event.keyCode == 49 { self.shellWorkspace.completePath(); return nil }
            if modifiers == [.control], event.keyCode == 14 { self.shellWorkspace.previousCommand(backward: true); return nil }
            if modifiers == [.control], event.keyCode == 7 { self.shellWorkspace.previousCommand(backward: false); return nil }
            if modifiers == [.option], event.keyCode == 100 { self.shellWorkspace.showHistory(.command); return nil }
            if modifiers == [.option], event.keyCode == 103 { self.shellWorkspace.showHistory(.view); return nil }
            if modifiers == [.option], event.keyCode == 111 { self.shellWorkspace.showHistory(.folder); return nil }
            if flags.contains(.command) || flags.contains(.control) { return event }
            let codes: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10]
            if let function = codes[event.keyCode] {
                if flags.intersection([.option, .shift]) == [.option] && (function == 1 || function == 2) {
                    self.activate(function == 1 ? self.left : self.right)
                    self.active.focus()
                    self.showPanelMenu(named: "Тома")
                } else if flags.intersection([.option, .shift]) == [.option] && function == 7 {
                    self.openSearch()
                } else if flags.intersection([.option, .shift]) == [.shift] && (function == 5 || function == 6) {
                    if !self.busy { self.transfer(move: function == 6, cursorOnly: true) }
                } else if flags.intersection([.shift, .option]).isEmpty {
                    self.performFunction(function)
                } else {
                    return event
                }
                return nil
            }
            return event
        }
    }

    @objc private func newEditor(_ sender: Any?) {
        guard NSApp.keyWindow?.attachedSheet == nil else { return }
        let editor = TextFileWindow(newIn: active.directory, onView: { [weak self] url, offset, encoding in
            self?.openDocument(url, editable: false, byteOffset: offset, encoding: encoding) ?? false
        })
        editors.removeAll { $0.window?.isVisible == false }
        editors.append(editor); editor.showWindow(nil)
    }

    @objc private func recoverEditors(_ sender: Any?) { offerEditorRecovery(automatic: false) }

    private func offerEditorRecovery(automatic: Bool) {
        do {
            let recovery = try EditorRecoveryStore().loadAvailable()
            let records = recovery.records.filter { !restoredDrafts.contains($0.id) }
            let notice = recovery.warnings.prefix(3).joined(separator: "\n")
            if !notice.isEmpty { status.stringValue = "Некоторые черновики не прочитаны; исходные записи сохранены." }
            guard !records.isEmpty else {
                if !notice.isEmpty {
                    let alert = NSAlert(); alert.messageText = "Не все черновики доступны"; alert.informativeText = notice; alert.runModal()
                } else if !automatic { status.stringValue = "Нет черновиков для восстановления." }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Доступны черновики редактора: \(records.count)"
            alert.informativeText = "Открыть несохранённый текст в редакторе? Исходные файлы останутся без изменений." + (notice.isEmpty ? "" : "\n\n" + notice)
            alert.addButton(withTitle: "Восстановить"); alert.addButton(withTitle: "Позже")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for record in records {
                let editor = try TextFileWindow(recovery: record, onView: { [weak self] url, offset, encoding in
                    self?.openDocument(url, editable: false, byteOffset: offset, encoding: encoding) ?? false
                })
                editors.append(editor); restoredDrafts.insert(record.id); editor.showWindow(nil)
            }
        } catch { showError(error) }
    }

    private func canWriteArchive() -> Bool {
        guard !busy, !toolMutationPending, !operationQueue.hasPendingOperations else {
            status.stringValue = "Дождитесь завершения операций перед изменением архива."
            return false
        }
        return true
    }
    private func archiveFailure(_ error: Error) {
        if let error = error as? ArchiveError, error == .cancelled { status.stringValue = error.localizedDescription }
        else { showError(error) }
    }
    private func openArchive(_ url: URL, in panel: PanelView) {
        guard !busy, !toolMutationPending else { return }
        let originalDirectory = panel.directory
        archiveOperations.open(url) { [weak self, weak panel] result in
            guard let self, let panel else { return }
            switch result {
            case .success(let snapshot):
                guard panel.directory == originalDirectory else { return }
                self.activate(panel); panel.showArchive(snapshot)
                self.status.stringValue = "Архив открыт. Enter — папка/просмотр; F5 — извлечь."
            case .failure(let error): self.archiveFailure(error)
            }
        }
    }
    private func refreshArchive(_ panel: PanelView, completion: @escaping () -> Void = {}) {
        guard !toolMutationPending, !busy, let archive = panel.archivePanel else { completion(); return }
        let url = archive.snapshot.sourceURL
        archiveOperations.open(url) { [weak self, weak panel, weak archive] result in
            defer { completion() }
            guard let self, let panel, panel.archivePanel === archive else { return }
            switch result {
            case .success(let snapshot): panel.showArchive(snapshot)
            case .failure(let error): self.archiveFailure(error)
            }
        }
    }
    private func archiveUpdated(_ snapshot: ArchiveSnapshot) {
        for panel in [left!, right!] {
            if panel.archivePanel?.snapshot.sourceURL.standardizedFileURL == snapshot.sourceURL.standardizedFileURL { panel.showArchive(snapshot) }
            else if !panel.isArchive { panel.load() }
        }
        status.stringValue = "Архив сохранён: " + snapshot.sourceURL.lastPathComponent
    }
    private func openArchiveMember(_ panel: PanelView, path: String, editable: Bool) {
        guard !busy, !toolMutationPending, let browser = panel.archivePanel else { return }
        let snapshot = browser.snapshot
        if browser.cursorPath == path && browser.cursorIsDirectory { return }
        if editable && snapshot.isEncrypted { inform("Архив доступен только для чтения", "Извлечение с паролем поддерживается. Сохранение шифрования при изменении архива пока не поддерживается."); return }
        archiveOperations.extract(snapshot, paths: [path]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.archiveFailure(error)
            case .success(let workspace):
                if editable { _ = self.openArchiveEditor(snapshot: snapshot, path: path, workspace: workspace) }
                else {
                    do {
                        let memberURL = try workspace.url(for: path)
                        let viewer = try ViewerWindow(url: memberURL, onEdit: { [weak self, weak workspace] url, offset, encoding in
                            guard let self else { return false }
                            guard url.standardizedFileURL == memberURL.standardizedFileURL else {
                                return self.openDocument(url, editable: true, byteOffset: offset, encoding: encoding)
                            }
                            guard let workspace else { return false }
                            return self.openArchiveEditor(snapshot: snapshot, path: path, workspace: workspace, byteOffset: offset, encoding: encoding)
                        })
                        viewer.retainedArchiveWorkspace = workspace
                        self.viewers.removeAll { $0.window?.isVisible == false }; self.viewers.append(viewer)
                        viewer.showWindow(nil); viewer.window?.makeKeyAndOrderFront(nil)
                    } catch { self.archiveFailure(error) }
                }
            }
        }
    }
    @discardableResult private func openArchiveEditor(snapshot: ArchiveSnapshot, path: String, workspace: ArchiveWorkspace, byteOffset: Int64? = nil, encoding: ViewerEncoding = .automatic) -> Bool {
        guard !snapshot.isEncrypted else { inform("Зашифрованный архив", "Редактирование зашифрованных архивов пока недоступно."); return false }
        do {
            let editor = try TextFileWindow(url: workspace.url(for: path), initialByteOffset: byteOffset, encoding: encoding)
            editor.retainedArchiveWorkspace = workspace
            let commit = try ArchiveEditCommitWindow(snapshot: snapshot, path: path, workspace: workspace, editor: editor,
                canCommit: { [weak self] in self?.canWriteArchive() ?? false },
                onCommitted: { [weak self] snapshot in self?.archiveUpdated(snapshot) })
            editors.removeAll { $0.window?.isVisible == false }; editors.append(editor)
            archiveEdits.removeAll { $0.window?.isVisible == false }; archiveEdits.append(commit)
            commit.showWindow(nil); editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            editor.window?.subtitle = "Рабочая копия · применить через окно «Сохранить в архив»"
            return true
        } catch { archiveFailure(error); return false }
    }
    private func extractArchiveSelection(cursorOnly: Bool = false) {
        guard !busy, !toolMutationPending, let browser = active.archivePanel else { return }
        guard !passive.isArchive else { inform("Выберите обычную папку назначения", "Копирование между архивами пока не поддерживается."); return }
        let selected = cursorOnly ? browser.cursorPath.map { [$0] } ?? [] : browser.selectedArchivePaths
        let paths = selected.filter { path in !selected.contains(where: { path.hasPrefix($0 + "/") }) }
        guard !paths.isEmpty else { inform("Выберите объекты архива", "Отметьте файлы или установите курсор на объект."); return }
        let snapshot = browser.snapshot, base = active.directory
        prompt("Извлечь из архива", detail: "Объектов: \(paths.count). После безопасной распаковки в рабочую папку копирование будет добавлено в очередь. Конфликты запросят решение; завершённые файлы при отмене сохраняются.", value: passive.directory.path, button: "Извлечь") { [weak self] value in
            guard let self, !self.toolMutationPending, !self.busy else { return }
            let path = (value as NSString).expandingTildeInPath
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let destination = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
            self.archiveOperations.extract(snapshot, paths: paths) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error): self.archiveFailure(error)
                case .success(let workspace):
                    do {
                        let urls = try paths.map { try workspace.url(for: $0) }
                        if self.operationQueue.enqueue(TransferRequest(sources: urls, destination: destination, move: false), retaining: workspace) {
                            self.status.stringValue = "Извлечение передано в очередь."
                        }
                    } catch { self.archiveFailure(error) }
                }
            }
        }
    }
    private func addToArchive(cursorOnly: Bool = false) {
        guard canWriteArchive(), !active.isArchive, let browser = passive.archivePanel else { return }
        let selected = cursorOnly ? active.cursorEntry.map { [$0] } ?? [] : active.selectedEntries
        guard !selected.isEmpty else { inform("Выберите файлы", "Установите курсор или отметьте объекты для добавления."); return }
        let snapshot = browser.snapshot, prefix = browser.currentDirectory
        let captured = active.capturedSearchResults(for: selected)
        do { try captured.forEach { try $0.verifyCurrent() } } catch { archiveFailure(error); return }
        let alert = NSAlert(); alert.messageText = "Добавить файлы в архив?"
        alert.informativeText = "\(snapshot.sourceURL.path) !/\(prefix)\nОбъектов: \(selected.count). Источники останутся на месте."
        alert.addButton(withTitle: "Добавить"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try captured.forEach { try $0.verifyCurrent() } } catch { archiveFailure(error); return }
        archiveOperations.update(snapshot, additions: selected.map(\.url), prefix: prefix) { [weak self] result in
            switch result { case .success(let snapshot): self?.archiveUpdated(snapshot); case .failure(let error): self?.archiveFailure(error) }
        }
    }
    private func deleteArchiveSelection() {
        guard canWriteArchive(), let browser = active.archivePanel else { return }
        let selected = browser.selectedArchivePaths, snapshot = browser.snapshot
        let paths = selected.filter { path in !selected.contains(where: { path.hasPrefix($0 + "/") }) }
        guard !paths.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Удалить из архива?"
        alert.informativeText = "\(snapshot.sourceURL.lastPathComponent)\n" + paths.prefix(8).joined(separator: "\n") + "\nИзменится только архив. Корзина для его элементов не используется."
        alert.addButton(withTitle: "Удалить из архива"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        archiveOperations.update(snapshot, deletions: paths) { [weak self] result in
            switch result { case .success(let snapshot): self?.archiveUpdated(snapshot); case .failure(let error): self?.archiveFailure(error) }
        }
    }
    private func createArchive() {
        guard canWriteArchive(), !active.isArchive, let selected = requireSelection() else { return }
        let captured = active.capturedSearchResults(for: selected)
        let alert = NSAlert(); alert.messageText = "Формат нового архива"
        alert.informativeText = "ZIP или несжатый TAR. Шифрование при создании пока не поддерживается."
        alert.addButton(withTitle: "ZIP"); alert.addButton(withTitle: "TAR"); alert.addButton(withTitle: "Отмена")
        let answer = alert.runModal(); guard answer != .alertThirdButtonReturn else { return }
        let format: ArchiveFormat = answer == .alertFirstButtonReturn ? .zip : .tar
        let save = NSSavePanel(); save.title = "Создать архив"; save.directoryURL = active.directory
        save.nameFieldStringValue = "Archive." + format.rawValue
        if let type = UTType(filenameExtension: format.rawValue) { save.allowedContentTypes = [type] }
        guard save.runModal() == .OK, let destination = save.url else { return }
        do { try captured.forEach { try $0.verifyCurrent() } } catch { archiveFailure(error); return }
        archiveOperations.create(sources: selected.map(\.url), destination: destination, format: format) { [weak self] result in
            switch result { case .success(let snapshot): self?.archiveUpdated(snapshot); case .failure(let error): self?.archiveFailure(error) }
        }
    }

    private func updateFunctionLabels() {
        let remote = active?.isRemote == true
        let archive = active?.isArchive == true
        let readOnly = active?.archivePanel?.snapshot.isEncrypted == true
        let temporary = !archive && !remote && active?.isTemporary == true
        archiveFunctionButtons[4]?.isEnabled = !readOnly
        archiveFunctionButtons[5]?.title = archive ? "F5  Извлечь" : (passive.isArchive == true ? "F5  В архив" : "F5  Копия")
        archiveFunctionButtons[5]?.toolTip = archive ? "Извлечь выбранные элементы в обычную папку через очередь." : (passive.isArchive ? "Добавить выбранные файлы в соседний архив." : "Копировать выбранные файлы.")
        archiveFunctionButtons[6]?.isEnabled = !archive && passive.isArchive != true
        archiveFunctionButtons[8]?.title = (archive || remote) ? "F8  Удалить" : "F8  Корзина"
        archiveFunctionButtons[8]?.toolTip = remote ? "Удаление с сервера без Корзины после подтверждения." : archive ? "Удалить выбранные элементы из архива после подтверждения. Корзина не используется." : "Переместить выбранные файлы в Корзину macOS."
        archiveFunctionButtons[8]?.isEnabled = !readOnly
        folderFunctionButton?.isEnabled = !archive
        folderFunctionButton?.title = temporary ? "F7  Убрать" : "F7  Папка"
        folderFunctionButton?.toolTip = temporary ? "F7 — убрать ссылку из временной панели, сохранив файл." : "F7 — создать папку."
    }
    private func updateAuxiliaryPanels() {
        updateFunctionLabels()
        guard left != nil, right != nil else { return }
        for (panel, other) in [(left!, right!), (right!, left!)] where panel.contentMode != .files {
            panel.updateAuxiliary(directory: other.directory, selected: other.contentMode == .files ? other.cursorEntry : nil)
        }
    }
    private func editFileDescription() {
        guard let item = active.cursorEntry else { return }
        do {
            let controller = try FileDescriptionWindow(directory: item.url.deletingLastPathComponent(), filename: item.name) { [weak self] in self?.refresh() }
            toolWindows.removeAll { $0.window?.isVisible == false }
            toolWindows.append(controller); controller.showWindow(nil)
        } catch { showError(error) }
    }
    private func editSortGroups() {
        let controller = SortGroupsWindow(groups: active.sortGroups, maskGroups: maskGroups) { [weak self] groups in
            guard let self else { return }
            do {
                UserDefaults.standard.set(try groups.jsonData(), forKey: "panel.sortGroups")
                self.left.sortGroups = groups; self.right.sortGroups = groups
            } catch { self.showError(error) }
        }
        toolWindows.removeAll { $0.window?.isVisible == false }
        toolWindows.append(controller); controller.showWindow(nil)
    }
    private func compareDirectories() {
        guard !left.isTemporary, !right.isTemporary, !left.isArchive, !right.isArchive, !left.isRemote, !right.isRemote else {
            inform("Сравнение каталогов", "Вернитесь из временной панели к папкам."); return
        }
        let leftURL = left.directory, rightURL = right.directory
        comparisonWindow = DirectoryComparisonWindow(left: leftURL, right: rightURL) { [weak self] leftURLs, rightURLs in
            guard let self else { return }
            guard self.left.directory == leftURL, self.right.directory == rightURL,
                  !self.left.isTemporary, !self.right.isTemporary, !self.left.loading, !self.right.loading else {
                self.inform("Пути панелей изменились", "Повторите сравнение текущих каталогов."); return
            }
            self.left.setContentMode(.files); self.right.setContentMode(.files)
            self.left.markPaths(leftURLs); self.right.markPaths(rightURLs)
            let marked = self.left.markedEntries.count + self.right.markedEntries.count
            self.status.stringValue = "Отмечено видимых отличий: \(marked) из \(leftURLs.count + rightURLs.count). Скрытые/отфильтрованные не помечены. Файлы не изменялись."
        }
        comparisonWindow?.showWindow(nil)
    }
    private func addToTemporaryPanel() {
        guard !busy else { return }
        let items = active.selectedEntries
        guard !items.isEmpty else { return }
        let snapshots = active.capturedSearchResults(for: items)
        let target = passive, path = target.directory
        busy = true; status.stringValue = "Добавление ссылок во временную панель…"
        Task {
            defer { busy = false }
            do {
                let results = try await Task.detached(priority: .userInitiated) {
                    if !snapshots.isEmpty { for result in snapshots { try result.verifyCurrent() }; return snapshots }
                    return try items.map { try SearchResult.capture($0.url) }
                }.value
                guard target.directory == path else { throw PanelSessionError("Путь соседней панели изменился. Повторите добавление.") }
                try target.addTemporaryItems(results)
                status.stringValue = "Добавлено ссылок: \(results.count). Исходные файлы не перемещались."
            } catch { showError(error) }
        }
    }
    private func locateTemporaryItem() {
        guard active.isTemporary, let item = active.cursorEntry else { return }
        active.setContentMode(.files)
        active.load(item.url.deletingLastPathComponent(), preserveSelection: false, selectName: item.name)
    }

    func activate(_ panel: PanelView) {
        active = panel
        left.active = panel === left
        right.active = panel === right
        shellWorkspace?.updateDirectory()
        UserDefaults.standard.set(panel.locationKey, forKey: "session.activePanel")
        updateFunctionLabels()
    }
    private func setTerminalVisible(_ visible: Bool) {
        terminalVisible = visible; panelsContainer.isHidden = visible
        shellWorkspace.terminalView.isHidden = !visible
        if visible { shellWorkspace.focusTerminal() } else { active.focus() }
    }
    private func toggleTerminal() { setTerminalVisible(!terminalVisible) }
    func panelKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == [.control], event.keyCode == 121, !active.isArchive, let entry = active.cursorEntry, !entry.isDirectory { openArchive(entry.url, in: active); return true }
        if active.isArchive || active.isRemote { return false }
        if modifiers == [.control], event.keyCode == 116, active.isTemporary { locateTemporaryItem(); return true }
        if modifiers == [.control] || modifiers == [.control, .shift] {
            let digitCodes: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            if let number = digitCodes[event.keyCode] { quickFolder(number, save: modifiers.contains(.shift)); return true }
            if event.keyCode == 69 || event.keyCode == 78 {
                if modifiers.contains(.shift) { active.selectSameName(mark: event.keyCode == 69) }
                else { active.selectSameExtension(mark: event.keyCode == 69) }
                return true
            }
        }
        if event.keyCode == 67 && modifiers == [.option] { active.invertFilesAndClearDirectories(); return true }
        if event.keyCode == 67 && (modifiers.isEmpty || modifiers == [.control]) {
            active.invertMarks(includeDirectories: modifiers.contains(.control))
            return true
        }
        if modifiers.isEmpty && (event.keyCode == 69 || event.keyCode == 78) {
            selectionMask(mark: event.keyCode == 69)
            return true
        }
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else { return false }
        switch event.keyCode {
        case 48: activate(passive); active.focus(); return true
        case 36, 76: active.openSelection(); return true
        case 51: active.parent(); return true
        case 53: active.clearFilter(); return true
        default: return false
        }
    }
    func toolbarButton(_ title: String, symbol: String, action: String) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: #selector(command(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(action)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 12)
        return button
    }
    @objc func functionButton(_ sender: NSButton) { performFunction(sender.tag) }
    @objc func functionMenu(_ sender: NSMenuItem) { if sender.tag == 1 { help() } else { performFunction(sender.tag) } }
    private let filePanelCommands: Set<String> = ["mark", "markAll", "clearMarks", "invertMarks", "invertAll", "markMask", "unmarkMask", "restoreMarks", "sameExtension", "unmarkExtension", "sameName", "unmarkName", "invertFiles", "quickFind", "findNext", "findPrevious", "filter", "fileDescription", "rename", "copyCursor", "batchRename", "properties", "symbolicLink", "hardLink", "deletePermanently"]
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(functionMenu(_:)), menuItem.tag == 8 {
            menuItem.title = active?.isRemote == true ? "Удалить с сервера…" : active?.isArchive == true ? "Удалить из архива…" : "В Корзину…"
        }
        if menuItem.action == #selector(functionMenu(_:)), menuItem.tag == 5 {
            menuItem.title = active?.isArchive == true ? "Извлечь из архива…" : (passive.isArchive == true ? "Добавить в архив…" : "Копировать…")
        }
        if menuItem.action == #selector(functionMenu(_:)), menuItem.tag == 7 {
            menuItem.title = active?.isTemporary == true ? "Убрать из временной панели" : "Создать папку…"
        }
        if menuItem.action == #selector(functionMenu(_:)) && menuItem.tag == 1 { return true }
        if menuItem.action == #selector(newEditor(_:)) || menuItem.action == #selector(recoverEditors(_:)) {
            return NSApp.keyWindow?.attachedSheet == nil
        }
        guard window != nil && window.isKeyWindow && window.attachedSheet == nil && !busy else { return false }
        if let id = menuItem.representedObject as? String, (active.isArchive || active.isRemote),
           (filePanelCommands.contains(id) && id != "copyCursor") || ["search", "temporaryAdd", "temporaryRemove", "temporaryLocate", "saveSession", "panelSettings", "brief", "full", "custom", "reverseSort", "symbolicLink", "hardLink"].contains(id) { return false }
        if let id = menuItem.representedObject as? String, filePanelCommands.contains(id), active.contentMode != .files { return false }
        if menuItem.action == #selector(functionMenu(_:)), (3...8).contains(menuItem.tag), active.contentMode != .files { return false }
        if let id = menuItem.representedObject as? String {
            switch id {
            case "networkConnect": return !toolMutationPending
            case "networkDisconnect", "networkPath", "networkRefresh": return active.isRemote && !toolMutationPending
            case "networkCancel": return network.isWorking
            case "networkRetry", "networkDiscard": return network.hasPendingDownload
            case "archiveOpen": return !active.isArchive && active.cursorEntry?.isDirectory == false && !toolMutationPending
            case "archiveClose": return active.isArchive
            case "archiveCreate": return !active.isArchive && !active.selectedEntries.isEmpty && !toolMutationPending
            case "archiveExtract": return active.isArchive && !passive.isArchive && !toolMutationPending
            case "archiveAdd": return !active.isArchive && passive.isArchive && passive.archivePanel?.snapshot.isEncrypted == false && !toolMutationPending
            case "archiveDelete": return active.archivePanel?.snapshot.isEncrypted == false && !toolMutationPending
            case "archiveCancel": return archiveOperations.isWorking
            default: break
            }
        }
        if active.isArchive, menuItem.action == #selector(functionMenu(_:)), [4, 8].contains(menuItem.tag), active.archivePanel?.snapshot.isEncrypted == true { return false }
        if active.isArchive, menuItem.action == #selector(functionMenu(_:)), [6, 7].contains(menuItem.tag) { return false }
        if menuItem.representedObject as? String == "back" { return active.canGoBack }
        if menuItem.representedObject as? String == "forward" { return active.canGoForward }
        if let id = menuItem.representedObject as? String, ["leaveResults", "temporaryRemove", "temporaryLocate"].contains(id) { return active.isTemporary && active.contentMode == .files }
        if menuItem.representedObject as? String == "temporaryAdd" { return active.contentMode == .files && !active.loading }
        return true
    }

    func performFunction(_ function: Int) {
        guard !busy, window.attachedSheet == nil else { NSSound.beep(); return }
        if terminalVisible && shellWorkspace.isRunning && ![1, 2, 9, 10].contains(function) { NSSound.beep(); return }
        if active.contentMode != .files && [3, 4, 5, 6, 7, 8].contains(function) {
            status.stringValue = "Для файловой операции переключитесь в режим «Файлы»."; NSSound.beep(); return
        }
        if active.isRemote {
            switch function {
            case 3, 4: network.open(active, editable: function == 4); return
            case 5, 6: network.transfer(from: active, to: passive, move: function == 6); return
            case 7: network.makeDirectory(active); return
            case 8: network.remove(active); return
            default: break
            }
        }
        if active.isArchive {
            switch function {
            case 3, 4: if let path = active.archivePanel?.cursorPath { openArchiveMember(active, path: path, editable: function == 4) }; return
            case 5: extractArchiveSelection(); return
            case 8: deleteArchiveSelection(); return
            case 6, 7: inform("Команда недоступна в архиве", "Используйте F5 для извлечения или добавления. Перемещение и создание папок внутри архива пока не поддерживаются."); return
            default: break
            }
        }
        switch function {
        case 1: help()
        case 2: shellWorkspace.showUserMenu()
        case 3: openText(editable: false)
        case 4: openText(editable: true)
        case 5: transfer(move: false)
        case 6: transfer(move: true)
        case 7: if active.isTemporary { active.removeTemporarySelection() } else { makeDirectory() }
        case 8: trash()
        case 9: showCommandMenu()
        case 10: NSApp.terminate(nil)
        default: break
        }
    }

    @objc func command(_ sender: Any) {
        guard window != nil, window.isKeyWindow, window.attachedSheet == nil else { return }
        let id = (sender as? NSButton)?.identifier?.rawValue ?? (sender as? NSMenuItem)?.representedObject as? String ?? ""
        if active.isArchive || active.isRemote, (filePanelCommands.contains(id) && id != "copyCursor") || ["search", "temporaryAdd", "temporaryRemove", "temporaryLocate", "saveSession", "panelSettings", "brief", "full", "custom", "reverseSort"].contains(id) { NSSound.beep(); return }
        if filePanelCommands.contains(id), active.contentMode != .files { NSSound.beep(); return }
        switch id {
        case "networkConnect": network.connect(in: active)
        case "networkDisconnect": active.leaveRemote()
        case "networkPath": network.goTo(active)
        case "networkRefresh": network.refresh(active)
        case "networkCancel": network.cancel()
        case "networkRetry": network.retryDownload()
        case "networkDiscard": network.discardDownload()
        case "archiveOpen": if let entry = active.cursorEntry, !entry.isDirectory { openArchive(entry.url, in: active) }
        case "archiveClose": active.leaveArchive()
        case "archiveCreate": createArchive()
        case "archiveExtract": extractArchiveSelection()
        case "archiveAdd": addToArchive()
        case "archiveDelete": deleteArchiveSelection()
        case "archiveCancel": archiveOperations.cancel()
        case "fileDescription": editFileDescription()
        case "sortGroups": editSortGroups()
        case "panelFiles": active.setContentMode(.files); active.focus()
        case "panelTree": active.setContentMode(.tree); active.focus()
        case "panelInfo": active.setContentMode(.info); active.focus()
        case "panelQuickView": active.setContentMode(.quickView); active.focus()
        case "compareDirectories": compareDirectories()
        case "temporaryAdd": addToTemporaryPanel()
        case "temporaryRemove": active.removeTemporarySelection()
        case "temporaryLocate": locateTemporaryItem()
        case "saveSession": left.persistSession(); right.persistSession(); status.stringValue = "Сессия панелей сохранена."
        case "commandLine": shellWorkspace.focusCommand()
        case "shell": shellWorkspace.interactiveShell()
        case "toggleTerminal": toggleTerminal()
        case "userCommands": shellWorkspace.configureCommands()
        case "commandHistory": shellWorkspace.showHistory(.command)
        case "viewHistory": shellWorkspace.showHistory(.view)
        case "editHistory": shellWorkspace.showHistory(.edit)
        case "folderHistory": shellWorkspace.showHistory(.folder)
        case "search": openSearch()
        case "leaveResults": active.leaveSearchResults()
        case "rename": if !busy { transfer(move: true, cursorOnly: true) }
        case "copyCursor": if !busy { transfer(move: false, cursorOnly: true) }
        case "operations": operationQueue.showWindow(nil)
        case "cancelOperations": operationQueue.cancelAll()
        case "batchRename": openBatchRename()
        case "properties": openProperties()
        case "symbolicLink": createLink(symbolic: true)
        case "hardLink": createLink(symbolic: false)
        case "deletePermanently": deletePermanently()
        case "mark": active.toggleMarkAndAdvance()
        case "markAll": active.markAll()
        case "clearMarks": active.saveSelectionForOperation(); active.clearMarks()
        case "invertMarks": active.invertMarks()
        case "invertAll": active.invertMarks(includeDirectories: true)
        case "markMask": selectionMask(mark: true)
        case "unmarkMask": selectionMask(mark: false)
        case "restoreMarks": active.restoreMarks()
        case "sameExtension": active.selectSameExtension(mark: true)
        case "unmarkExtension": active.selectSameExtension(mark: false)
        case "sameName": active.selectSameName(mark: true)
        case "unmarkName": active.selectSameName(mark: false)
        case "invertFiles": active.invertFilesAndClearDirectories()
        case "quickFind": active.focusQuickFind()
        case "findNext": active.findNext()
        case "findPrevious": active.findNext(backwards: true)
        case "back": active.goBack()
        case "forward": active.goForward()
        case "history": showPanelMenu(named: "История")
        case "bookmark": addBookmark()
        case "unbookmark": removeBookmark()
        case "favorites": showPanelMenu(named: "Избранное")
        case "syncToOther": passive.load(active.directory, preserveSelection: false)
        case "syncFromOther": active.load(passive.directory, preserveSelection: false)
        case "reverseSort": active.toggleSortDirection()
        case "brief": active.setDisplayMode(.brief)
        case "full": active.setDisplayMode(.full)
        case "custom": active.setDisplayMode(.custom)
        case "panelSettings": openPanelSettings()
        case "maskGroups": openMaskGroups()
        case "home": active.load(FileManager.default.homeDirectoryForCurrentUser, preserveSelection: false)
        case "volumes": showPanelMenu(named: "Тома")
        case "path": if active.isRemote { network.goTo(active) } else { active.focusPath() }
        case "filter": active.focusFilter()
        case "refresh": refresh()
        case "hidden":
            let value = !active.showHidden
            left.showHidden = value; right.showHidden = value
            UserDefaults.standard.set(value, forKey: "showHidden")
            refresh()
        case "choose": chooseDirectory()
        case "terminal":
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
            NSWorkspace.shared.open([active.directory], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.showError(error) } }
            }
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting(active.selectedEntries.map(\.url).isEmpty ? [active.directory] : active.selectedEntries.map(\.url))
        default: break
        }
    }

    func chooseDirectory() {
        dialogHelp = "Выберите папку для активной панели. Отмена оставляет текущий путь. Для другой панели используйте Option+F1 или Option+F2."
        let target = active!
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.directoryURL = target.directory
        picker.prompt = "Открыть папку"
        picker.beginSheetModal(for: window) { response in
            if response == .OK, let url = picker.url { target.load(url, preserveSelection: false); target.focus() }
        }
    }
    func refresh() {
        guard left != nil, right != nil else { return }
        let panels = [left!, right!]
        panels.forEach { $0.cancelInspection() }
        func next(_ index: Int) {
            guard index < panels.count else { return }
            let panel = panels[index]
            if panel.isRemote { network.refresh(panel, completion: { next(index + 1) }) }
            else if panel.isArchive { refreshArchive(panel, completion: { next(index + 1) }) }
            else { panel.load(); next(index + 1) }
        }
        next(0)
    }
    func selectionMask(mark: Bool) {
        guard !busy, !active.loading, window.attachedSheet == nil else { return }
        let panel = active!
        let action = mark ? "Отметить" : "Снять пометки"
        prompt("\(action) по маске", detail: "Примеры: *.swift;*.md|README* · <text> · /readme/i\nМаски с разделителями заключайте в кавычки. F1 — подробности.\n\(mark ? "Отмечаются только файлы; папку можно отметить Space." : "Пометки снимаются и с файлов, и с папок.")", value: "*", button: action) { [weak self] pattern in
            do {
                try panel.applyMask(pattern, mark: mark)
                panel.focus()
            } catch { self?.showError(error) }
        }
    }
    func requireCursor() -> FileEntry? {
        guard !active.loading else { return nil }
        guard let entry = active.cursorEntry else {
            guard window.attachedSheet == nil else { return nil }
            inform("Переместите курсор на файл или папку", "Строка «..» не является целью операции. Пометки других объектов для этой команды не используются.")
            return nil
        }
        return entry
    }
    func requireSelection(single: Bool = false) -> [FileEntry]? {
        guard !active.loading else { return nil }
        let selected = active.selectedEntries
        guard !selected.isEmpty, !single || selected.count == 1 else {
            guard window.attachedSheet == nil else { return nil }
            inform("Выберите \(single ? "один файл или папку" : "файлы или папки")", "Строка «..» служит только для перехода к родительской папке.")
            return nil
        }
        return selected
    }
    func openText(editable: Bool) {
        guard let entry = requireCursor() else { return }
        if entry.isDirectory {
            if editable { openProperties() }
            else { retainTool(DirectorySizeWindow(url: entry.url)) }
            return
        }
        if !shellWorkspace.association(for: entry.url, action: editable ? .edit : .view) {
            _ = openDocument(entry.url, editable: editable)
        }
    }
    @discardableResult
    private func openDocument(_ url: URL, editable: Bool, byteOffset: Int64? = nil, encoding: ViewerEncoding = .automatic) -> Bool {
        do {
            if editable {
                if let existing = editors.first(where: {
                    $0.window?.isVisible == true && $0.window?.representedURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
                }) { existing.showWindow(nil); return true }
                let editor = try TextFileWindow(url: url, editable: true, initialByteOffset: byteOffset, encoding: encoding,
                    onView: { [weak self] url, offset, encoding in self?.openDocument(url, editable: false, byteOffset: offset, encoding: encoding) ?? false })
                editors.removeAll { $0.window?.isVisible == false }
                editors.append(editor)
                editor.showWindow(nil)
            } else {
                let viewer = try ViewerWindow(url: url, initialByteOffset: byteOffset, initialEncoding: encoding,
                    onEdit: { [weak self] url, offset, encoding in self?.openDocument(url, editable: true, byteOffset: offset, encoding: encoding) ?? false })
                viewers.removeAll { $0.window?.isVisible == false }
                viewers.append(viewer)
                viewer.showWindow(nil)
            }
            shellWorkspace?.recordActivity(editable ? .edit : .view, value: url.path)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось открыть файл"
            alert.informativeText = error.localizedDescription
            if let target = NSApp.keyWindow, target.attachedSheet == nil { alert.beginSheetModal(for: target) }
            else { showError(error) }
            return false
        }
    }
    func openSearch() {
        guard !active.isArchive, !active.isRemote else { inform("Поиск внутри провайдера пока недоступен", "Откройте обычную папку для рекурсивного поиска."); return }
        if let searchWindow, searchWindow.window?.isVisible == true || searchWindow.isSearching {
            searchWindow.showWindow(nil)
            return
        }
        searchWindow = SearchWindow(directory: active.directory, maskGroups: maskGroups,
            onReveal: { [weak self] result in self?.revealSearchResult(result) },
            onOpen: { [weak self] result, editable in self?.openSearchResult(result, editable: editable) },
            onSendToPanel: { [weak self] results in
                guard let self else { return }
                self.active.showSearchResults(results)
                self.window.makeKeyAndOrderFront(nil)
                self.active.focus()
            })
        searchWindow?.showWindow(nil)
    }
    private func revealSearchResult(_ result: SearchResult) {
        do {
            try result.verifyCurrent()
            active.load(result.url.deletingLastPathComponent(), preserveSelection: false, selectName: result.name)
            window.makeKeyAndOrderFront(nil)
            active.focus()
        } catch { searchActionError(error) }
    }
    private func openSearchResult(_ result: SearchResult, editable: Bool) {
        do {
            try result.verifyCurrent()
            var targetIsDirectory = ObjCBool(false)
            let exists = FileManager.default.fileExists(atPath: result.url.path, isDirectory: &targetIsDirectory)
            if result.isDirectory || (exists && targetIsDirectory.boolValue) {
                if editable {
                    retainTool(FilePropertiesWindow(url: result.url, canMutate: { [weak self] in self?.canUseFileTools() ?? false }, onComplete: { [weak self] in self?.refresh() }))
                } else { retainTool(DirectorySizeWindow(url: result.url)) }
            } else {
                _ = openDocument(result.url, editable: editable)
            }
        } catch { searchActionError(error) }
    }
    private func searchActionError(_ error: Error) {
        let target = searchWindow?.window?.isVisible == true ? searchWindow?.window : window
        guard let target, target.attachedSheet == nil else { status.stringValue = error.localizedDescription; return }
        let alert = NSAlert()
        alert.messageText = "Результат поиска недоступен"
        alert.informativeText = error.localizedDescription
        target.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: target)
    }
    func retainTool(_ controller: NSWindowController) {
        toolWindows.removeAll { $0.window?.isVisible == false }
        toolWindows.append(controller)
        controller.showWindow(nil)
    }
    func canUseFileTools() -> Bool {
        guard !busy, !toolMutationPending, !operationQueue.hasPendingOperations else {
            status.stringValue = "Дождитесь операций или отмените очередь перед изменением свойств и имён."
            operationQueue.showWindow(nil)
            return false
        }
        return true
    }
    func openBatchRename() {
        guard canUseFileTools(), let selected = requireSelection() else { return }
        retainTool(BatchRenameWindow(urls: selected.map(\.url), canMutate: { [weak self] in self?.canUseFileTools() ?? false }, onComplete: { [weak self] in self?.refresh() }))
    }
    func openProperties() {
        guard let entry = requireCursor() else { return }
        retainTool(FilePropertiesWindow(url: entry.url, canMutate: { [weak self] in self?.canUseFileTools() ?? false }, onComplete: { [weak self] in self?.refresh() }))
    }
    func createLink(symbolic: Bool) {
        guard canUseFileTools(), let entry = requireCursor() else { return }
        do {
            let source = try FileTools.metadata(entry.url)
            let base = passive.directory
            prompt(symbolic ? "Символическая ссылка" : "Жёсткая ссылка", detail: "Источник: \(entry.url.path)\nНазначение должно отсутствовать. Жёсткая ссылка допустима только для файла на том же томе.", value: base.appendingPathComponent(entry.name + "-link").path, button: "Создать") { [weak self] text in
                let path = (text as NSString).expandingTildeInPath
                guard !path.isEmpty else { return }
                let destination = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                self?.runOperation("Создание ссылки…") { try FileTools.createLink(source: source, at: destination, symbolic: symbolic) }
            }
        } catch { showError(error) }
    }
    func deletePermanently() {
        guard canUseFileTools(), let selected = requireSelection() else { return }
        do {
            let items = try FileTools.snapshot(selected.map(\.url))
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Удалить безвозвратно \(items.count) объектов?"
            alert.informativeText = "Корзина не используется. Восстановление и откат не предусмотрены. При ошибке часть данных может быть уже удалена.\n\n" + items.prefix(8).map { $0.url.path }.joined(separator: "\n")
            dialogHelp = alert.informativeText
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Удалить безвозвратно")
            alert.beginSheetModal(for: window) { [weak self] answer in
                guard answer == .alertSecondButtonReturn else { return }
                self?.runOperation("Безвозвратное удаление…") { try FileTools.permanentlyDelete(items) }
            }
        } catch { showError(error) }
    }
    func makeDirectory() {
        guard !active.loading else { return }
        let directory = active.directory
        prompt("Новая папка", detail: directory.path, value: "Новая папка", button: "Создать") { [weak self] name in
            self?.runOperation("Создание папки…") { try FileService.createDirectory(named: name, in: directory) }
        }
    }
    func transfer(move: Bool, cursorOnly: Bool = false) {
        if active.isRemote || passive.isRemote { network.transfer(from: active, to: passive, move: move, cursorOnly: cursorOnly); return }
        if active.isArchive || passive.isArchive {
            if move { inform("Перемещение между архивом и папкой", "Пока доступно только копирование F5; исходники остаются на месте."); return }
            if active.isArchive { extractArchiveSelection(cursorOnly: cursorOnly) } else { addToArchive(cursorOnly: cursorOnly) }
            return
        }
        guard !toolMutationPending else { NSSound.beep(); return }
        let selected: [FileEntry]
        if cursorOnly {
            guard let entry = requireCursor() else { return }
            selected = [entry]
        } else {
            guard let entries = requireSelection() else { return }
            selected = entries
        }
        active.saveSelectionForOperation()
        let sources = selected.map(\.url)
        let searchSnapshots = active.capturedSearchResults(for: selected)
        let sourceDirectory = active.directory
        let sourceDescription = active.isTemporary
            ? sources.prefix(5).map(\.path).joined(separator: "\n") + (sources.count > 5 ? "\n…" : "")
            : sourceDirectory.path
        let relativeBase = active.isTemporary ? "\nОтносительное назначение отсчитывается от: \(sourceDirectory.path)" : ""
        let target = cursorOnly ? (move ? selected[0].url.path : passive.directory.appendingPathComponent(selected[0].name).path) : passive.directory.path
        prompt(move ? "Переместить / переименовать" : "Копировать", detail: "Объектов: \(sources.count)\nИз: \(sourceDescription)\nНазначение: существующая папка или полное новое имя для одного объекта.\(relativeBase)\nКонфликты запросят решение в окне операций. Отмена не откатывает завершённые файлы.", value: target, button: "В очередь") { [weak self] value in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self?.inform("Назначение не задано", "Укажите путь папки или новое имя файла."); return
            }
            let path = (value as NSString).expandingTildeInPath
            let destination = path.hasPrefix("/") ? URL(fileURLWithPath: path) : sourceDirectory.appendingPathComponent(path)
            guard let self, !self.toolMutationPending, !self.busy else { return }
            do { try searchSnapshots.forEach { try $0.verifyCurrent() } }
            catch { self.showError(error); return }
            self.operationQueue.enqueue(TransferRequest(sources: sources, destination: destination, move: move))
            self.status.stringValue = "Добавлено в очередь: \(sources.count) объектов"
        }
    }
    func trash() {
        guard let selected = requireSelection() else { return }
        active.saveSelectionForOperation()
        let urls = selected.map(\.url)
        let searchSnapshots = active.capturedSearchResults(for: selected)
        dialogHelp = "Выбранные объекты будут перемещены в Корзину macOS. Проверьте количество и имена. Отмена оставит файлы на месте. Ctrl+M на панели восстанавливает пометки, но не возвращает файлы из Корзины."
        let alert = NSAlert()
        alert.messageText = "Переместить в Корзину?"
        alert.informativeText = "Объектов: \(urls.count)\n" + selected.prefix(5).map { active.isTemporary ? $0.url.path : $0.name }.joined(separator: "\n") + (selected.count > 5 ? "\n…" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "В Корзину")
        alert.addButton(withTitle: "Отмена")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.runOperation("Перемещение в Корзину…") {
                    try searchSnapshots.forEach { try $0.verifyCurrent() }
                    try FileService.trash(urls)
                }
            }
        }
    }
    func runOperation(_ message: String, operation: @escaping @Sendable () throws -> Void) {
        guard !busy, !toolMutationPending else { return }
        guard !operationQueue.hasPendingOperations else {
            status.stringValue = "Дождитесь очереди или отмените её перед изменением файлов этой командой."
            operationQueue.showWindow(nil)
            return
        }
        busy = true
        status.stringValue = message
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try operation() }.value
                status.stringValue = "Готово · операция завершена"
            } catch {
                status.stringValue = "Операция не завершена"
                showError(error)
            }
            busy = false
            refresh()
        }
    }
    func prompt(_ title: String, detail: String, value: String, button: String, completion: @escaping (String) -> Void) {
        dialogHelp = title.contains("маске") ? "Маски: * и ? сопоставляют всё имя. [a-z] — диапазон символов. Несколько масок разделяются запятой или точкой с запятой; | вводит исключения. Маска в кавычках позволяет использовать разделители в имени.\n\n<text> — именованная группа. Группы редактируются в меню «Пометки». Вложенность допустима; циклы и неизвестные группы отклоняются.\n\n/readme/i — явное регулярное выражение; совпадение ищется внутри имени. Поддержаны флаги i, m, s, x. При превышении лимита времени весь набор пометок остаётся без изменений.\n\nДобавление по маске отмечает файлы. Снятие по маске действует также на папки." : "\(title)\n\n\(detail)\n\nEnter подтверждает, Escape отменяет. Изменения начнутся после подтверждения. Пути можно вводить с ~ для домашней папки. Копирование и перемещение выполняются в очереди. Совпадения имён требуют решения: заменить, пропустить, новое имя или объединить папки. Отмена сохраняет уже завершённые изменения."
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 480, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
        field.selectText(nil)
    }
    func inform(_ title: String, _ detail: String) {
        dialogHelp = title + "\n\n" + detail
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
    func showError(_ error: Error) {
        guard window.attachedSheet == nil else { status.stringValue = error.localizedDescription; return }
        inform("Не удалось выполнить действие", error.localizedDescription)
    }
    func help() {
        let key = NSApp.keyWindow
        let title: String, text: String
        if let key, viewers.contains(where: { $0.window === key || $0.window === key.sheetParent }) {
            title = "Просмотрщик"
            text = ViewerWindow.helpText
        } else if let searchWindow, key === searchWindow.window || key?.sheetParent === searchWindow.window {
            title = "Поиск файлов"
            text = SearchWindow.helpText
        } else if key === operationQueue.window || key?.sheetParent === operationQueue.window {
            title = "Файловые операции"
            text = FileOperationQueue.helpText
        } else if let controller = toolWindows.first(where: { $0.window === key }) {
            title = controller.window?.title ?? "Файловые инструменты"
            text = "F3 для папки считает логический размер без обхода символических ссылок; подсчёт можно остановить. F4 открывает свойства и позволяет менять POSIX-права выбранного объекта без рекурсии.\n\nГрупповое переименование использует шаблон {name}, {ext}, {n}. Сначала создайте и проверьте предпросмотр. Изменение шаблона сбрасывает предпросмотр. Существующие имена не перезаписываются; после частичной ошибки завершённые переименования остаются.\n\nЗакройте окно через Cmd+W. Во время записи дождитесь завершения."
        } else if key === settingsWindow?.window {
            title = "Настройки панели"
            text = "Сортировка и вид сохраняются отдельно для левой и правой панели.\n\nКраткий режим показывает имя. Полный добавляет сведения о размере, дате, правах и владельце. В своём режиме выберите колонки; имя всегда остаётся. Большое число колонок включает горизонтальную прокрутку.\n\nПапки первыми — отдельная группировка, независимая от направления. Естественный порядок ставит file2 перед file10. Учитывать регистр — сравнивать большие и малые буквы отдельно. Сортировка по пометкам обновляется при изменении пометок.\n\n«Применить» сохраняет настройки. «Отмена» закрывает без изменения."
        } else if key === groupsWindow?.window {
            title = "Группы масок"
            text = "Каждая строка задаёт имя=маска. Например:\ntext=*.txt;*.md\nsource=*.swift;<text>\n\nПрименяйте <source> в диалоге маски. Имя группы состоит из букв, цифр, _, - и точки. Группы могут ссылаться друг на друга, но циклы отклоняются.\n\nCmd+S сохраняет проверенную конфигурацию сразу для двух панелей. Если строка неверна, текст остаётся в окне, прежние группы не изменяются."
        } else if let key, editors.contains(where: { $0.window === key || $0.window === key.sheetParent }) {
            title = "Редактор"
            text = TextFileWindow.helpText
        } else if window.attachedSheet != nil {
            title = "Диалог"
            text = dialogHelp.isEmpty ? "Enter — подтвердить действие; Escape — отменить. Проверяйте пути и число объектов перед подтверждением. Корзина macOS позволяет восстановить удалённые объекты." : dialogHelp
        } else if active.isRemote {
            title = "Сетевая панель"
            text = "SFTP, FTP/FTPS и WebDAV: Enter — папка/просмотр, Tab — соседняя панель, Esc — отключиться. Пробел/Insert — пометки, Cmd+A — отметить всё.\n\nF3 — просмотр, F4 — локальная рабочая копия. Сохранение в редакторе не отправляет файл: нажмите «Сохранить на сервер» в отдельном окне. Удалённая версия проверяется повторно.\n\nF5 — копирование между обычной и сетевой панелями; F6 — перенос обычного файла после проверки копии. F7 — новая папка, F8 — удаление с сервера без Корзины. Непустые папки и перенос папок требуют отдельных действий.\n\nПосле разрыва используйте «Сеть → Продолжить скачивание». WebDAV со строгим ETag продолжает подтверждённую частичную копию; другие серверы начинают загрузку заново. При изменённой версии сбросьте задание. Незавершённое скачивание хранится до сброса или выхода из приложения. Между удалёнными панелями прямой перенос пока не поддерживается."
        } else if active.isArchive {
            title = "Архивная панель"
            text = "ZIP и несжатый TAR. Enter — войти в папку или просмотреть файл, Backspace — выше, Esc — закрыть архив, Tab — соседняя панель. Пробел/Insert — пометка, Cmd+A — отметить всё.\n\nF3 — просмотр, F4 — рабочая копия редактора. Сохранение в редакторе меняет только копию: примените её отдельной кнопкой «Сохранить в архив». F5 извлекает в обычную папку через очередь; F5 с противоположной файловой панели добавляет выбранное в текущую папку архива. F8 удаляет элементы из архива после подтверждения.\n\nСоздание ZIP/TAR доступно в меню «Архив» на обычной панели. Шифрованные ZIP доступны только для чтения с паролем. Вложенные, многотомные, ZIP64, 7z/RAR и сжатые TAR пока не поддерживаются."
        } else {
            title = "Файловая панель"
            text = "Курсор и пометки независимы. F5/F6/F8 обрабатывают пометки, без пометок — курсор. F3/F4 и Shift+F5/F6 используют только курсор. Для папки F3 считает размер, F4 открывает свойства.\n\nНАВИГАЦИЯ\nTab — другая панель; Enter — открыть; Backspace — выше.\nHome/End/PageUp/PageDown — перемещение; Shift — с пометкой.\nCmd+L — путь, Cmd+[ / Cmd+] — назад/вперёд.\nOption+буквы — быстрый поиск без фильтрации, Ctrl+Enter — следующее совпадение, Ctrl+Shift+Enter — предыдущее, Escape — закрыть поиск.\nCmd+F — фильтр текущей панели; скрываемые файлы теряют пометки.\nOption+F7 или Cmd+Shift+F — рекурсивный поиск файлов. Результаты можно открыть через F3/F4 или отправить во временную панель. Кнопка возврата восстанавливает обычную папку.\nOption+F1/F2 — тома и папки соответствующей панели.\nCtrl+Shift+0…9 — сохранить быструю папку; Ctrl+0…9 — перейти.\n\nПОМЕТКИ\nInsert/Space — переключить пометку и шагнуть вниз.\nShift+стрелки/Home/End/Page — пометить диапазон покидаемых строк.\nCtrl+M — восстановить прошлый набор, повтор — поменять наборы местами.\nNumpad +/− — маска; * — инверсия; Ctrl+* — с папками.\nCtrl+Numpad +/− — то же расширение; Ctrl+Shift+Numpad +/− — то же имя без расширения.\nCmd+A — все объекты, Cmd-щелчок — одна пометка.\n\nМЕНЮ\nCmd+J — очередь и журнал; отмена не откатывает завершённые файлы.\nF9 — все меню команд; меню «Вид» — сортировка, режим и колонки.\nCtrl+T — дерево, Ctrl+L — информация, Ctrl+Q — быстрый просмотр соседнего файла; Esc возвращает файлы. «Панели» — сравнение каталогов, описания и группы сортировки. Во временной панели F7 убирает только ссылку, Ctrl+PageUp открывает исходную папку.\nМеню «История», «Избранное» и «Тома» — переходы; «Панели» — синхронизация путей. Настройки сохраняются между запусками.\n\nF2 — пользовательское меню; «Команды» — настройка меню, ассоциации и истории. Cmd+Enter — строка команд, Tab/Ctrl+Space в строке — дополнить путь, Ctrl+E/X — история. Ctrl+O — панели/PTY; Ctrl+C в терминале — прервать. Shell открывает интерактивную сессию. Простой cd меняет панель, cd внутри shell меняет только сессию. На Mac для F-клавиш может потребоваться Fn."
        }
        contextHelp.present(title: title, text: text)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if toolMutationPending {
            status.stringValue = "Дождитесь завершения или отмены файловой операции."
            toolWindows.first { ($0 as? FileToolsWindowController)?.hasPendingMutation == true }?.showWindow(nil)
            return .terminateCancel
        }
        if operationQueue.hasPendingOperations {
            status.stringValue = "Перед выходом дождитесь очереди или отмените операции в её окне."
            operationQueue.showWindow(nil)
            return .terminateCancel
        }
        if busy { inform("Операция ещё выполняется", "Дождитесь завершения файловой операции перед выходом."); return .terminateCancel }
        if shellWorkspace?.confirmTermination() == false { return .terminateCancel }
        for controller in toolWindows.compactMap({ $0 as? MetadataEditingWindow }) where controller.window?.isVisible == true {
            if !controller.confirmClose() { return .terminateCancel }
        }
        for editor in editors where editor.window?.isVisible == true {
            if let window = editor.window, editor.windowShouldClose(window) == false { return .terminateCancel }
        }
        for session in archiveEdits where session.window?.isVisible == true {
            if !session.confirmClose() { return .terminateCancel }
        }
        if !network.confirmTermination() { return .terminateCancel }
        network.finalizeTermination()
        archiveEdits.forEach { $0.finalizeClose() }
        toolWindows.compactMap { $0 as? MetadataEditingWindow }.forEach { $0.finalizeClose() }
        editors.forEach { $0.finalizeClose() }
        searchWindow?.cancel()
        viewers.forEach { $0.cancelBackgroundWork() }
        // Termination need not deallocate controllers: remove private archive
        // working copies only after every close guard has approved.
        archiveEdits.forEach { $0.cleanupForTermination() }
        editors.forEach { $0.retainedArchiveWorkspace?.cleanup(); $0.retainedArchiveWorkspace = nil }
        viewers.forEach { $0.retainedArchiveWorkspace?.cleanup(); $0.retainedArchiveWorkspace = nil }
        left.persistSession(); right.persistSession()
        left.cancelInspection(); right.cancelInspection()
        shellWorkspace?.stopForExit()
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if window != nil && !busy { refresh() }
    }

    func setupMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "О FarForMac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть FarForMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Выйти из FarForMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        func submenu(_ name: String) -> NSMenu {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: name); item.submenu = menu; bar.addItem(item); return menu
        }
        let files = submenu("Файлы")
        let newFile = NSMenuItem(title: "Новый файл — Shift+F4", action: #selector(newEditor(_:)), keyEquivalent: "n")
        newFile.target = self; files.addItem(newFile)
        // Standard nil-target actions follow the active editor's responder
        // chain, so menu key equivalents also work when no keyDown is delivered.
        let save = NSMenuItem(title: "Сохранить", action: #selector(TextFileWindow.saveDocument(_:)), keyEquivalent: "s")
        files.addItem(save)
        let saveAs = NSMenuItem(title: "Сохранить как…", action: #selector(TextFileWindow.saveAsDocument(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]; files.addItem(saveAs)
        let recover = NSMenuItem(title: "Восстановить черновики редактора…", action: #selector(recoverEditors(_:)), keyEquivalent: "")
        recover.target = self; files.addItem(recover); files.addItem(.separator())
        let titles = ["Помощь", "Пользовательское меню", "Просмотр", "Редактировать", "Копировать…", "Переместить…", "Создать папку…", "В Корзину…"]
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(functionMenu(_:)), keyEquivalent: String(UnicodeScalar(0xF704 + index)!))
            item.keyEquivalentModifierMask = []
            item.target = self; item.tag = index + 1; files.addItem(item)
        }
        let renameItem = NSMenuItem(title: "Переименовать…", action: #selector(command(_:)), keyEquivalent: String(UnicodeScalar(0xF709)!))
        renameItem.keyEquivalentModifierMask = [.shift]
        renameItem.target = self; renameItem.representedObject = "rename"; files.addItem(renameItem)
        files.addItem(menuCommand("Копировать объект под курсором…", "copyCursor", key: String(UnicodeScalar(0xF708)!), modifiers: [.shift]))
        files.addItem(.separator())
        for (title, id) in [("Массовое переименование…", "batchRename"), ("Свойства и права…", "properties"), ("Создать символическую ссылку…", "symbolicLink"), ("Создать жёсткую ссылку…", "hardLink"), ("Удалить безвозвратно…", "deletePermanently")] {
            files.addItem(menuCommand(title, id))
        }
        let operations = submenu("Операции")
        operations.addItem(menuCommand("Очередь и журнал…", "operations", key: "j"))
        operations.addItem(menuCommand("Отменить все ожидающие и текущую", "cancelOperations"))
        let search = submenu("Поиск")
        search.addItem(menuCommand("Найти файлы… — ⌥F7", "search", key: "f", modifiers: [.command, .shift]))
        search.addItem(menuCommand("Вернуться из результатов к папке", "leaveResults"))
        let edit = submenu("Правка")
        for (name, action, key) in [("Отменить", Selector(("undo:")), "z"), ("Вырезать", #selector(NSText.cut(_:)), "x"), ("Копировать", #selector(NSText.copy(_:)), "c"), ("Вставить", #selector(NSText.paste(_:)), "v")] {
            edit.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; edit.insertItem(redo, at: 1)
        // Native responder routing keeps Cmd+A available inside modal field
        // editors; FileTable's override supplies panel marking semantics.
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let commands = submenu("Команды")
        for (title, id) in [("Командная строка — Cmd+Enter", "commandLine"), ("Панели / терминал — Ctrl+O", "toggleTerminal"), ("Интерактивный shell", "shell"), ("Настроить меню и ассоциации…", "userCommands"), ("История команд — Alt+F8", "commandHistory"), ("История просмотра — Alt+F11", "viewHistory"), ("История редактора", "editHistory"), ("История папок — Alt+F12", "folderHistory")] {
            let item = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; commands.addItem(item)
        }
        let navigation = submenu("Панели")
        for (name, id, key) in [("Описание файла…", "fileDescription", ""), ("Группы сортировки…", "sortGroups", ""), ("Файловая панель", "panelFiles", ""), ("Дерево каталогов · Ctrl+T", "panelTree", ""), ("Информационная панель · Ctrl+L", "panelInfo", ""), ("Быстрый просмотр · Ctrl+Q", "panelQuickView", ""), ("Сравнить каталоги…", "compareDirectories", ""), ("Добавить выбранное во временную соседнюю панель", "temporaryAdd", ""), ("Убрать из временной панели (без удаления файлов)", "temporaryRemove", ""), ("Перейти к исходной папке", "temporaryLocate", ""), ("Сохранить сессию панелей", "saveSession", ""), ("Перейти к пути…", "path", "l"), ("Выбрать папку…", "choose", "o"), ("Назад", "back", "["), ("Вперёд", "forward", "]"), ("Быстрый поиск по имени", "quickFind", ""), ("Следующее совпадение", "findNext", ""), ("Предыдущее совпадение", "findPrevious", ""), ("Фильтр текущей папки", "filter", "f"), ("Обновить", "refresh", "r"), ("Показать / скрыть скрытые файлы", "hidden", "."), ("Открыть этот путь в соседней панели", "syncToOther", ""), ("Взять путь соседней панели", "syncFromOther", ""), ("Настройки активной панели…", "panelSettings", ","), ("Открыть Терминал здесь", "terminal", "t"), ("Показать в Finder", "reveal", "")] {
            let item = NSMenuItem(title: name, action: #selector(command(_:)), keyEquivalent: key)
            item.target = self; item.representedObject = id; navigation.addItem(item)
        }
        let marks = submenu("Пометки")
        for (name, id) in [("Пометить и перейти вниз", "mark"), ("Отметить по маске…", "markMask"), ("Снять пометки по маске…", "unmarkMask"), ("Восстановить прошлые пометки — Ctrl+M", "restoreMarks"), ("Отметить то же расширение", "sameExtension"), ("Снять пометки с того же расширения", "unmarkExtension"), ("Отметить то же имя без расширения", "sameName"), ("Снять пометки с того же имени", "unmarkName"), ("Инвертировать файлы", "invertMarks"), ("Инвертировать всё, включая папки", "invertAll"), ("Инвертировать файлы и снять папки", "invertFiles"), ("Отметить всё", "markAll"), ("Снять все пометки", "clearMarks"), ("Группы масок…", "maskGroups")] {
            let item = NSMenuItem(title: name, action: #selector(command(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; marks.addItem(item)
        }
        attachPanelMenus(to: bar)
        let windows = submenu("Окно")
        windows.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windows.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let networks = submenu("Сеть")
        for (title, id) in [("Подключиться…", "networkConnect"), ("Отключиться", "networkDisconnect"), ("Удалённая папка…", "networkPath"), ("Обновить / подключиться повторно", "networkRefresh"), ("Отменить сетевую операцию", "networkCancel"), ("Продолжить скачивание", "networkRetry"), ("Сбросить незавершённое скачивание", "networkDiscard")] { networks.addItem(menuCommand(title, id)) }
        let archives = submenu("Архив")
        for (title, id) in [("Открыть как архив · Ctrl+PageDown", "archiveOpen"), ("Закрыть архив", "archiveClose"), ("Создать ZIP / TAR…", "archiveCreate"), ("Извлечь выбранное…", "archiveExtract"), ("Добавить выбранное в соседний архив…", "archiveAdd"), ("Удалить выбранное из архива…", "archiveDelete"), ("Отменить архивную операцию", "archiveCancel")] { archives.addItem(menuCommand(title, id)) }
        NSApp.windowsMenu = windows
        NSApp.mainMenu = bar
    }
}

@main
enum FarForMacMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
