import AppKit
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
    private var keyMonitor: Any?
    private var busy = false
    var settingsWindow: PanelSettingsWindow?
    var groupsWindow: MaskGroupsWindow?
    private var searchWindow: SearchWindow?
    private var toolWindows: [NSWindowController] = []
    private var toolMutationPending: Bool {
        toolWindows.contains { ($0 as? FileToolsWindowController)?.hasPendingMutation == true }
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
        for panel in [left!, right!] {
            panel.showHidden = defaults.bool(forKey: "showHidden")
            panel.maskGroups = maskGroups
            panel.onFocus = { [weak self] pane in self?.activate(pane) }
            panel.onError = { [weak self] error in self?.showError(error) }
            panel.onFileOpen = { entry in NSWorkspace.shared.open(entry.url) }
            panel.onKey = { [weak self] event in self?.panelKey(event) ?? false }
        }
        let panels = horizontal([left, right], spacing: 10)
        panels.distribution = .fillEqually
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        left.heightAnchor.constraint(equalTo: panels.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: panels.heightAnchor).isActive = true
        let panelsWrapper = inset(panels, x: 14, y: 0)
        panelsWrapper.setContentHuggingPriority(.defaultLow, for: .vertical)

        let hints = horizontal([status, NSView(), label("Space  пометка    Tab  панель    ⌘L  путь    ⌘F  фильтр", size: 11, color: Palette.muted)])
        let statusBar = inset(hints, x: 18, y: 11)
        let actions = horizontal([], spacing: 5)
        let names = ["Помощь", "Действия", "Просмотр", "Правка", "Копия", "Перенос", "Папка", "Корзина", "Меню", "Выход"]
        for (index, title) in names.enumerated() {
            let button = NSButton(title: "F\(index + 1)  \(title)", target: self, action: #selector(functionButton(_:)))
            button.tag = index + 1
            button.bezelStyle = .recessed
            button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = index == 4 ? Palette.accent : Palette.text
            button.toolTip = "F\(index + 1) — \(title). На Mac может потребоваться Fn."
            actions.addArrangedSubview(button)
        }
        actions.distribution = .fillEqually
        let footer = inset(actions, x: 12, y: 10, color: Palette.raised)
        window.contentView = vertical([toolbar, panelsWrapper, statusBar, footer])
        activate(left)
        left.load()
        right.load()
        window.makeKeyAndOrderFront(nil)
        left.focus()
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow != nil else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 122 && flags.intersection([.command, .control, .option, .shift]).isEmpty {
                self.help(); return nil
            }
            guard self.window.isKeyWindow, self.window.attachedSheet == nil else { return event }
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

    func activate(_ panel: PanelView) {
        active = panel
        left.active = panel === left
        right.active = panel === right
    }
    func panelKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
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
    @objc func selectAllInContext(_ sender: Any?) {
        NSApp.keyWindow?.firstResponder?.selectAll(sender)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(functionMenu(_:)) && menuItem.tag == 1 { return true }
        if menuItem.action == #selector(selectAllInContext(_:)) {
            return NSApp.keyWindow?.firstResponder is FileTable || NSApp.keyWindow?.firstResponder is NSTextView
        }
        guard window != nil && window.isKeyWindow && window.attachedSheet == nil && !busy else { return false }
        if menuItem.representedObject as? String == "back" { return active.canGoBack }
        if menuItem.representedObject as? String == "forward" { return active.canGoForward }
        if menuItem.representedObject as? String == "leaveResults" { return active.isTemporary }
        return true
    }

    func performFunction(_ function: Int) {
        guard !busy, window.attachedSheet == nil else { NSSound.beep(); return }
        switch function {
        case 1: help()
        case 2:
            if let menu = NSApp.mainMenu?.item(withTitle: "Панели")?.submenu {
                menu.popUp(positioning: nil, at: NSPoint(x: 18, y: window.contentView!.bounds.height - 10), in: window.contentView)
            }
        case 3: openText(editable: false)
        case 4: openText(editable: true)
        case 5: transfer(move: false)
        case 6: transfer(move: true)
        case 7: makeDirectory()
        case 8: trash()
        case 9: showCommandMenu()
        case 10: NSApp.terminate(nil)
        default: break
        }
    }

    @objc func command(_ sender: Any) {
        guard window != nil, window.isKeyWindow, window.attachedSheet == nil else { return }
        let id = (sender as? NSButton)?.identifier?.rawValue ?? (sender as? NSMenuItem)?.representedObject as? String ?? ""
        switch id {
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
        case "path": active.focusPath()
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
    func refresh() { left.load(); right.load() }
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
        do {
            let editor = try TextFileWindow(url: entry.url, editable: editable)
            editors.removeAll { $0.window?.isVisible == false }
            editors.append(editor)
            editor.showWindow(nil)
        } catch { showError(error) }
    }
    func openSearch() {
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
            if result.isDirectory && !result.isSymbolicLink {
                if editable {
                    retainTool(FilePropertiesWindow(url: result.url, canMutate: { [weak self] in self?.canUseFileTools() ?? false }, onComplete: { [weak self] in self?.refresh() }))
                } else { retainTool(DirectorySizeWindow(url: result.url)) }
            } else {
                let editor = try TextFileWindow(url: result.url, editable: editable)
                editors.removeAll { $0.window?.isVisible == false }
                editors.append(editor)
                editor.showWindow(nil)
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
        if let searchWindow, key === searchWindow.window || key?.sheetParent === searchWindow.window {
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
        } else if let key, editors.contains(where: { $0.window === key }) {
            title = key.title.contains("Редактор") ? "Редактор" : "Просмотрщик"
            text = "Просмотр и редактирование обычного текста UTF-8 до 8 МиБ.\n\nCmd+A — выделить весь текст, Cmd+C — копировать, Cmd+F и расширенный поиск пока не реализованы. В редакторе: Cmd+S — сохранить, Cmd+Z — отменить правку. Escape или Cmd+W закрывает окно; несохранённые изменения требуют решения.\n\nЕсли файл изменён другой программой, сохранение отклоняется и буфер остаётся в окне. Для других форматов используйте Enter на файловой панели."
        } else if window.attachedSheet != nil {
            title = "Диалог"
            text = dialogHelp.isEmpty ? "Enter — подтвердить действие; Escape — отменить. Проверяйте пути и число объектов перед подтверждением. Корзина macOS позволяет восстановить удалённые объекты." : dialogHelp
        } else {
            title = "Файловая панель"
            text = "Курсор и пометки независимы. F5/F6/F8 обрабатывают пометки, без пометок — курсор. F3/F4 и Shift+F5/F6 используют только курсор. Для папки F3 считает размер, F4 открывает свойства.\n\nНАВИГАЦИЯ\nTab — другая панель; Enter — открыть; Backspace — выше.\nHome/End/PageUp/PageDown — перемещение; Shift — с пометкой.\nCmd+L — путь, Cmd+[ / Cmd+] — назад/вперёд.\nOption+буквы — быстрый поиск без фильтрации, Ctrl+Enter — следующее совпадение, Ctrl+Shift+Enter — предыдущее, Escape — закрыть поиск.\nCmd+F — фильтр текущей панели; скрываемые файлы теряют пометки.\nOption+F7 или Cmd+Shift+F — рекурсивный поиск файлов. Результаты можно открыть через F3/F4 или отправить во временную панель. Кнопка возврата восстанавливает обычную папку.\nOption+F1/F2 — тома и папки соответствующей панели.\nCtrl+Shift+0…9 — сохранить быструю папку; Ctrl+0…9 — перейти.\n\nПОМЕТКИ\nInsert/Space — переключить пометку и шагнуть вниз.\nShift+стрелки/Home/End/Page — пометить диапазон покидаемых строк.\nCtrl+M — восстановить прошлый набор, повтор — поменять наборы местами.\nNumpad +/− — маска; * — инверсия; Ctrl+* — с папками.\nCtrl+Numpad +/− — то же расширение; Ctrl+Shift+Numpad +/− — то же имя без расширения.\nCmd+A — все объекты, Cmd-щелчок — одна пометка.\n\nМЕНЮ\nCmd+J — очередь и журнал; отмена не откатывает завершённые файлы.\nF9 — все меню команд; меню «Вид» — сортировка, режим и колонки.\nМеню «История», «Избранное» и «Тома» — переходы; «Панели» — синхронизация путей. Настройки сохраняются между запусками.\n\nF2 пока открывает фиксированные действия; пользовательское меню запланировано отдельно. На Mac для F-клавиш может потребоваться Fn."
        }
        contextHelp.present(title: title, text: text)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if toolMutationPending {
            toolWindows.first { ($0 as? FileToolsWindowController)?.hasPendingMutation == true }?.showWindow(nil)
            return .terminateCancel
        }
        if operationQueue.hasPendingOperations {
            status.stringValue = "Перед выходом дождитесь очереди или отмените операции в её окне."
            operationQueue.showWindow(nil)
            return .terminateCancel
        }
        if busy { inform("Операция ещё выполняется", "Дождитесь завершения файловой операции перед выходом."); return .terminateCancel }
        for editor in editors where editor.window?.isVisible == true {
            if let window = editor.window, editor.windowShouldClose(window) == false { return .terminateCancel }
        }
        searchWindow?.cancel()
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
        let titles = ["Помощь", "Действия панели", "Просмотр", "Редактировать", "Копировать…", "Переместить…", "Создать папку…", "В Корзину…"]
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
        let selectAll = NSMenuItem(title: "Выделить всё", action: #selector(selectAllInContext(_:)), keyEquivalent: "a")
        selectAll.target = self; edit.addItem(selectAll)
        let navigation = submenu("Панели")
        for (name, id, key) in [("Перейти к пути…", "path", "l"), ("Выбрать папку…", "choose", "o"), ("Назад", "back", "["), ("Вперёд", "forward", "]"), ("Быстрый поиск по имени", "quickFind", ""), ("Следующее совпадение", "findNext", ""), ("Предыдущее совпадение", "findPrevious", ""), ("Фильтр текущей папки", "filter", "f"), ("Обновить", "refresh", "r"), ("Показать / скрыть скрытые файлы", "hidden", "."), ("Открыть этот путь в соседней панели", "syncToOther", ""), ("Взять путь соседней панели", "syncFromOther", ""), ("Настройки активной панели…", "panelSettings", ","), ("Открыть Терминал здесь", "terminal", "t"), ("Показать в Finder", "reveal", "")] {
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
