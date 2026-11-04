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
    private let virtualOperations = NetworkOperationController()
    private var lastVirtualResults: [SearchMatch] = []
    private lazy var savedPanelRestore: SavedPanelRestoreController = {
        let controller = SavedPanelRestoreController()
        network.configureSavedPanelRestore(controller)
        controller.onProgress = { [weak self] index, total, path in
            self?.status.stringValue = "Восстановление \(index)/\(total): \(path)"
        }
        return controller
    }()
    private var persistentPanelsWindow: PersistentTemporaryPanelsWindow?
    private var archiveEdits: [ArchiveEditCommitWindow] = []

    private var restoredDrafts: Set<UUID> = []
    private var shellWorkspace: ShellWorkspace!
    private var panelsContainer: NSView!
    private var terminalVisible = false
    private var recordedPanelPaths: [ObjectIdentifier: String] = [:]
    private var folderFunctionButton: NSButton?
    private var archiveFunctionButtons: [Int: NSButton] = [:]
    private var comparisonWindow: DirectoryComparisonWindow?
    private var temporaryPanelsWindow: TemporaryPanelsWindow?
    private var synchronizingTemporaryPanels = false
    private var keyMonitor: Any?
    private var busy = false
    var settingsWindow: PanelSettingsWindow?
    var groupsWindow: MaskGroupsWindow?
    private var searchWindow: SearchWindow?
    private var toolWindows: [NSWindowController] = []
    private var toolMutationPending: Bool {
        searchWindow?.isProviderSearching == true || savedPanelRestore.isWorking || virtualOperations.isWorking || network.isWorking || archiveOperations.isWorking || archiveEdits.contains(where: { $0.isWorking }) || toolWindows.contains { ($0 as? FileToolsWindowController)?.hasPendingMutation == true }
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
            self?.refreshLocalPanelsIfIdle()
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
        if !AppRuntime.isSmoke { window.setFrameAutosaveName("FarMac.main") }
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

        let defaults = AppPreferences.defaults
        func location(_ key: String) -> URL {
            if let fixture = AppRuntime.smokeDirectory { return fixture }
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
            panel.onRemoteDisconnect = { [weak self] provider in
                guard let self else { return }
                let retained = self.lastVirtualResults.contains { match in
                    if case .remote(_, let captured) = match { return captured === provider }; return false
                } || self.searchWindow?.retainsRemoteProvider(provider) == true || [self.left!, self.right!].contains { panel in
                    panel.virtualResults.contains { if case .remote(_, let captured) = $0 { return captured === provider }; return false }
                }
                if !retained { self.network.disconnected(provider) }
            }
            panel.showHidden = defaults.bool(forKey: "showHidden")
            panel.maskGroups = maskGroups
            if let data = defaults.data(forKey: "panel.sortGroups"), let groups = try? SortGroups.decode(data, maskGroups: maskGroups) { panel.sortGroups = groups }
            panel.onTemporaryLibrarySnapshot = { [weak self] slot, items in
                guard let self, !self.synchronizingTemporaryPanels else { return }
                self.temporaryPanelsWindow?.updateLinkedSlot(slot, items: items)
            }
            panel.onFocus = { [weak self] pane in self?.activate(pane) }
            panel.onError = { [weak self] error in self?.showError(error) }
            panel.onVirtualReveal = { [weak self] panel, match in self?.activate(panel); self?.revealSearchMatch(match) }
            panel.onVirtualOpen = { [weak self] panel, match in self?.activate(panel); self?.openSearchMatch(match, editable: false) }
            panel.onVirtualResultsChange = { [weak self] matches in
                guard let self, !self.synchronizingTemporaryPanels else { return }
                self.lastVirtualResults = matches
                self.persistentTemporaryPanels().persistLastMixed(matches)
            }
            panel.onVirtualLibrarySnapshot = { [weak self] slot, matches in
                guard let self, !self.synchronizingTemporaryPanels else { return }
                self.persistentTemporaryPanels().updateLinkedSlot(slot, items: matches)
            }
            panel.onArchiveView = { [weak self] panel, path in self?.openArchiveMember(panel, path: path, editable: false) }
            panel.onArchiveOpenNested = { [weak self] panel, path in self?.openNestedArchive(panel, path: path) }
            panel.onArchiveRefresh = { [weak self] panel in self?.refreshArchive(panel) }
            panel.onArchiveSwitchPanel = { [weak self] in guard let self else { return }; self.activate(self.passive); self.active.focus() }
            panel.onFileOpen = { [weak self, weak panel] entry in
                guard let self, let panel else { return }
                if ArchivePanelView.isArchiveName(entry.url.lastPathComponent) {
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
            return UserCommandContext(currentFile: self.active.cursorEntry?.url, markedFiles: self.active.markedEntries.map(\.url), activeDirectory: self.active.directory, passiveDirectory: self.passive.directory, passiveCurrentFile: self.passive.cursorEntry?.url, passiveMarkedFiles: self.passive.markedEntries.map(\.url))
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
        if !AppRuntime.isSmoke { DispatchQueue.main.async { [weak self] in self?.offerEditorRecovery(automatic: true) } }
        lastVirtualResults = persistentTemporaryPanels().savedLastMixed.map(SearchMatch.saved)
        configureAutomation()
        installWorkspaceObservers()
        applyInterfacePreferences()
        if AppRuntime.isSmoke { Task { await runUISmoke() } }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow != nil else { return event }
            if CommandWorkspace.shared.handle(event) { return nil }
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
        editors.removeAll { $0.window?.isVisible == false && $0.retainedArchiveWorkspace == nil && $0.retainedRemoteWorkspace == nil }
        editors.append(editor); editor.showWindow(nil)
    }

    @objc private func recoverEditors(_ sender: Any?) { offerEditorRecovery(automatic: false) }

    private func offerEditorRecovery(automatic: Bool) {
        do {
            let recovery = try AppRuntime.recoveryStore.loadAvailable()
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
        let generation = panel.locationGeneration
        archiveOperations.open(url) { [weak self, weak panel] result in
            guard let self, let panel else { return }
            switch result {
            case .success(let snapshot):
                guard panel.locationGeneration == generation else { return }
                self.activate(panel); panel.showArchive(snapshot)
                self.status.stringValue = "Архив открыт. Enter — папка/просмотр; F5 — извлечь."
            case .failure(let error): self.archiveFailure(error)
            }
        }
    }
    private func openNestedArchive(_ panel: PanelView, path: String) {
        guard !busy, !toolMutationPending, let frame = panel.archiveFrame,
              frame.snapshot.entries.contains(where: { $0.path == path && !$0.isDirectory }) else { return }
        archiveOperations.openNested(frame, path: path) { [weak self, weak panel] result in
            guard let self, let panel, panel.archiveFrame === frame else { return }
            switch result {
            case .success(let child):
                panel.showArchive(frame: child)
                self.status.stringValue = L10n.text("Вложенный архив открыт только для чтения. F5 — извлечь; Esc — к родительскому архиву.")
            case .failure(let error): self.archiveFailure(error)
            }
        }
    }
    private func refreshArchive(_ panel: PanelView, completion: @escaping () -> Void = {}) {
        guard !toolMutationPending, !busy, let archive = panel.archivePanel else { completion(); return }
        if panel.archiveFrame?.parent != nil {
            defer { completion() }
            do { try archive.snapshot.verifyCurrent(); archive.update(snapshot: archive.snapshot) }
            catch { archiveFailure(error) }
            return
        }
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
    private func createArchiveDirectory() {
        guard canWriteArchive(), let browser = active.archivePanel, !browser.snapshot.isReadOnly else { return }
        let snapshot = browser.snapshot, base = browser.currentDirectory
        prompt("Новая папка в архиве", detail: "Путь относительно текущей папки. Начальный / означает корень архива. Архив будет переписан целиком; отмена до публикации сохраняет оригинал.", value: "Новая папка", button: "Создать") { [weak self] value in
            guard let self, self.canWriteArchive() else { return }
            do {
                let path = try ArchiveMutationInput.resolve(value, relativeTo: base)
                self.archiveOperations.createDirectory(snapshot, path: path) { [weak self] result in
                    switch result {
                    case .success(let updated): self?.archiveUpdated(updated)
                    case .failure(let error): self?.archiveFailure(error)
                    }
                }
            } catch { self.archiveFailure(error) }
        }
    }
    private func moveArchiveSelection(cursorOnly: Bool = false) {
        guard canWriteArchive(), let browser = active.archivePanel, !browser.snapshot.isReadOnly else { return }
        let paths = cursorOnly ? browser.cursorPath.map { [$0] } ?? [] : browser.selectedArchivePaths
        guard !paths.isEmpty else { return }
        let snapshot = browser.snapshot, base = browser.currentDirectory
        let initial = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "/"
        prompt("Переместить / переименовать внутри архива", detail: "Объектов: \(paths.count). Для одного объекта укажите новое полное имя, для нескольких — папку назначения. Относительно текущей папки, / — корень архива. Конфликты останавливают операцию без замены. Перемещение между архивом и обычной папкой здесь не выполняется.", value: initial, button: "Переместить") { [weak self] value in
            guard let self, self.canWriteArchive() else { return }
            do {
                let mapping = try ArchiveMutationInput.mapping(paths: paths, destination: value, relativeTo: base)
                self.archiveOperations.move(snapshot, entries: mapping) { [weak self] result in
                    switch result {
                    case .success(let updated): self?.archiveUpdated(updated)
                    case .failure(let error): self?.archiveFailure(error)
                    }
                }
            } catch { self.archiveFailure(error) }
        }
    }
    private func openArchiveMember(_ panel: PanelView, path: String, editable: Bool) {
        guard !busy, !toolMutationPending, let browser = panel.archivePanel else { return }
        if browser.cursorPath == path && browser.cursorIsDirectory { return }
        openArchiveMember(snapshot: browser.snapshot, path: path, editable: editable)
    }
    private func openArchiveMember(snapshot: ArchiveSnapshot, path: String, editable: Bool, byteOffset: Int64? = nil) {
        guard !busy, !toolMutationPending, snapshot.entries.contains(where: { $0.path == path && !$0.isDirectory }) else { return }
        if editable && snapshot.isReadOnly { inform("Архив доступен только для чтения", "Для редактирования извлеките файл в обычную папку. Изменение вложенных и зашифрованных архивов не поддерживается."); return }
        archiveOperations.extract(snapshot, paths: [path]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.archiveFailure(error)
            case .success(let workspace):
                do { try snapshot.verifyCurrent() } catch { self.archiveFailure(error); return }
                if editable { _ = self.openArchiveEditor(snapshot: snapshot, path: path, workspace: workspace, byteOffset: byteOffset) }
                else {
                    do {
                        let memberURL = try workspace.url(for: path)
                        let viewer = try ViewerWindow(url: memberURL, initialByteOffset: byteOffset, initialDisplayMode: byteOffset == nil ? nil : .hex, onEdit: { [weak self, weak workspace] url, offset, encoding in
                            guard let self else { return false }
                            guard url.standardizedFileURL == memberURL.standardizedFileURL else {
                                return self.openDocument(url, editable: true, byteOffset: offset, encoding: encoding)
                            }
                            guard let workspace else { return false }
                            return self.openArchiveEditor(snapshot: snapshot, path: path, workspace: workspace, byteOffset: offset, encoding: encoding)
                        })
                        viewer.retainedArchiveWorkspace = workspace
                        viewer.showWorkingCopyLocation(ArchiveNavigationFrame(snapshot: snapshot).displayPath + " !/" + path)
                        self.viewers.removeAll { $0.window?.isVisible == false }; self.viewers.append(viewer)
                        viewer.showWindow(nil); viewer.window?.makeKeyAndOrderFront(nil)
                    } catch { self.archiveFailure(error) }
                }
            }
        }
    }
    @discardableResult private func openArchiveEditor(snapshot: ArchiveSnapshot, path: String, workspace: ArchiveWorkspace, byteOffset: Int64? = nil, encoding: ViewerEncoding = .automatic) -> Bool {
        guard !snapshot.isReadOnly else { inform("Архив доступен только для чтения", "Для редактирования извлеките файл в обычную папку. Изменение вложенных и зашифрованных архивов не поддерживается."); return false }
        do {
            let editor = try TextFileWindow(url: workspace.url(for: path), initialByteOffset: byteOffset, encoding: encoding)
            editor.retainedArchiveWorkspace = workspace
            let commit = try ArchiveEditCommitWindow(snapshot: snapshot, path: path, workspace: workspace, editor: editor,
                canCommit: { [weak self] in self?.canWriteArchive() ?? false },
                onCommitted: { [weak self] snapshot in self?.archiveUpdated(snapshot) })
            editors.removeAll { $0.window?.isVisible == false && $0.retainedArchiveWorkspace == nil && $0.retainedRemoteWorkspace == nil }; editors.append(editor)
            archiveEdits.removeAll { $0.window?.isVisible == false }; archiveEdits.append(commit)
            commit.showWindow(nil); editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            editor.window?.subtitle = "Рабочая копия · применить через окно «Сохранить в архив»"
            return true
        } catch { archiveFailure(error); return false }
    }
    private func extractArchiveSelection(cursorOnly: Bool = false) {
        guard !busy, !toolMutationPending, let browser = active.archivePanel else { return }
        guard !passive.isVirtual, !passive.isArchive, !passive.isRemote else { inform("Выберите обычную папку назначения", "Прямое извлечение в другой архив или сетевую панель пока не поддерживается."); return }
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
                        if self.operationQueue.enqueue(TransferRequest(sources: urls, destination: destination, move: false, propagateDescriptions: false), retaining: workspace) {
                            self.status.stringValue = "Извлечение передано в очередь."
                        }
                    } catch { self.archiveFailure(error) }
                }
            }
        }
    }
    private func addToArchive(cursorOnly: Bool = false) {
        guard canWriteArchive(), !active.isVirtual, !active.isArchive, !active.isRemote, let browser = passive.archivePanel, !browser.snapshot.isReadOnly else { return }
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
        guard canWriteArchive(), let browser = active.archivePanel, !browser.snapshot.isReadOnly else { return }
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
        guard canWriteArchive(), !active.isVirtual, !active.isArchive, !active.isRemote, let selected = requireSelection() else { return }
        let captured = active.capturedSearchResults(for: selected)
        let alert = NSAlert(); alert.messageText = "Формат нового архива"
        alert.informativeText = L10n.text("Выберите формат и сжатие. Шифрование при создании пока не поддерживается.")
        let formats = ArchiveFormat.allCases
        let picker = archiveFormatPicker()
        alert.accessoryView = picker
        alert.addButton(withTitle: L10n.text("Продолжить")); alert.addButton(withTitle: L10n.text("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn, formats.indices.contains(picker.indexOfSelectedItem) else { return }
        let format = formats[picker.indexOfSelectedItem]
        let save = NSSavePanel(); save.title = "Создать архив"; save.directoryURL = active.directory
        save.nameFieldStringValue = "Archive." + format.defaultExtension
        if let type = UTType(filenameExtension: (format.defaultExtension as NSString).pathExtension.isEmpty ? format.defaultExtension : (format.defaultExtension as NSString).pathExtension) { save.allowedContentTypes = [type] }
        guard save.runModal() == .OK, let destination = save.url else { return }
        do { try captured.forEach { try $0.verifyCurrent() } } catch { archiveFailure(error); return }
        archiveOperations.create(sources: selected.map(\.url), destination: destination, format: format) { [weak self] result in
            switch result { case .success(let snapshot): self?.archiveUpdated(snapshot); case .failure(let error): self?.archiveFailure(error) }
        }
    }
    private func archiveFormatPicker() -> NSPopUpButton {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
        picker.addItems(withTitles: ArchiveFormat.allCases.map(\.displayName))
        picker.setAccessibilityLabel(L10n.text("Формат нового архива"))
        return picker
    }

    private func updateFunctionLabels() {
        let remote = active?.isRemote == true
        let archive = active?.isArchive == true
        let readOnly = active?.archivePanel?.snapshot.isReadOnly == true
        let temporary = !archive && !remote && active?.isTemporary == true
        archiveFunctionButtons[4]?.isEnabled = !readOnly
        archiveFunctionButtons[5]?.isEnabled = !(archive && (passive.isArchive || passive.isRemote)) && !(passive.isArchive && (remote || passive.archivePanel?.snapshot.isReadOnly == true))
        archiveFunctionButtons[5]?.title = archive ? "F5  Извлечь" : (passive.isArchive == true ? "F5  В архив" : "F5  Копия")
        archiveFunctionButtons[5]?.toolTip = archive ? "Извлечь выбранные элементы в обычную папку через очередь." : (passive.isArchive ? "Добавить выбранные файлы в соседний архив." : "Копировать выбранные файлы.")
        archiveFunctionButtons[6]?.isEnabled = archive ? !readOnly : !passive.isArchive
        archiveFunctionButtons[8]?.title = (archive || remote) ? "F8  Удалить" : "F8  Корзина"
        archiveFunctionButtons[8]?.toolTip = remote ? "Удаление с сервера без Корзины после подтверждения." : archive ? "Удалить выбранные элементы из архива после подтверждения. Корзина не используется." : "Переместить выбранные файлы в Корзину macOS."
        archiveFunctionButtons[8]?.isEnabled = !readOnly
        folderFunctionButton?.isEnabled = !readOnly
        folderFunctionButton?.title = temporary ? "F7  Убрать" : "F7  Папка"
        folderFunctionButton?.toolTip = temporary ? "F7 — убрать ссылку из временной панели, сохранив файл." : "F7 — создать папку."
        if passive.isVirtual { archiveFunctionButtons[5]?.isEnabled = !remote && !archive; archiveFunctionButtons[6]?.isEnabled = false }
        if active?.isVirtual == true {
            archiveFunctionButtons[4]?.isEnabled = active.cursorVirtualResult?.canEdit == true
            archiveFunctionButtons[5]?.isEnabled = !passive.isArchive && !passive.isRemote && !passive.isVirtual && !passive.isTemporary
            archiveFunctionButtons[5]?.title = "F5  Копия"
            archiveFunctionButtons[6]?.isEnabled = false
            archiveFunctionButtons[8]?.isEnabled = true
            archiveFunctionButtons[8]?.title = "F8  Убрать"
            archiveFunctionButtons[8]?.toolTip = "Убрать ссылки из панели. Исходные файлы сохраняются."
            folderFunctionButton?.isEnabled = true; folderFunctionButton?.title = "F7  Убрать"
        }
        for button in archiveFunctionButtons.values { button.title = L10n.text(button.title) }
        if let button = folderFunctionButton { button.title = L10n.text(button.title) }
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
                AppPreferences.defaults.set(try groups.jsonData(), forKey: "panel.sortGroups")
                self.left.sortGroups = groups; self.right.sortGroups = groups
            } catch { self.showError(error) }
        }
        toolWindows.removeAll { $0.window?.isVisible == false }
        toolWindows.append(controller); controller.showWindow(nil)
    }
    private func compareDirectories() {
        guard !left.isVirtual, !right.isVirtual, !left.isTemporary, !right.isTemporary, !left.isArchive, !right.isArchive, !left.isRemote, !right.isRemote else {
            inform("Сравнение каталогов", "Вернитесь из временной панели к папкам."); return
        }
        let leftURL = left.directory, rightURL = right.directory
        comparisonWindow = DirectoryComparisonWindow(left: leftURL, right: rightURL) { [weak self] leftURLs, rightURLs in
            guard let self else { return }
            guard self.left.directory == leftURL, self.right.directory == rightURL,
                  !self.left.isVirtual, !self.right.isVirtual, !self.left.isTemporary, !self.right.isTemporary, !self.left.loading, !self.right.loading else {
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
        if active.isVirtual {
            do { try passive.appendVirtualResults(active.selectedVirtualResults) } catch { showError(error) }
            return
        }
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
                if target.isVirtual { try target.appendVirtualResults(results.map(SearchMatch.local)) }
                else { try target.addTemporaryItems(results) }
                status.stringValue = "Добавлено ссылок: \(results.count). Исходные файлы не перемещались."
            } catch { showError(error) }
        }
    }
    private func commonTemporaryPanels() -> TemporaryPanelsWindow {
        if let temporaryPanelsWindow { return temporaryPanelsWindow }
        let store = AppRuntime.smokeStateDirectory.map { TemporaryPanelLibraryStore(url: $0.appendingPathComponent("common-panels/panels.json")) } ?? TemporaryPanelLibraryStore()
        let controller = TemporaryPanelsWindow(store: store, captureCurrent: { [weak self] in
            guard let self, self.active.isTemporary else { return nil }
            return (self.active.temporaryLibrarySlot, self.active.temporaryResults)
        }, onOpen: { [weak self] slot, items in
            guard let self else { return }
            self.synchronizingTemporaryPanels = true
            self.active.showTemporaryLibrarySlot(slot, items: items)
            self.synchronizingTemporaryPanels = false
            self.window.makeKeyAndOrderFront(nil); self.active.focus()
        }, onError: { [weak self] error in self?.showError(error) }, onStored: { [weak self] slot, items in
            guard let self, !self.synchronizingTemporaryPanels else { return }
            self.synchronizingTemporaryPanels = true
            for panel in [self.left!, self.right!] where panel.temporaryLibrarySlot == slot {
                panel.showTemporaryLibrarySlot(slot, items: items, focus: false)
            }
            self.synchronizingTemporaryPanels = false
        })
        temporaryPanelsWindow = controller
        return controller
    }
    private func persistentTemporaryPanels() -> PersistentTemporaryPanelsWindow {
        if let persistentPanelsWindow { return persistentPanelsWindow }
        let store = AppRuntime.smokeStateDirectory.map {
            PersistentTemporaryPanelsStore(url: $0.appendingPathComponent("mixed-common/mixed-panels.json"),
                legacyURL: $0.appendingPathComponent("common-panels/panels.json"))
        } ?? PersistentTemporaryPanelsStore()
        let controller = PersistentTemporaryPanelsWindow(store: store, captureCurrent: { [weak self] in
            guard let self, let active = self.active else { return nil }
            if active.isVirtual { return (active.virtualLibrarySlot, active.virtualResults) }
            if active.isTemporary { return (nil, active.temporaryResults.map(SearchMatch.local)) }
            return nil
        }, onOpen: { [weak self] slot, references in
            guard let self else { return }
            do {
                try self.active.showVirtualLibrarySlot(slot, matches: references.map(SearchMatch.saved))
                self.window.makeKeyAndOrderFront(nil); self.active.focus()
            } catch { self.showError(error) }
        }, onError: { [weak self] error in self?.searchActionError(error) }, onStored: { [weak self] slot, references in
            guard let self, !self.synchronizingTemporaryPanels else { return }
            self.synchronizingTemporaryPanels = true
            defer { self.synchronizingTemporaryPanels = false }
            do {
                for panel in [self.left!, self.right!] where panel.virtualLibrarySlot == slot {
                    try panel.refreshVirtualLibrarySlot(slot, references: references)
                }
            } catch { self.showError(error) }
        })
        persistentPanelsWindow = controller
        return controller
    }

    private func importTemporaryList() {
        guard !busy, !active.isVirtual, !active.isArchive, !active.isRemote else { return }
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        chooser.title = L10n.text("Импорт списка во временную панель…")
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        let target = active!, directory = target.directory
        let format: TemporaryPanelList.Format = url.pathExtension.lowercased() == "json" ? .json : url.pathExtension.lowercased() == "lst0" ? .nul : .lines
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let urls = try TemporaryPanelList.read(url, format: format)
                    var items: [SearchResult] = [], skipped = 0
                    for path in urls {
                        do { items.append(try SearchResult.capture(path)) } catch { skipped += 1 }
                    }
                    return (items, skipped)
                }.value
                guard target.directory == directory, !target.isArchive, !target.isRemote else { throw PanelSessionError("Панель изменилась во время импорта.") }
                try target.addTemporaryItems(result.0)
                status.stringValue = L10n.text("Импортировано ссылок") + ": \(result.0.count); " + L10n.text("Недоступных путей") + ": \(result.1)"
            } catch { showError(error) }
        }
    }
    private func exportTemporaryList() {
        guard !busy, !active.isVirtual, !active.isArchive, !active.isRemote else { return }
        let urls = active.isTemporary ? active.temporaryResults.map(\.url) : active.selectedEntries.map(\.url)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let chooser = NSSavePanel(); chooser.allowedContentTypes = [.json]; chooser.nameFieldStringValue = "panel-list.json"
        chooser.title = L10n.text("Экспорт списка путей…")
        guard chooser.runModal() == .OK, let url = chooser.url else { return }
        do {
            try TemporaryPanelList.encode(urls).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status.stringValue = L10n.text("Список путей сохранён") + ": " + url.path
        } catch { showError(error) }
    }
    private func locateTemporaryItem() {
        if active.isVirtual, let match = active.cursorVirtualResult { revealSearchMatch(match); return }
        guard active.isTemporary, let item = active.cursorEntry else { return }
        active.setContentMode(.files)
        active.load(item.url.deletingLastPathComponent(), preserveSelection: false, selectName: item.name)
    }

    func activate(_ panel: PanelView) {
        active = panel
        left.active = panel === left
        right.active = panel === right
        shellWorkspace?.updateDirectory()
        AppPreferences.defaults.set(panel.locationKey, forKey: "session.activePanel")
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
        if active.isVirtual || active.isArchive || active.isRemote { return false }
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
    private let virtualPanelCommands: Set<String> = ["temporarySlots", "temporaryRemove", "temporaryLocate", "temporaryLastMixed", "temporaryAdd", "copyCursor", "search", "mark", "markAll", "clearMarks", "invertMarks", "invertAll", "markMask", "unmarkMask", "restoreMarks", "sameExtension", "unmarkExtension", "sameName", "unmarkName", "invertFiles", "filter", "reverseSort", "refresh", "home", "parent", "back", "forward", "networkConnect", "networkCancel", "archiveCancel", "operationQueue", "help", "commandLine", "toggleTerminal"]
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.representedObject as? String == "descriptionPropagation" {
            menuItem.state = DescriptionPreferences.enabled ? .on : .off
        }
        if menuItem.action == #selector(showInterfacePreferences(_:)) { return NSApp.modalWindow == nil }
        if menuItem.action == #selector(functionMenu(_:)), menuItem.tag == 8 {
            menuItem.title = active?.isVirtual == true ? "Убрать ссылки из панели" : active?.isRemote == true ? "Удалить с сервера…" : active?.isArchive == true ? "Удалить из архива…" : "В Корзину…"
        }
        if menuItem.action == #selector(functionMenu(_:)), menuItem.tag == 5 {
            menuItem.title = active?.isArchive == true ? "Извлечь из архива…" : (passive.isArchive == true ? "Добавить в архив…" : "Копировать…")
        }
        if menuItem.action == #selector(functionMenu(_:)), menuItem.tag == 7 {
            menuItem.title = (active?.isVirtual == true || active?.isTemporary == true) ? "Убрать из временной панели" : "Создать папку…"
        }
        if menuItem.action == #selector(functionMenu(_:)) && menuItem.tag == 1 { return true }
        if menuItem.action == #selector(newEditor(_:)) || menuItem.action == #selector(recoverEditors(_:)) {
            return NSApp.keyWindow?.attachedSheet == nil
        }
        guard window != nil && window.isKeyWindow && window.attachedSheet == nil && !busy else { return false }
        if active.isVirtual {
            if menuItem.action == #selector(functionMenu(_:)) {
                if [2, 6].contains(menuItem.tag) { return false }
                if menuItem.tag == 4 { return active.cursorVirtualResult?.canEdit == true && !toolMutationPending }
                if menuItem.tag == 5 { return !passive.isVirtual && !passive.isRemote && !passive.isArchive && !passive.isTemporary && !toolMutationPending }
            }
            if let id = menuItem.representedObject as? String, !virtualPanelCommands.contains(id) { return false }
        }
        if menuItem.representedObject as? String == "temporaryLastMixed" { return !lastVirtualResults.isEmpty }
        if let id = menuItem.representedObject as? String, (active.isArchive || active.isRemote),
           (filePanelCommands.contains(id) && id != "copyCursor") || ["temporaryAdd", "temporaryRemove", "temporaryLocate", "temporaryImport", "temporaryExport", "alternateExecute", "alternateView", "alternateEdit", "saveSession", "panelSettings", "brief", "full", "custom", "reverseSort", "symbolicLink", "hardLink"].contains(id) { return false }
        if let id = menuItem.representedObject as? String, filePanelCommands.contains(id), active.contentMode != .files { return false }
        if menuItem.action == #selector(functionMenu(_:)), (3...8).contains(menuItem.tag), active.contentMode != .files { return false }
        if let id = menuItem.representedObject as? String {
            switch id {
            case "networkConnect": return !toolMutationPending
            case "networkDisconnect", "networkPath", "networkRefresh", "networkRename": return active.isRemote && !toolMutationPending
            case "networkCancel": return network.isWorking || virtualOperations.isWorking || savedPanelRestore.isWorking
            case "networkReconnect": return active.remotePanel?.provider is SFTPProvider && !toolMutationPending
            case "networkRetry", "networkDiscard": return network.hasPendingDownload
            case "archiveOpen": return !toolMutationPending && (active.isArchive ? active.archivePanel?.cursorPath != nil && active.archivePanel?.cursorIsDirectory == false : !active.isRemote && active.cursorEntry?.isDirectory == false)
            case "archiveClose": return active.isArchive
            case "archiveCreate": return !active.isArchive && !active.isRemote && !active.selectedEntries.isEmpty && !toolMutationPending
            case "archiveExtract": return active.isArchive && !passive.isArchive && !passive.isRemote && !toolMutationPending
            case "archiveAdd": return !active.isArchive && !active.isRemote && passive.isArchive && passive.archivePanel?.snapshot.isReadOnly == false && !toolMutationPending
            case "archiveDelete", "archiveMove", "archiveMkdir": return active.archivePanel?.snapshot.isReadOnly == false && !toolMutationPending
            case "archiveCancel": return archiveOperations.isWorking
            default: break
            }
        }
        if active.isArchive, menuItem.action == #selector(functionMenu(_:)), [4, 6, 7, 8].contains(menuItem.tag), active.archivePanel?.snapshot.isReadOnly == true { return false }
        if menuItem.representedObject as? String == "back" { return active.canGoBack }
        if menuItem.representedObject as? String == "forward" { return active.canGoForward }
        if let id = menuItem.representedObject as? String, ["leaveResults", "temporaryRemove", "temporaryLocate"].contains(id) { return (active.isVirtual || active.isTemporary) && active.contentMode == .files }
        if let id = menuItem.representedObject as? String, ["alternateExecute", "alternateView", "alternateEdit"].contains(id) {
            return active.contentMode == .files && !active.loading && active.cursorEntry?.isDirectory == false
        }
        if let id = menuItem.representedObject as? String, ["temporaryImport", "temporaryExport", "temporarySlots"].contains(id) {
            return active.contentMode == .files && !active.loading
        }
        if menuItem.representedObject as? String == "temporaryAdd" { return active.contentMode == .files && !active.loading }
        return true
    }

    private func configureAutomation() {
        let workspace = CommandWorkspace.shared
        workspace.panelState = { [weak self] in
            guard let self, !self.active.isVirtual, !self.active.isArchive, !self.active.isRemote, self.active.contentMode == .files,
                  !self.active.loading, !self.terminalVisible else { return nil }
            return MacroEnvironment(context: .panel, fileName: self.active.cursorEntry?.name,
                isDirectory: self.active.cursorEntry?.isDirectory, hasSelection: !self.active.markedEntries.isEmpty)
        }
        workspace.configure(window: window) { [weak self] text in self?.status.stringValue = text }
        let recorded: Set<String> = ["mark", "markAll", "clearMarks", "invertMarks", "invertAll", "invertFiles", "restoreMarks", "sameExtension", "unmarkExtension", "sameName", "unmarkName", "reverseSort", "brief", "full", "custom"]
        func registerMenu(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { registerMenu(submenu) }
                guard item.action == #selector(command(_:)), let id = item.representedObject as? String,
                      workspace.registry.descriptor(for: CommandID(rawValue: "panel." + id)) == nil else { continue }
                workspace.register("panel." + id, title: item.title, contexts: [.panel], recordable: recorded.contains(id)) { [weak self] in
                    guard let self, self.window.isKeyWindow,
                          self.window.attachedSheet == nil else { throw CommandRegistryError.contextMismatch }
                    if recorded.contains(id) && (self.busy || self.active.loading || self.active.isArchive || self.active.isRemote || self.active.contentMode != .files || self.terminalVisible) { throw CommandRegistryError.contextMismatch }
                    let validation = NSMenuItem(title: "", action: #selector(self.command(_:)), keyEquivalent: "")
                    validation.representedObject = id
                    guard ["operations", "cancelOperations", "networkCancel", "archiveCancel"].contains(id) || self.validateMenuItem(validation) else { throw CommandRegistryError.contextMismatch }
                    self.performPanelCommand(id)
                }
            }
        }
        if let menu = NSApp.mainMenu { registerMenu(menu) }
        for function in 1...10 {
            workspace.register("panel.f\(function)", title: "F\(function)", contexts: [.panel]) { [weak self] in
                guard let self else { throw CommandRegistryError.contextMismatch }
                self.performFunctionDirect(function)
            }
        }
        workspace.register("panel.switch", title: "Переключить панель", contexts: [.panel], recordable: true) { [weak self] in
            guard let self, !self.busy, !self.terminalVisible else { throw CommandRegistryError.contextMismatch }
            self.activate(self.passive); self.active.focus()
        }
        for (id, title, delta) in [("panel.down", "Курсор вниз", 1), ("panel.up", "Курсор вверх", -1)] {
            workspace.register(id, title: title, contexts: [.panel], recordable: true) { [weak self] in
                guard let self, !self.busy, !self.active.loading, !self.active.isVirtual, !self.active.isArchive, !self.active.isRemote,
                      self.active.contentMode == .files, !self.terminalVisible else { throw CommandRegistryError.contextMismatch }
                self.active.automationMoveCursor(delta)
            }
        }
        workspace.panelKey = { [weak self] event in
            guard let self, !self.terminalVisible, self.window.firstResponder === self.active.table,
                  !self.active.isVirtual, !self.active.isArchive, !self.active.isRemote, self.active.contentMode == .files else { return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags == [.command], event.keyCode == 0 { return "panel.markAll" }
            if flags == [.control], event.keyCode == 46 { return "panel.restoreMarks" }
            guard flags.isEmpty else { return nil }
            switch event.keyCode {
            case 48: return "panel.switch"
            case 49, 114: return "panel.mark"
            case 125: return "panel.down"
            case 126: return "panel.up"
            default: return nil
            }
        }
        TextFileWindow.registerAutomation(in: workspace)
        ViewerWindow.registerAutomation(in: workspace)
        workspace.register("dialog.help", title: "Справка диалога", contexts: [.dialog]) { [weak self] in self?.help() }
        ExtensionWorkspace.shared.panelEntries = { [weak self] in
            guard let self, !self.active.loading, !self.active.isVirtual, !self.active.isArchive, !self.active.isRemote else { throw CommandRegistryError.contextMismatch }
            return self.active.selectedEntries.map { ExtensionEntry(name: $0.name, isDirectory: $0.isDirectory, size: Int64($0.size)) }
        }
    }

    func performFunction(_ function: Int) {
        if CommandWorkspace.shared.dispatch("panel.f\(function)") { return }
        performFunctionDirect(function)
    }
    private func performFunctionDirect(_ function: Int) {
        guard !busy, window.attachedSheet == nil else { NSSound.beep(); return }
        if terminalVisible && shellWorkspace.isRunning && ![1, 2, 9, 10].contains(function) { NSSound.beep(); return }
        if active.contentMode != .files && [3, 4, 5, 6, 7, 8].contains(function) {
            status.stringValue = "Для файловой операции переключитесь в режим «Файлы»."; NSSound.beep(); return
        }
        if active.isVirtual {
            switch function {
            case 3, 4: if let match = active.cursorVirtualResult { openSearchMatch(match, editable: function == 4) }; return
            case 5: copyVirtualResults(); return
            case 2, 6: NSSound.beep(); return
            case 7, 8: active.removeVirtualSelection(); return
            default: break
            }
        }
        if active.isRemote {
            if passive.isVirtual && [5, 6].contains(function) { NSSound.beep(); return }
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
            case 6: moveArchiveSelection(); return
            case 7: createArchiveDirectory(); return
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
        if CommandWorkspace.shared.dispatch("panel." + id) { return }
        performPanelCommand(id)
    }
    private func performPanelCommand(_ id: String) {
        if active.isVirtual, !virtualPanelCommands.contains(id) { NSSound.beep(); return }
        if active.isArchive || active.isRemote, (filePanelCommands.contains(id) && id != "copyCursor") || ["temporaryAdd", "temporaryRemove", "temporaryLocate", "temporaryImport", "temporaryExport", "alternateExecute", "alternateView", "alternateEdit", "saveSession", "panelSettings", "brief", "full", "custom", "reverseSort"].contains(id) { NSSound.beep(); return }
        if filePanelCommands.contains(id), active.contentMode != .files { NSSound.beep(); return }
        switch id {
        case "networkConnect": network.connect(in: active)
        case "networkDisconnect": if let provider = active.remotePanel?.provider { network.disconnected(provider) }; active.leaveRemote()
        case "networkPath": network.goTo(active)
        case "networkRefresh": network.refresh(active)
        case "networkReconnect": network.reconnect(active)
        case "networkRename": network.rename(active)
        case "networkCancel": network.cancel(); virtualOperations.cancel(); savedPanelRestore.cancel()
        case "networkRetry": network.retryDownload()
        case "networkDiscard": network.discardDownload()
        case "archiveOpen":
            if active.isArchive, let path = active.archivePanel?.cursorPath { openNestedArchive(active, path: path) }
            else if !active.isRemote, let entry = active.cursorEntry, !entry.isDirectory { openArchive(entry.url, in: active) }
        case "archiveClose": active.closeArchiveLevel()
        case "archiveCreate": createArchive()
        case "archiveExtract": extractArchiveSelection()
        case "archiveAdd": addToArchive()
        case "archiveDelete": deleteArchiveSelection()
        case "archiveMove": moveArchiveSelection()
        case "archiveMkdir": createArchiveDirectory()
        case "archiveCancel": archiveOperations.cancel()
        case "fileDescription": editFileDescription()
        case "descriptionPropagation":
            DescriptionPreferences.enabled.toggle()
            status.stringValue = DescriptionPreferences.enabled ? "Описания будут переноситься с файлами в новых локальных заданиях." : "Автоматический перенос описаний отключён для новых заданий."
        case "sortGroups": editSortGroups()
        case "panelFiles": active.setContentMode(.files); active.focus()
        case "panelTree": active.setContentMode(.tree); active.focus()
        case "panelInfo": active.setContentMode(.info); active.focus()
        case "panelQuickView": active.setContentMode(.quickView); active.focus()
        case "compareDirectories": compareDirectories()
        case "temporaryAdd": addToTemporaryPanel()
        case "temporaryRemove": if active.isVirtual { active.removeVirtualSelection() } else { active.removeTemporarySelection() }
        case "temporaryLastMixed": do { try active.showVirtualResults(lastVirtualResults) } catch { showError(error) }
        case "temporaryLocate": locateTemporaryItem()
        case "temporarySlots": persistentTemporaryPanels().showWindow(nil)
        case "temporaryImport": importTemporaryList()
        case "temporaryExport": exportTemporaryList()
        case "alternateExecute": shellWorkspace.alternativeAssociation(action: .alternateExecute)
        case "alternateView": shellWorkspace.alternativeAssociation(action: .alternateView)
        case "alternateEdit": shellWorkspace.alternativeAssociation(action: .alternateEdit)
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
            AppPreferences.defaults.set(value, forKey: "showHidden")
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
            if editable { _ = openDocument(entry.url, editable: true) }
            else {
                let urls = active.visible.filter { !$0.isDirectory && !$0.isSymbolicLink }.map(\.url)
                status.stringValue = "Подготовка просмотра…"
                Task { [weak self] in
                    let navigation = await Task.detached(priority: .userInitiated) { try? ViewerNavigation(urls: urls, currentURL: entry.url) }.value
                    guard let self else { return }
                    _ = self.openDocument(entry.url, editable: false, navigation: navigation)
                    self.status.stringValue = navigation == nil ? "Просмотр без списка соседних файлов." : "Список файлов для просмотра взят из текущего порядка панели."
                }
            }
        }
    }
    @discardableResult
    private func openDocument(_ url: URL, editable: Bool, byteOffset: Int64? = nil, encoding: ViewerEncoding = .automatic, initialDisplayMode: ViewerDisplayMode? = nil, navigation: ViewerNavigation? = nil) -> Bool {
        do {
            if editable {
                if let existing = editors.first(where: {
                    $0.window?.isVisible == true && $0.window?.representedURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
                }) { existing.showWindow(nil); return true }
                let editor = try TextFileWindow(url: url, editable: true, initialByteOffset: byteOffset, encoding: encoding,
                    onView: { [weak self] url, offset, encoding in self?.openDocument(url, editable: false, byteOffset: offset, encoding: encoding) ?? false })
                editors.removeAll { $0.window?.isVisible == false && $0.retainedArchiveWorkspace == nil && $0.retainedRemoteWorkspace == nil }
                editors.append(editor)
                editor.showWindow(nil)
            } else {
                let viewer = try ViewerWindow(url: url, initialByteOffset: byteOffset, initialEncoding: encoding, initialDisplayMode: initialDisplayMode, navigation: navigation,
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
    private func searchLocations(in panel: PanelView) -> [SearchLocation] {
        if let archive = panel.archivePanel { return [.archive(archive.snapshot, prefix: archive.currentDirectory)] }
        if let remote = panel.remotePanel { return [.remote(remote.provider, root: remote.currentPath)] }
        if panel.isVirtual { return [] }
        return [.local(panel.directory)]
    }
    func openSearch() {
        if let searchWindow, searchWindow.window?.isVisible == true || searchWindow.isWorkerRunning {
            searchWindow.showWindow(nil); return
        }
        guard !busy, !toolMutationPending, !operationQueue.hasPendingOperations else { return }
        let sources = searchLocations(in: active)
        searchWindow = SearchWindow(sources: sources.isEmpty ? searchLocations(in: passive) : sources,
            availableSources: { [weak self] in
                guard let self else { return [] }
                return self.searchLocations(in: self.active) + self.searchLocations(in: self.passive)
            }, maskGroups: maskGroups,
            onReveal: { [weak self] match in self?.revealSearchMatch(match) },
            onOpen: { [weak self] match, editable in self?.openSearchMatch(match, editable: editable) },
            onSendToPanel: { [weak self] matches in self?.showSearchMatches(matches) })
        searchWindow?.canStart = { [weak self] in
            guard let self else { return false }
            return !self.busy && !self.toolMutationPending && !self.operationQueue.hasPendingOperations
        }
        searchWindow?.showWindow(nil)
    }
    private func showSearchMatches(_ matches: [SearchMatch]) {
        do {
            if matches.allSatisfy({ if case .local = $0 { return true }; return false }) {
                active.showSearchResults(matches.compactMap { if case .local(let value) = $0 { return value }; return nil })
            } else { try active.showVirtualResults(matches) }
            window.makeKeyAndOrderFront(nil); active.focus()
        } catch { searchActionError(error) }
    }
    private func revealSearchMatch(_ match: SearchMatch) {
        guard !toolMutationPending, !busy else { return }
        switch match {
        case .saved:
            restoreSavedMatches([match]) { [weak self] matches in
                if let match = matches.first { self?.revealSearchMatch(match) }
            }
        case .local(let result): revealSearchResult(result)
        case .archive(let result): revealArchiveSearchResult(result)
        case .remote(let result, let provider):
            let target = active!
            network.revealSearchResult(result, provider: provider, in: target) { [weak self, weak target] in
                guard let self, let target else { return }
                self.activate(target); self.window.makeKeyAndOrderFront(nil); target.focus()
            }
        }
    }
    private func openSearchMatch(_ match: SearchMatch, editable: Bool) {
        guard !toolMutationPending, !busy, !editable || match.canEdit else { return }
        switch match {
        case .saved:
            restoreSavedMatches([match]) { [weak self] matches in
                if let match = matches.first { self?.openSearchMatch(match, editable: editable) }
            }
        case .local(let result): openSearchResult(result, editable: editable)
        case .archive(let result): openArchiveSearchResult(result, editable: editable)
        case .remote(let result, let provider):
            guard result.remoteEntry != nil else { return }
            network.openSearchResult(result, provider: provider, editable: editable)
        }
    }
    /// Resolve only on an explicit action. Partial failures remain visible as offline rows.
    private func restoreSavedMatches(_ matches: [SearchMatch], completion: @escaping ([SearchMatch]) -> Void) {
        guard !busy, !toolMutationPending, !operationQueue.hasPendingOperations else { return }
        let pending = matches.enumerated().compactMap { index, match -> (Int, SavedSearchReference)? in
            if case .saved(let reference) = match { return (index, reference) }; return nil
        }
        guard !pending.isEmpty else { completion(matches); return }
        let target = active!, generation = target.locationGeneration, originalVirtualPanel = target.virtualPanel
        var providers: [any RemoteProvider] = []
        for match in lastVirtualResults + left.virtualResults + right.virtualResults {
            if case .remote(_, let provider) = match, !providers.contains(where: { $0 === provider }) { providers.append(provider) }
        }
        for panel in [left!, right!] {
            if let provider = panel.remotePanel?.provider, !providers.contains(where: { $0 === provider }) { providers.append(provider) }
        }
        savedPanelRestore.restore(pending.map { $0.1 }, availableProviders: providers) { [weak self, weak target] outcome in
            guard let self, let target else { return }
            guard target.locationGeneration == generation else {
                self.status.stringValue = "Панель изменилась. Повторите действие с нужным результатом."
                return
            }
            if let originalVirtualPanel {
                guard target.virtualPanel === originalVirtualPanel,
                      pending.allSatisfy({ item in target.virtualResults.contains { $0.id == item.1.id && (try? SavedSearchReference(capturing: $0)) == item.1 } }) else {
                    self.status.stringValue = "Список результатов изменился. Повторите действие."; return
                }
            }
            do { try target.applyRestoredVirtualMatches(outcome.matches) }
            catch { self.searchActionError(error); return }
            guard !outcome.cancelled else {
                self.status.stringValue = "Восстановление отменено. Ссылки сохранены в панели."; return
            }
            guard outcome.failures.isEmpty else {
                let detail = outcome.failures.prefix(3).map { $0.reference.displayPath + "\n" + $0.message }.joined(separator: "\n\n")
                self.searchActionError(PanelSessionError("Недоступных результатов: \(outcome.failures.count). Ссылки сохранены.\n\n" + detail))
                return
            }
            var resolved = matches
            for (item, restored) in zip(pending, outcome.matches) { resolved[item.0] = restored }
            self.activate(target)
            completion(resolved)
        }
    }

    private func copyVirtualResults(cursorOnly: Bool = false) {
        guard !busy, !toolMutationPending, !operationQueue.hasPendingOperations,
              !passive.isVirtual, !passive.isArchive, !passive.isRemote, !passive.isTemporary else { return }
        let matches = cursorOnly ? active.cursorVirtualResult.map { [$0] } ?? [] : active.selectedVirtualResults
        guard !matches.isEmpty, matches.count <= 100 else {
            inform("Копирование результатов", "Выберите от 1 до 100 объектов."); return
        }
        let destination = passive.directory
        let alert = NSAlert(); alert.messageText = "Копировать выбранные результаты?"
        alert.informativeText = "Объектов: \(matches.count)\nНазначение: \(destination.path)\nАрхивные и сетевые копии: до 256 МиБ суммарно. Конфликты обрабатывает очередь; исходники сохраняются."
        alert.addButton(withTitle: "Копировать"); alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        restoreSavedMatches(matches) { [weak self] resolved in
            self?.prepareVirtualCopies(resolved, destination: destination)
        }
    }
    private func prepareVirtualCopies(_ matches: [SearchMatch], destination: URL) {
        var passwords: [URL: String] = [:]
        for match in matches {
            guard case .archive(let result) = match, let snapshot = result.capturedArchiveSnapshot,
                  snapshot.isEncrypted, passwords[snapshot.sourceURL] == nil else { continue }
            let prompt = NSAlert(); prompt.messageText = "Пароль архива"
            prompt.informativeText = result.archiveDisplayPath ?? snapshot.sourceURL.lastPathComponent
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26)); prompt.accessoryView = field
            prompt.addButton(withTitle: "Продолжить"); prompt.addButton(withTitle: "Отмена")
            guard prompt.runModal() == .alertFirstButtonReturn else { return }; passwords[snapshot.sourceURL] = field.stringValue
        }
        virtualOperations.run(title: "Подготовка результатов к копированию", work: { token, progress in
            try SearchResultCopies.prepare(matches, archivePasswords: passwords, cancellation: token, progress: progress)
        }) { [weak self] outcome in
            guard let self else { return }
            do {
                let copies = try outcome.get()
                // Freeze requests before launching any queue job; same-name items remain distinct jobs.
                let requests = try copies.map { copy -> TransferRequest in
                    if case .local(let result) = copy.original { try result.verifyCurrent() }
                    return TransferRequest(sources: [copy.source], destination: destination, move: false, propagateDescriptions: false)
                }
                var added = 0
                for (request, copy) in zip(requests, copies) {
                    guard self.operationQueue.enqueue(request, retaining: copy) else { break }; added += 1
                }
                self.status.stringValue = "Передано в очередь: \(added) из \(copies.count)."
            } catch { self.showError(error) }
        }
    }
    private func revealArchiveSearchResult(_ result: ProviderSearchResult) {
        do {
            guard let snapshot = result.capturedArchiveSnapshot else { throw PanelSessionError("Архив результата недоступен") }
            try result.verifyArchiveCurrent(snapshot: snapshot)
            active.showArchive(frame: ArchiveNavigationFrame(snapshot: snapshot))
            active.archivePanel?.reveal(path: result.path)
            window.makeKeyAndOrderFront(nil); active.focus()
        } catch { searchActionError(error) }
    }
    private func openArchiveSearchResult(_ result: ProviderSearchResult, editable: Bool) {
        do {
            guard let snapshot = result.capturedArchiveSnapshot else { throw PanelSessionError("Архив результата недоступен") }
            try result.verifyArchiveCurrent(snapshot: snapshot)
            openArchiveMember(snapshot: snapshot, path: result.path, editable: editable, byteOffset: result.byteOffset)
        } catch { searchActionError(error) }
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
                _ = openDocument(result.url, editable: editable, byteOffset: result.byteOffset, initialDisplayMode: result.byteOffset == nil ? nil : .hex)
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
        guard !active.isVirtual, !active.loading else { return }
        let directory = active.directory
        prompt("Новая папка", detail: directory.path, value: "Новая папка", button: "Создать") { [weak self] name in
            self?.runOperation("Создание папки…") { try FileService.createDirectory(named: name, in: directory) }
        }
    }
    func transfer(move: Bool, cursorOnly: Bool = false) {
        if active.isVirtual { if !move { copyVirtualResults(cursorOnly: cursorOnly) }; return }
        if passive.isVirtual { if !move { addToTemporaryPanel() }; return }
        if active.isRemote || passive.isRemote { network.transfer(from: active, to: passive, move: move, cursorOnly: cursorOnly); return }
        if active.isArchive || passive.isArchive {
            if move && active.isArchive { moveArchiveSelection(cursorOnly: cursorOnly); return }
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
            self.operationQueue.enqueue(TransferRequest(sources: sources, destination: destination, move: move, propagateDescriptions: DescriptionPreferences.enabled, descriptionEncodings: DescriptionPreferences.encodings(forSources: sources, destination: destination)))
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
            text = "F3 для папки считает логический размер без обхода символических ссылок; подсчёт можно остановить. F4 открывает свойства: даты доступа/изменения и POSIX-права. Рекурсивные права требуют предпросмотра и отдельного подтверждения; даты меняются только у выбранного объекта. Отмена сохраняет выполненные изменения.\n\nГрупповое переименование использует шаблон {name}, {ext}, {n}. Сначала создайте и проверьте предпросмотр. Изменение шаблона сбрасывает предпросмотр. Существующие имена не перезаписываются; после частичной ошибки завершённые переименования остаются.\n\nЗакройте окно через Cmd+W. Во время записи дождитесь завершения."
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
            text = "SFTP, FTP/FTPS и WebDAV: Enter — папка/просмотр, Tab — соседняя панель, Esc — отключиться. Пробел/Insert — пометки, Cmd+A — отметить всё.\n\nF3 — просмотр, F4 — локальная рабочая копия. Сохранение в редакторе не отправляет файл: нажмите «Сохранить на сервер» в отдельном окне. Удалённая версия проверяется повторно.\n\nF5 — копирование между обычной и сетевой панелями; F6 — перенос обычного файла после проверки копии. F7 — новая папка, F8 — удаление с сервера без Корзины. F8 показывает план рекурсивного удаления для SFTP/FTP; WebDAV-папки этой командой не удаляются. Alt+F7 ищет внутри текущей сетевой папки.\n\nПосле разрыва используйте «Сеть → Продолжить скачивание». WebDAV со строгим ETag продолжает подтверждённую частичную копию; другие серверы начинают загрузку заново. При изменённой версии сбросьте задание. Незавершённое скачивание хранится до сброса или выхода из приложения. F6 между двумя панелями одного SFTP/WebDAV-профиля перемещает выбранные файлы и папки на сервере без замены. Команда «Сеть → Переименовать / переместить на сервере» работает с объектом под курсором. Слияние папок и межсерверная передача пока недоступны."
        } else if active.isArchive {
            title = "Архивная панель"
            text = "ZIP и несжатый TAR. Enter — войти в папку или просмотреть файл, Backspace — выше, Esc — закрыть архив, Tab — соседняя панель. Пробел/Insert — пометка, Cmd+A — отметить всё.\n\nF3 — просмотр, F4 — рабочая копия редактора. Сохранение в редакторе меняет только копию: примените её отдельной кнопкой «Сохранить в архив». F5 извлекает в обычную папку через очередь; F5 с противоположной файловой панели добавляет выбранное в текущую папку архива. F6 перемещает/переименовывает внутри архива без перезаписи конфликтов; F7 создаёт папку. F8 удаляет элементы из архива после подтверждения. Alt+F7 ищет внутри текущей папки архива.\n\nСоздание ZIP/TAR доступно в меню «Архив» на обычной панели. Шифрованные ZIP доступны только для чтения с паролем. Вложенные, многотомные, ZIP64, 7z/RAR и сжатые TAR пока не поддерживаются."
        } else {
            title = "Файловая панель"
            text = "Курсор и пометки независимы. F5/F6/F8 обрабатывают пометки, без пометок — курсор. F3/F4 и Shift+F5/F6 используют только курсор. Для папки F3 считает размер, F4 открывает свойства.\n\nНАВИГАЦИЯ\nTab — другая панель; Enter — открыть; Backspace — выше.\nHome/End/PageUp/PageDown — перемещение; Shift — с пометкой.\nCmd+L — путь, Cmd+[ / Cmd+] — назад/вперёд.\nOption+буквы — быстрый поиск без фильтрации, Ctrl+Enter — следующее совпадение, Ctrl+Shift+Enter — предыдущее, Escape — закрыть поиск.\nCmd+F — фильтр текущей панели; скрываемые файлы теряют пометки.\nOption+F7 или Cmd+Shift+F — рекурсивный поиск файлов. Результаты можно открыть через F3/F4 или отправить во временную панель. Кнопка возврата восстанавливает обычную папку.\nOption+F1/F2 — тома и папки соответствующей панели.\nCtrl+Shift+0…9 — сохранить быструю папку; Ctrl+0…9 — перейти.\n\nПОМЕТКИ\nInsert/Space — переключить пометку и шагнуть вниз.\nShift+стрелки/Home/End/Page — пометить диапазон покидаемых строк.\nCtrl+M — восстановить прошлый набор, повтор — поменять наборы местами.\nNumpad +/− — маска; * — инверсия; Ctrl+* — с папками.\nCtrl+Numpad +/− — то же расширение; Ctrl+Shift+Numpad +/− — то же имя без расширения.\nCmd+A — все объекты, Cmd-щелчок — одна пометка.\n\nМЕНЮ\nCmd+J — очередь и журнал; отмена не откатывает завершённые файлы.\nF9 — все меню команд; меню «Вид» — сортировка, режим и колонки.\nCtrl+T — дерево, Ctrl+L — информация, Ctrl+Q — быстрый просмотр соседнего файла; Esc возвращает файлы. «Панели» — сравнение каталогов, описания и группы сортировки. Во временной панели F7 убирает только ссылку, Ctrl+PageUp открывает исходную папку.\nМеню «История», «Избранное» и «Тома» — переходы; «Панели» — синхронизация путей. Настройки сохраняются между запусками.\n\nF2 — пользовательское меню; «Команды» — настройка меню, ассоциации и истории. Cmd+Enter — строка команд, Tab/Ctrl+Space в строке — дополнить путь, Ctrl+E/X — история. Ctrl+O — панели/PTY; Ctrl+C в терминале — прервать. Shell открывает интерактивную сессию. Простой cd меняет панель, cd внутри shell меняет только сессию. На Mac для F-клавиш может потребоваться Fn."
        }
        contextHelp.present(title: title, text: text)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try temporaryPanelsWindow?.persistLinkedPanel(); try persistentPanelsWindow?.persistLinkedPanel() }
        catch { showError(error); return .terminateCancel }
        if searchWindow?.isProviderSearching == true {
            searchWindow?.cancel(); searchWindow?.showWindow(nil)
            status.stringValue = "Поиск отменяется. Дождитесь очистки временных копий и повторите выход."
            return .terminateCancel
        }
        if savedPanelRestore.isWorking {
            savedPanelRestore.cancel()
            status.stringValue = "Восстановление отменяется. Дождитесь очистки и повторите выход."
            return .terminateCancel
        }
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
        for editor in editors where editor.window?.isVisible == true || editor.retainedArchiveWorkspace != nil || editor.retainedRemoteWorkspace != nil {
            if let window = editor.window, editor.windowShouldClose(window) == false { return .terminateCancel }
        }
        for session in archiveEdits where session.window?.isVisible == true {
            if !session.confirmClose() { return .terminateCancel }
        }
        if !network.confirmTermination() { return .terminateCancel }
        CommandWorkspace.shared.stopPlayback()
        ExtensionWorkspace.shared.cancel()
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
        if window != nil { refreshAfterWake = true; refreshLocalPanelsIfIdle() }
    }

    private var interfacePreferences: UIPreferencesWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshAfterWake = false

    @objc private func showInterfacePreferences(_ sender: Any?) {
        if interfacePreferences?.window?.isVisible != true {
            interfacePreferences = UIPreferencesWindow { [weak self] in self?.applyInterfacePreferences() }
        }
        interfacePreferences?.showWindow(nil)
        interfacePreferences?.window?.makeKeyAndOrderFront(nil)
    }
    private func applyInterfacePreferences() {
        if let menu = NSApp.mainMenu { UIAccessibility.apply(menu: menu) }
        for window in NSApp.windows {
            window.backgroundColor = Palette.background
            if let view = window.contentView { UIAccessibility.apply(to: view) }
        }
        window?.subtitle = L10n.text("Файловый менеджер")
        left?.applyInterfacePreferences(); right?.applyInterfacePreferences()
        shellWorkspace?.applyInterfacePreferences()
    }
    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.workspaceChanged(note) }
            })
        }
    }
    private func workspaceChanged(_ notification: Notification) {
        guard !AppRuntime.isSmoke else { return }
        if notification.name == NSWorkspace.willSleepNotification {
            left.persistSession(); right.persistSession()
            left.cancelInspection(); right.cancelInspection()
            CommandWorkspace.shared.stopPlayback(); ExtensionWorkspace.shared.cancel()
            refreshAfterWake = true
            return
        }
        if notification.name == NSWorkspace.didUnmountNotification,
           let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            left.invalidateUnavailableVolume(volume); right.invalidateUnavailableVolume(volume)
        }
        // Never reconnect a network provider or replay a failed write merely because macOS woke.
        refreshAfterWake = true
        refreshLocalPanelsIfIdle()
    }
    private func refreshLocalPanelsIfIdle() {
        guard refreshAfterWake, !busy, !toolMutationPending, !operationQueue.hasPendingOperations else { return }
        refreshAfterWake = false
        for panel in [left!, right!] where !panel.isVirtual && !panel.isArchive && !panel.isRemote {
            if FileManager.default.isReadableFile(atPath: panel.directory.path) { panel.refresh() }
            else { panel.invalidateUnavailableVolume(panel.directory) }
        }
    }
    private func runUISmoke() async {
        var checks: [String] = []
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks.append(message)
        }
        do {
            let deadline = Date().addingTimeInterval(20)
            while (left.loading || right.loading) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(!left.loading && !right.loading, "Both panels finish loading")
            try require(left.directory == AppRuntime.smokeDirectory && right.directory == AppRuntime.smokeDirectory, "Panels use isolated fixtures")
            try require(left.table.numberOfRows == 3 && right.table.numberOfRows == 3, "Real table views contain the expected files")
            try require(window.contentView != nil && NSApp.mainMenu != nil, "Main window and command menu constructed")
            try require(CommandWorkspace.shared.registry.descriptor(for: "panel.markAll") != nil, "Stable commands registered")
            try require(left.table.accessibilityLabel()?.isEmpty == false, "Panel has an accessibility label")
            let beforeNames = left.entries.map(\.name)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(left)
            let popups = views.compactMap { $0 as? NSPopUpButton }
            let popupState = popups.map { ($0.numberOfItems, $0.indexOfSelectedItem) }
            let imageButtons = views.compactMap { $0 as? NSButton }.filter { $0.imagePosition == .imageOnly }
            let imageState = imageButtons.map { ($0.title, $0.imagePosition, $0.font) }
            let searchCell = left.filterField.cell as? NSSearchFieldCell
            let searchTitle = searchCell?.searchButtonCell?.title
            let cancelTitle = searchCell?.cancelButtonCell?.title
            L10n.language = .english; UIPreferences.fontScale = 1.25; UIPreferences.highContrast = true
            applyInterfacePreferences()
            try require(NSApp.mainMenu?.items.contains(where: { $0.title == "Files" }) == true, "English main menu applied")
            let scaledHeight = left.table.rowHeight
            applyInterfacePreferences()
            try require(left.table.rowHeight == scaledHeight && scaledHeight > 29, "Text scaling is idempotent")
            try require(zip(popups, popupState).allSatisfy { $0.numberOfItems == $1.0 && $0.indexOfSelectedItem == $1.1 }, "Localization preserves popup items and selection")
            try require(zip(imageButtons, imageState).allSatisfy { $0.title == $1.0 && $0.imagePosition == $1.1 && $0.font == $1.2 }, "Image-only buttons retain native presentation")
            try require(searchCell?.searchButtonCell?.title == searchTitle && searchCell?.cancelButtonCell?.title == cancelTitle, "Search field internal buttons remain unchanged")
            try require(left.entries.map(\.name) == beforeNames, "Localization preserves filenames")
            if let index = left.entries.firstIndex(where: { $0.name == "Имя" }),
               let cell = left.table.view(atColumn: 0, row: index + 1, makeIfNecessary: true) as? NSTableCellView {
                try require(cell.textField?.stringValue == "Имя", "Filename matching UI vocabulary remains literal")
            } else { throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing filename localization fixture"]) }
            L10n.language = .russian; UIPreferences.fontScale = 1; UIPreferences.highContrast = false
            applyInterfacePreferences()
            try require(NSApp.mainMenu?.items.contains(where: { $0.title == "Файлы" }) == true, "Russian main menu restored")
            activate(left); window.makeKeyAndOrderFront(nil); left.focus()
            try CommandWorkspace.shared.macros.startRecording()
            try CommandWorkspace.shared.macros.execute("panel.markAll", in: .panel)
            let macro = try CommandWorkspace.shared.macros.stopRecording(name: "smoke")
            try require(macro.steps.count == 1 && left.markedEntries.count == 2, "Panel command records and updates marks")
            left.clearMarks()
            try await CommandWorkspace.shared.macros.play(macro)
            try require(left.markedEntries.count == 2, "Macro playback updates real panel marks")
            left.invalidateUnavailableVolume(left.directory)
            try require(left.selectedEntries.isEmpty && left.entries.isEmpty, "Unavailable volume invalidates stale entries")
            left.refresh()
            let recoveryDeadline = Date().addingTimeInterval(5)
            while left.loading && Date() < recoveryDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(left.entries.count == 2, "Panel recovers after resource returns")
            left.persistSession()
            try require(AppPreferences.defaults.data(forKey: "panel.left.session") != nil, "Session persists in isolated defaults")
            let listData = try TemporaryPanelList.encode(left.entries.map(\.url))
            let listURLs = try TemporaryPanelList.decode(listData, format: .json, relativeTo: left.directory)
            let snapshots = try listURLs.map { try SearchResult.capture($0) }
            try left.addTemporaryItems(snapshots)
            try require(left.isTemporary && left.temporaryResults.count == 2 && left.table.numberOfRows == 2, "Imported path list creates real temporary panel rows")
            try left.addTemporaryItems(snapshots)
            let exportedPaths = try TemporaryPanelList.decode(TemporaryPanelList.encode(left.temporaryResults.map(\.url)), format: .json, relativeTo: left.directory)
            try require(left.temporaryResults.count == 2 && exportedPaths.count == 2, "Temporary export preserves paths and duplicate import keeps original snapshots")
            checks += try await FilePropertiesWindow.runUISmokeChecks()
            checks += try await BatchRenameWindow.verifyFARRenameUI()
            checks += try await PanelView.runColumnLayoutUISmokeChecks()
            checks += try await FileOperationQueue.runDescriptionQueueUISmokeChecks()
            checks += try await FileDescriptionWindow.runUISmokeChecks()
            let commonPanels = commonTemporaryPanels()
            commonPanels.updateLinkedSlot(0, items: snapshots)
            activate(left); commonPanels.openSlot(0)
            activate(right); commonPanels.openSlot(0)
            let sharedLoadDeadline = Date().addingTimeInterval(5)
            while (left.loading || right.loading) && Date() < sharedLoadDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(!left.loading && !right.loading && left.temporaryResults.count == 2 && right.temporaryResults.count == 2,
                        "Both shared common panels finish validating the original snapshots")
            activate(left); left.focus(); left.markAll()
            try require(left.markedEntries.count == 2, "Common panel marks are applied after snapshot validation")
            left.removeTemporarySelection()
            let sharedSyncDeadline = Date().addingTimeInterval(5)
            while (left.loading || right.loading) && Date() < sharedSyncDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(!left.loading && !right.loading && left.temporaryResults.isEmpty && right.temporaryResults.isEmpty,
                        "Two panels sharing a common slot synchronize removals without restoring stale links")
            try require(active === left, "Synchronizing the passive common panel preserves the active panel and focus")
            commonPanels.openSlot(9)
            activate(right); commonPanels.openSlot(8)
            activate(left); commonPanels.openSlot(0)
            let sharedReopenDeadline = Date().addingTimeInterval(5)
            while (left.loading || right.loading) && Date() < sharedReopenDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try require(!left.loading && !right.loading && left.temporaryResults.isEmpty,
                        "Switching both former shared views and reopening the slot does not resurrect removed references")
            activate(left)
            checks += try TemporaryPanelsWindow.runUISmokeChecks()
            checks += try PersistentTemporaryPanelsWindow.runUISmokeChecks()
            checks += try await SavedPanelRestoreController.runUISmokeChecks()
            checks += try await runPersistentPanelsHostUISmokeChecks()
            checks += try SearchWindow.runSearchOptionsUISmokeChecks()
            checks += try await SearchWindow.runProviderSearchUISmokeChecks()
            checks += try await SearchWindow.runHexSearchUISmokeChecks()
            checks += try await SearchWindow.runArchiveTraversalUISmokeChecks()
            checks += try await SearchWindow.runMultiSourceUISmokeChecks()
            checks += try PanelView.runVirtualResultsUISmokeChecks()
            checks += try await runMixedResultsHostUISmokeChecks()
            checks += try await ArchiveOperationController.runArchiveMutationUISmokeChecks()
            checks += try await runArchiveNavigationUISmokeChecks()
            checks += try NetworkCoordinator.runProviderOperationUISmokeChecks()
            checks += try NetworkCoordinator.runDirectoryTransferUISmokeChecks()
            checks += try NetworkConflictEditor.runUISmokeChecks()
            checks += try await NetworkCoordinator.runDirectoryMoveUISmokeChecks()
            checks += try PanelView.runNetworkLifecycleUISmokeChecks()
            checks += try UserCommandsWindow.runUserCommandUISmokeChecks()
            checks += try CommandWorkspace.runUISmokeChecks()
            checks += try TextFileWindow.runEditingUISmokeChecks()
            checks += try await ViewerWindow.runViewerUISmokeChecks()
            checks += try await ViewerWindow.runViewerFuzzyUISmokeChecks()
            checks += try await WorkingCopyViewerSession.runWorkingCopyUISmokeChecks()
            checks += try NetworkConnectionWindow.runUISmokeChecks()
            checks += try TerminalRenderer.runUISmokeChecks()
            checks += try MacroShortcutAdapter.runUISmokeChecks()
            checks += try ExtensionWorkspace.runUISmokeChecks()
            checks += try await ShellWorkspace.runUISmokeChecks()
            shellWorkspace.stopForExit()
            AppRuntime.finishSmoke(checks: checks)
        } catch { shellWorkspace?.stopForExit(); AppRuntime.finishSmoke(checks: checks, error: error.localizedDescription) }
    }

    private func runPersistentPanelsHostUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let base = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Missing smoke scope") }
        let folder = base.appendingPathComponent("saved-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("local.txt"); try Data("saved original".utf8).write(to: file)
        let original = active!, previous = lastVirtualResults
        let provider = ProviderUISmokeFixture()
        savedPanelRestore.showsProgressWindow = false
        defer {
            savedPanelRestore.showsProgressWindow = true
            left.leaveVirtualResults(focus: false); right.leaveVirtualResults(focus: false)
            activate(original); lastVirtualResults = previous
            persistentTemporaryPanels().persistLastMixed(previous)
            try? FileManager.default.removeItem(at: folder)
        }
        var matches: [SearchMatch] = [.local(try SearchResult.capture(file))]
        var options = SearchOptions(roots: [folder]); options.namePattern = "alpha.txt"
        _ = ProviderSearchEngine.runRemote(provider: provider, root: "/docs", request: SearchRequest(options: options), cancellation: ProviderSearchCancellation()) {
            if case .result(let result) = $0 { matches.append(.remote(result, provider)) }
        }
        guard matches.count == 2 else { throw PanelSessionError("Saved host fixture missing") }
        let library = persistentTemporaryPanels()
        library.updateLinkedSlot(7, items: matches)
        activate(left); library.openSlot(7)
        activate(right); library.openSlot(7)
        guard [left!, right!].allSatisfy({ $0.virtualLibrarySlot == 7 && $0.virtualResults.count == 2 && $0.virtualResults.allSatisfy({ if case .saved = $0 { return true }; return false }) }), provider.downloads == 0 else {
            throw PanelSessionError("Host shared slots did not open offline")
        }
        activate(left); window.makeKeyAndOrderFront(nil); left.focus()
        let menu = menuCommand("Общие временные панели · 0–9", "temporarySlots")
        guard validateMenuItem(menu) else { throw PanelSessionError("Common slot menu unavailable on a virtual panel") }
        // Supply a real session provider; restore must match it exactly and avoid credentials.
        lastVirtualResults = matches
        var restored: [SearchMatch]?
        restoreSavedMatches(left.virtualResults) { restored = $0 }
        let deadline = Date().addingTimeInterval(5)
        while savedPanelRestore.isWorking && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard let restored, restored.count == 2, restored.allSatisfy({ if case .saved = $0 { return false }; return true }),
              left.virtualResults.allSatisfy({ if case .saved = $0 { return false }; return true }),
              left.virtualLibrarySlot == 7 else { throw PanelSessionError("Host explicit restore failed or lost shared slot") }
        let copies = try SearchResultCopies.prepare(restored)
        guard copies.count == 2, provider.downloads == 1 else { throw PanelSessionError("Restored results did not enter normal copy staging") }
        left.markAll(); left.removeVirtualSelection()
        guard left.virtualResults.isEmpty, right.virtualResults.isEmpty else { throw PanelSessionError("Host mixed common slot removal did not synchronize") }
        let disk = try PersistentTemporaryPanelsStore(url: base.appendingPathComponent("mixed-common/mixed-panels.json")).load()
        guard disk.slots[7].isEmpty, disk.lastMixed.isEmpty, FileManager.default.fileExists(atPath: file.path) else {
            throw PanelSessionError("Host removal did not persist or removed source")
        }
        // Startup uses exactly this offline decode; reopening retains type and original stamps.
        library.persistLastMixed(matches)
        let restart = try PersistentTemporaryPanelsStore(url: base.appendingPathComponent("mixed-common/mixed-panels.json")).load()
        lastVirtualResults = restart.lastMixed.map(SearchMatch.saved)
        try left.showVirtualResults(lastVirtualResults)
        guard left.virtualResults.count == 2, left.virtualLibrarySlot == nil, provider.downloads == 1 else {
            throw PanelSessionError("Last mixed list failed offline restart recreation")
        }
        guard let localReference = restart.lastMixed.first(where: { if case .local = $0 { return true }; return false }) else {
            throw PanelSessionError("Missing saved local fixture")
        }
        var removedActionRan = false
        restoreSavedMatches([.saved(localReference)]) { _ in removedActionRan = true }
        left.markAll(); left.removeVirtualSelection()
        let removalDeadline = Date().addingTimeInterval(5)
        while savedPanelRestore.isWorking && Date() < removalDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !savedPanelRestore.isWorking, !removedActionRan, left.virtualResults.isEmpty,
              FileManager.default.fileExists(atPath: file.path) else {
            throw PanelSessionError("Pending saved action acted after its reference was removed")
        }
        return ["Host common-slot menu works on virtual panels; both panes open persisted mixed references offline",
                "Host explicit restore reuses exact live provider, upgrades rows and stages F5 copies",
                "Host shared removals persist without touching originals; last mixed panel recreates offline after store reload",
                "Removing a saved reference during restoration prevents the deferred action"]
    }

    private func runMixedResultsHostUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let base = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Missing smoke scope") }
        let original = active!, previous = lastVirtualResults
        let folder = base.appendingPathComponent("mixed-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { left.leaveVirtualResults(focus: false); left.leaveRemote(focus: false); lastVirtualResults = previous; activate(original); try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("local.txt"); try Data("local".utf8).write(to: file)
        let provider = ProviderUISmokeFixture()
        var options = SearchOptions(roots: [folder]); options.namePattern = "*.txt"; options.kinds = [.file]
        var matches: [SearchMatch] = []
        _ = MultiSourceSearchEngine.run(locations: [.local(folder), .remote(provider, root: "/docs")],
            request: SearchRequest(options: options), cancellation: ProviderSearchCancellation()) {
                if case .match(let match) = $0 { matches.append(match) }
            }
        guard matches.count == 3, let remote = matches.first(where: { if case .remote = $0 { return true }; return false }) else { throw PanelSessionError("Host mixed fixtures missing") }
        activate(left); showSearchMatches(matches); window.makeKeyAndOrderFront(nil); left.focus()
        let moveMenu = NSMenuItem(title: "Move", action: #selector(functionMenu(_:)), keyEquivalent: ""); moveMenu.tag = 6
        guard left.isVirtual, left.cursorEntry == nil, left.selectedEntries.isEmpty,
              !validateMenuItem(moveMenu), lastVirtualResults.count == 3 else { throw PanelSessionError("Host mixed panel exposed local operations or lost session history") }
        revealSearchMatch(remote)
        let deadline = Date().addingTimeInterval(5)
        while network.isWorking && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard left.remotePanel?.provider === provider, left.remotePanel?.cursor?.path == "/docs/alpha.txt" else {
            throw PanelSessionError("Host Enter did not restore captured remote provider")
        }
        try left.showVirtualResults(lastVirtualResults)
        openSearchMatch(remote, editable: false)
        let viewDeadline = Date().addingTimeInterval(5)
        while network.isWorking && Date() < viewDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard provider.downloads > 0 else { throw PanelSessionError("Host F3 did not read captured remote result") }
        window.makeKeyAndOrderFront(nil); left.focus(); left.markAll(); performFunctionDirect(8)
        guard left.virtualResults.isEmpty, lastVirtualResults.isEmpty, FileManager.default.fileExists(atPath: file.path),
              try provider.stat(path: "/docs/alpha.txt", cancellation: TransferCancellation()) != nil else {
            throw PanelSessionError("Host F8 changed source files or resurrected removed references")
        }
        return ["Mixed host panel hides underlying local paths and disables move; session history retains typed references",
                "Mixed host Enter and F3 restore and read the captured network provider",
                "Mixed host F8 removes references and session history while preserving local and remote originals"]
    }

    private func runArchiveNavigationUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let base = AppRuntime.smokeStateDirectory else { throw ArchiveError.io("Missing isolated smoke directory") }
        let folder = base.appendingPathComponent("nested-panel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let originalActive = active!
        defer { left.leaveArchive(); activate(originalActive); try? FileManager.default.removeItem(at: folder) }
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw ArchiveError.io(message) } }
        let payload = Data([0, 255, 1, 128, 42])
        let file = folder.appendingPathComponent("payload.bin"); try payload.write(to: file)
        let nestedFolder = folder.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: false)
        try Data("marked sibling".utf8).write(to: nestedFolder.appendingPathComponent("sibling.txt"))
        let inner = try ArchiveWriter.create(sources: [file, nestedFolder], destination: folder.appendingPathComponent("inner.tar.gz"), format: .tarGzip)
        try FileManager.default.copyItem(at: inner.sourceURL, to: nestedFolder.appendingPathComponent("inner.tar.gz"))
        let outer = try ArchiveWriter.create(sources: [nestedFolder], destination: folder.appendingPathComponent("outer.zip"), format: .zip)
        let root = ArchiveNavigationFrame(snapshot: outer)
        activate(left); left.showArchive(frame: root); left.archivePanel?.reveal(path: "archives/inner.tar.gz")
        left.archivePanel?.restoreNavigationState(.init(directory: "archives", cursor: "archives/inner.tar.gz", marks: ["archives/sibling.txt"], cursors: ["archives": "archives/inner.tar.gz"]))
        window.makeKeyAndOrderFront(nil); left.focus()
        try require(archiveFunctionButtons[6]?.isEnabled == true && folderFunctionButton?.isEnabled == true, "Writable archive enables F6/F7 function buttons")
        left.archivePanel?.openSelection()
        let deadline = Date().addingTimeInterval(5)
        while archiveOperations.isWorking && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let child = left.archiveFrame, child.parent === root else { throw ArchiveError.io("Enter did not open nested archive through host controller") }
        window.makeKeyAndOrderFront(nil); left.focus()
        try require(left.archivePanel?.currentDirectory == "" && left.archivePanel?.captureNavigationState().marks.isEmpty == true, "Nested child starts at root without inheriting parent marks")
        try require(child.snapshot.isReadOnly && left.pathField.stringValue.contains("outer.zip !/archives/inner.tar.gz"), "Nested frame shows parent chain and is read-only")
        let searchSource = ProviderSearchSource.archive(child.snapshot, prefix: "")
        try require(!searchSource.canEdit && searchSource.caption.contains("outer.zip !/archives/inner.tar.gz"), "Nested search retains provenance and disables editing")
        try require(archiveFunctionButtons[4]?.isEnabled == false && archiveFunctionButtons[6]?.isEnabled == false && archiveFunctionButtons[8]?.isEnabled == false && folderFunctionButton?.isEnabled == false, "Nested archive disables F4/F6/F7/F8")
        for id in ["archiveDelete", "archiveMove", "archiveMkdir"] {
            let item = menuCommand(id, id)
            try require(!validateMenuItem(item), "Nested archive mutation menu is disabled")
        }
        left.closeArchiveLevel()
        try require(left.archiveFrame === root && left.archivePanel?.cursorPath == "archives/inner.tar.gz" && left.archivePanel?.currentDirectory == "archives" && left.archivePanel?.selectedArchivePaths == ["archives/sibling.txt"], "Closing nested archive restores parent directory, cursor and marks")
        left.leaveArchive()
        let extracted = try ArchiveReader.extract(child.snapshot)
        defer { extracted.cleanup() }
        try require(try Data(contentsOf: extracted.url(for: "payload.bin")) == payload, "Retained nested result stays readable after panel exit")
        let viewer = try ViewerWindow(url: extracted.url(for: "payload.bin"), onEdit: { _, _, _ in false })
        viewer.retainedArchiveWorkspace = extracted
        viewer.showWorkingCopyLocation(child.displayPath + " !/payload.bin")
        try require(viewer.window?.subtitle == child.displayPath + " !/payload.bin", "Nested viewer identifies its archive location")
        viewer.close()
        var searchOptions = SearchOptions(roots: [folder])
        searchOptions.namePattern = "payload.bin"
        searchOptions.searchNestedArchives = true
        var archiveMatches: [ProviderSearchResult] = []
        _ = ProviderSearchEngine.runArchive(outer, request: SearchRequest(options: searchOptions), cancellation: ProviderSearchCancellation()) { event in
            if case .result(let result) = event { archiveMatches.append(result) }
        }
        guard let found = archiveMatches.first(where: { $0.capturedArchiveSnapshot?.isReadOnly == true }) else {
            throw ArchiveError.io("Nested search result missing in host smoke")
        }
        revealArchiveSearchResult(found)
        try require(left.archivePanel?.cursorPath == "payload.bin" && left.archiveFrame?.parent != nil,
                    "Search Enter restores actual nested frame and selects member")
        let previousViewerCount = viewers.filter { $0.window?.isVisible != false }.count
        openArchiveSearchResult(found, editable: false)
        let searchOpenDeadline = Date().addingTimeInterval(5)
        while archiveOperations.isWorking && Date() < searchOpenDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(viewers.count == previousViewerCount + 1 && viewers.last?.window?.subtitle.contains("outer.zip !/archives/inner.tar.gz !/payload.bin") == true,
                    "Search F3 opens actual retained nested working copy with full location")
        viewers.last?.close(); viewers.removeLast()
        left.leaveArchive()
        try Data("changed parent".utf8).write(to: outer.sourceURL)
        do { try child.verifyCurrent(); throw ArchiveError.io("Changed outer archive was accepted") }
        catch ArchiveError.changedArchive { }
        let picker = archiveFormatPicker()
        try require(picker.itemTitles == ArchiveFormat.allCases.map(\.displayName), "Creation picker exposes every verified compression format")
        return ["Enter opens nested compressed archive through controller and displays its parent chain",
                "Nested archives disable write commands; writable roots expose F6/F7 buttons",
                "Closing nested frame restores parent directory, cursor and marks; retained snapshot survives panel exit and rejects changed ancestor",
                "Archive creation picker offers ZIP, TAR, TAR.GZ, TAR.BZ2 and TAR.XZ",
                "Search Enter restores nested panel; F3 opens actual nested member through host controller"]
    }

    func setupMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem(); bar.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "О FarForMac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let preferences = NSMenuItem(title: "Доступность и язык…", action: #selector(showInterfacePreferences(_:)), keyEquivalent: ",")
        preferences.target = self; appMenu.addItem(preferences)
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
        files.addItem(menuCommand("Переносить описания вместе с файлами", "descriptionPropagation"))
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
        for (title, id) in [("Альтернативное открытие…", "alternateExecute"), ("Альтернативный просмотр…", "alternateView"), ("Альтернативное редактирование…", "alternateEdit")] {
            commands.addItem(menuCommand(title, id))
        }
        let navigation = submenu("Панели")
        navigation.addItem(menuCommand("Общие временные панели · 0–9", "temporarySlots"))
        navigation.addItem(menuCommand("Последняя смешанная панель", "temporaryLastMixed"))
        navigation.addItem(menuCommand("Импорт списка во временную панель…", "temporaryImport"))
        navigation.addItem(menuCommand("Экспорт списка путей…", "temporaryExport"))
        for (name, id, key) in [("Описание файла…", "fileDescription", ""), ("Группы сортировки…", "sortGroups", ""), ("Файловая панель", "panelFiles", ""), ("Дерево каталогов · Ctrl+T", "panelTree", ""), ("Информационная панель · Ctrl+L", "panelInfo", ""), ("Быстрый просмотр · Ctrl+Q", "panelQuickView", ""), ("Сравнить каталоги…", "compareDirectories", ""), ("Добавить выбранное во временную соседнюю панель", "temporaryAdd", ""), ("Убрать из временной панели (без удаления файлов)", "temporaryRemove", ""), ("Перейти к исходной папке", "temporaryLocate", ""), ("Сохранить сессию панелей", "saveSession", ""), ("Перейти к пути…", "path", "l"), ("Выбрать папку…", "choose", "o"), ("Назад", "back", "["), ("Вперёд", "forward", "]"), ("Быстрый поиск по имени", "quickFind", ""), ("Следующее совпадение", "findNext", ""), ("Предыдущее совпадение", "findPrevious", ""), ("Фильтр текущей папки", "filter", "f"), ("Обновить", "refresh", "r"), ("Показать / скрыть скрытые файлы", "hidden", "."), ("Открыть этот путь в соседней панели", "syncToOther", ""), ("Взять путь соседней панели", "syncFromOther", ""), ("Настройки активной панели…", "panelSettings", ""), ("Открыть Терминал здесь", "terminal", "t"), ("Показать в Finder", "reveal", "")] {
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
        for (title, id) in [("Подключиться…", "networkConnect"), ("Отключиться", "networkDisconnect"), ("Удалённая папка…", "networkPath"), ("Обновить", "networkRefresh"), ("Установить новое SSH-соединение", "networkReconnect"), ("Переименовать / переместить на сервере…", "networkRename"), ("Отменить сетевую операцию", "networkCancel"), ("Продолжить скачивание", "networkRetry"), ("Сбросить незавершённое скачивание", "networkDiscard")] { networks.addItem(menuCommand(title, id)) }
        let archives = submenu("Архив")
        for (title, id) in [("Открыть как архив · Ctrl+PageDown", "archiveOpen"), ("Закрыть архив", "archiveClose"), ("Создать ZIP / TAR со сжатием…", "archiveCreate"), ("Извлечь выбранное…", "archiveExtract"), ("Добавить выбранное в соседний архив…", "archiveAdd"), ("Удалить выбранное из архива…", "archiveDelete"), ("Переместить / переименовать внутри архива · F6", "archiveMove"), ("Новая папка внутри архива · F7", "archiveMkdir"), ("Отменить архивную операцию", "archiveCancel")] { archives.addItem(menuCommand(title, id)) }
        NSApp.windowsMenu = windows
        CommandWorkspace.shared.installMenu(in: bar)
        ExtensionWorkspace.shared.installMenu(in: bar)
        NSApp.mainMenu = bar
    }
}

@main
enum FarForMacMain {
    @MainActor static func main() {
        do { try AppRuntime.configure() } catch { fputs("\(error.localizedDescription)\n", stderr); exit(2) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
