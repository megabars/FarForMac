import AppKit
import FarCore

extension AppDelegate {
    private typealias MenuItem = FarMainMenuView.Item
    private typealias MenuSection = FarMainMenuView.Section

    func presentFarMainMenu(restoringLast: Bool) {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              NSApp.modalWindow == nil, let host = window.contentView, !farMainMenu.isPresented else { return }
        farMainMenu.present(in: host, rightPanelActive: active === right && !right.isHidden,
                            restoringLast: restoringLast, rows: [
            .left: farSideMenu(for: left, rightSide: false),
            .files: farFilesMenu(),
            .commands: farCommandsMenu(),
            .options: farOptionsMenu(),
            .right: farSideMenu(for: right, rightSide: true)
        ])
    }

    private func farSideMenu(for panel: PanelView, rightSide: Bool) -> [MenuItem?] {
        let mayChange = canChangePanelResource
        func panelMode(_ mode: PanelContentMode, _ ru: String, _ en: String, _ key: String) -> MenuItem {
            var row = farItem(mode.rawValue, ru, en, key, checked: panel.contentMode == mode)
            if mayChange {
                row.action = { [weak self, weak panel] in
                    guard let self, let panel, self.canChangePanelResource else { return }
                    panel.setContentMode(mode)
                    if self.active === panel { panel.focus() }
                }
            }
            return row
        }
        var sort = farItem("sortModes", "Режимы сортировки", "Sort modes", "Ctrl+F12")
        if mayChange, panel.contentMode == .files, !panel.isArchive, !panel.isRemote, !panel.isResource {
            sort.action = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.showFarSortModes(for: panel)
            }
        }
        var reread = farItem("reread", "Перечитать", "Re-read", "Ctrl+R")
        if mayChange, !panel.isVirtual { reread.action = { [weak panel] in panel?.refresh() } }
        var drive = farItem("changeDrive", "Сменить диск", "Change drive", rightSide ? "Alt+F2" : "Alt+F1")
        if mayChange {
            drive.action = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.showResourceMenu(for: panel)
            }
        }
        return [
            farItem("brief", "Краткий", "Brief", "Ctrl+1"),
            farItem("medium", "Средний", "Medium", "Ctrl+2"),
            farItem("full", "Полный", "Full", "Ctrl+3"),
            farItem("wide", "Широкий", "Wide", "Ctrl+4"),
            farItem("detailed", "Детальный", "Detailed", "Ctrl+5"),
            farItem("descriptions", "Описания", "Descriptions", "Ctrl+6"),
            farItem("longDescriptions", "Длинные описания", "Long descriptions", "Ctrl+7"),
            farItem("owners", "Владельцы файлов", "File owners", "Ctrl+8"),
            farItem("links", "Ссылки файлов", "File links", "Ctrl+9"),
            farItem("alternative", "Альтернативный полный", "Alternative full", "Ctrl+0"),
            nil,
            panelMode(.info, "Панель информации", "Info panel", "Ctrl+L"),
            panelMode(.tree, "Дерево папок", "Tree panel", "Ctrl+T"),
            panelMode(.quickView, "Быстрый просмотр", "Quick view", "Ctrl+Q"),
            nil,
            sort,
            farItem("longNames", "Показывать длинные имена", "Show long names", "Ctrl+N"),
            farItem("togglePanel", "Панель Вкл/Выкл", "Panel On/Off", rightSide ? "Ctrl+F2" : "Ctrl+F1"),
            reread,
            drive
        ]
    }

    private func showFarSortModes(for panel: PanelView) {
        let modes = FileSort.allCases
        let title = farText("Режимы сортировки", "Sort modes")
        let menu = PanelListMenu(title: title, hint: "")
        let rows = modes.map { mode in
            PanelListMenu.Row(title: (mode == panel.sortOptions.sort ? "✓  " : "   ") + L10n.text(mode.title))
        }
        menu.replaceRows(rows, selection: modes.firstIndex(of: panel.sortOptions.sort) ?? 0)
        var chosen: FileSort?
        menu.onActivate = { [weak menu] index in chosen = modes[index]; menu?.dismiss() }
        menu.run(relativeTo: window)
        if let chosen { panel.setSort(chosen) }
    }

    private func farFilesMenu() -> [MenuItem?] {
        let cursorOnly = active.cursorEntry.map { cursor in active.selectedEntries.map(\.id) == [cursor.id] } ?? false
        return [
            farFunction(3, "Просмотр", "View"),
            farFunction(4, "Редактирование", "Edit"),
            farFunction(5, "Копирование", "Copy"),
            farFunction(6, "Перенос", "Rename or move"),
            farItem("link", "Ссылка", "Link", "Alt+F6"),
            farFunction(7, "Создание папки", "Make folder"),
            farFunction(8, "Удаление", "Delete"),
            farItem("wipe", "Уничтожение", "Wipe", "Alt+Del"),
            nil,
            farCommand(passive.isArchive ? "archiveAdd" : "archiveCreate", "Архивировать", "Add to archive", "Shift+F1"),
            farCommand("archiveExtract", "Распаковать", "Extract files", "Shift+F2", enabled: !passive.isResource),
            farItem("archiveCommands", "Архивные команды", "Archive commands", "Shift+F3"),
            nil,
            farCommand("properties", "Атрибуты файлов", "File attributes", "Ctrl+A", enabled: cursorOnly),
            farItem("applyCommand", "Применить команду", "Apply command", "Ctrl+G"),
            farCommand("fileDescription", "Описание файлов", "Describe files", "Ctrl+Z", enabled: cursorOnly),
            nil,
            farCommand("markMask", "Пометить группу", "Select group", "Num +"),
            farCommand("unmarkMask", "Снять пометку", "Deselect group", "Num −"),
            farCommand("invertMarks", "Инверсия пометки", "Invert selection", "Num *"),
            farCommand("restoreMarks", "Восстановить пометку", "Restore selection", "Ctrl+M")
        ]
    }

    private func farCommandsMenu() -> [MenuItem?] {
        let folders = [left!, right!].allSatisfy {
            !$0.isResource && !$0.isArchive && !$0.isRemote && !$0.isVirtual && !$0.isTemporary
        }
        return [
            farCommand("search", "Поиск файла", "Find file", "Alt+F7"),
            farCommand("commandHistory", "История команд", "History", "Alt+F8"),
            farItem("videoMode", "Видеорежим", "Video mode", "Alt+F9"),
            farItem("findFolder", "Поиск папки", "Find folder", "Alt+F10"),
            farCommand("viewHistory", "История просмотра", "File view history", "Alt+F11"),
            farCommand("folderHistory", "История папок", "Folders history", "Alt+F12"),
            nil,
            farItem("swapPanels", "Поменять панели", "Swap panels", "Ctrl+U"),
            farCommand("toggleTerminal", "Панели Вкл/Выкл", "Panels On/Off", "Ctrl+O"),
            farCommand("compareDirectories", "Сравнение папок", "Compare folders", enabled: folders),
            nil,
            farCommand("userCommands", "Меню пользователя", "Edit user menu"),
            farCommand("userCommands", "Ассоциации файлов", "File associations", menuID: "fileAssociations"),
            farItem("folderShortcuts", "Ссылки на папки", "Folder shortcuts"),
            farItem("fileFilter", "Фильтр панели файлов", "File panel filter", "Ctrl+I"),
            nil,
            farItem("pluginCommands", "Команды плагинов", "Plugin commands", "F11"),
            farItem("screens", "Список экранов", "Screens list", "F12"),
            farItem("tasks", "Список задач", "Task list", "Ctrl+W"),
            farItem("hotplug", "Список устройств", "Hotplug devices list")
        ]
    }

    private func farOptionsMenu() -> [MenuItem?] {
        [
            farItem("systemSettings", "Системные параметры", "System settings"),
            farItem("panelSettings", "Настройки панели", "Panel settings"),
            farItem("treeSettings", "Настройки дерева папок", "Tree settings"),
            farItem("interfaceSettings", "Настройки интерфейса", "Interface settings"),
            farItem("languages", "Языки", "Languages"),
            farItem("plugins", "Параметры плагинов", "Plugins configuration"),
            farItem("pluginManager", "Параметры менеджера плагинов", "Plugin manager settings"),
            farItem("dialogs", "Настройки диалогов", "Dialog settings"),
            farItem("menus", "Настройки меню", "Menu settings"),
            farItem("commandLine", "Настройки командной строки", "Command line settings"),
            farItem("autocomplete", "Настройки автодополнения", "AutoComplete settings"),
            farItem("infoPanel", "Настройки панели информации", "InfoPanel settings"),
            farCommand("maskGroups", "Группы масок файлов", "Groups of file masks"),
            nil,
            farItem("confirmations", "Подтверждения", "Confirmations"),
            farItem("panelModes", "Режимы панели файлов", "File panel modes"),
            farItem("descriptionSettings", "Описания файлов", "File descriptions"),
            farItem("folderDescriptions", "Файлы описания папок", "Folder description files"),
            nil,
            farItem("viewerSettings", "Настройки программы просмотра", "Viewer settings"),
            farItem("editorSettings", "Настройки редактора", "Editor settings"),
            farItem("codePages", "Кодовые страницы", "Code pages"),
            nil,
            farItem("colors", "Цвета", "Colors"),
            farItem("fileHighlighting", "Раскраска файлов и группы сортировки", "Files highlighting and sort groups"),
            nil,
            farItem("saveSetup", "Сохранить параметры", "Save setup", "Shift+F9")
        ]
    }

    private func farText(_ ru: String, _ en: String) -> String { L10n.language == .english ? en : ru }

    private func farItem(_ id: String, _ ru: String, _ en: String, _ shortcut: String = "", checked: Bool = false) -> MenuItem {
        MenuItem(id: id, title: farText(ru, en), shortcut: shortcut, checked: checked)
    }

    private func farCommand(_ id: String, _ ru: String, _ en: String, _ shortcut: String = "",
                            enabled: Bool = true, menuID: String? = nil) -> MenuItem {
        var row = farItem(menuID ?? id, ru, en, shortcut)
        let command = menuCommand(row.title, id)
        if enabled, validateMenuItem(command) {
            row.action = { [weak self] in
                guard let self, self.validateMenuItem(command) else { return }
                self.command(command)
            }
        }
        return row
    }

    private func farFunction(_ number: Int, _ ru: String, _ en: String) -> MenuItem {
        var row = farItem("f\(number)", ru, en, "F\(number)")
        let command = NSMenuItem(title: row.title, action: #selector(functionMenu(_:)), keyEquivalent: "")
        command.tag = number
        let supported: Bool
        switch active.resourceKind {
        case .localNetwork: supported = [4, 5, 8].contains(number)
        case .connections: supported = [4, 5, 7, 8].contains(number)
        case .processes: supported = [3, 8].contains(number)
        case nil:
            if [5, 6].contains(number), passive.isResource {
                supported = number == 5 && passive.resourceKind == .connections &&
                    !active.isArchive && !active.isRemote && !active.isVirtual
            } else {
                supported = true
            }
        }
        if supported, canChangePanelResource, validateMenuItem(command) {
            row.action = { [weak self] in
                guard let self, self.canChangePanelResource, self.validateMenuItem(command) else { return }
                self.performFunction(number)
            }
        }
        return row
    }

    func runFarMainMenuUISmokeChecks() throws -> [String] {
        guard AppRuntime.isSmoke else { throw PanelSessionError("F9 smoke requires isolated state") }
        let originalPanel = active!, originalLeftMode = left.contentMode, originalRightMode = right.contentMode
        defer {
            farMainMenu.dismiss()
            left.setContentMode(originalLeftMode)
            right.setContentMode(originalRightMode)
            activate(originalPanel)
            originalPanel.focus()
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PanelSessionError(message) }
        }
        func press(_ keyCode: UInt16) throws {
            guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, characters: "",
                                             charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)
            else { throw PanelSessionError("Could not construct F9 smoke key") }
            farMainMenu.handleKey(key)
        }

        window.makeKeyAndOrderFront(nil)
        right.setContentMode(.files)
        activate(right); right.focus()
        showCommandMenu()
        try require(farMainMenu.selectedSection == .right && !farMainMenu.isExpanded,
                    "F9 did not start on right: presented=\(farMainMenu.isPresented), section=\(farMainMenu.selectedSection), activeRight=\(active === right), key=\(window.isKeyWindow), modal=\(NSApp.modalWindow != nil), sheet=\(window.attachedSheet != nil)")
        try press(53)
        activate(left); left.focus()
        let responder = window.firstResponder
        showCommandMenu()
        try require(farMainMenu.selectedSection == .left && !farMainMenu.isExpanded, "F9 did not start at the left active panel")
        try press(124)
        try require(farMainMenu.selectedSection == .files, "F9 sections were not in FAR order")
        try press(48)
        try require(farMainMenu.selectedSection == .right && active === left, "F9 Tab did not select the passive section without changing active panel")
        try press(125)
        try require(farMainMenu.selectedCommandID == "info", "Unavailable file modes must not become actions")
        if let content = window.contentView, let report = AppRuntime.smokeReport {
            content.layoutSubtreeIfNeeded()
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: report.deletingLastPathComponent().appendingPathComponent("far-main-menu-smoke.png"), options: .atomic)
                }
            }
        }
        try press(48)
        try require(farMainMenu.selectedSection == .left && farMainMenu.isExpanded, "F9 Tab did not keep the adjacent section expanded")
        try press(48)
        try press(36)
        try require(!farMainMenu.isPresented && active === left && left.contentMode == originalLeftMode && right.contentMode == .info,
                    "F9 right-side action changed the wrong panel")
        try require(window.firstResponder === responder, "F9 did not restore the original keyboard focus")
        showCommandMenu(restoringLast: true)
        try require(farMainMenu.selectedSection == .right && farMainMenu.isExpanded && farMainMenu.selectedCommandID == "info",
                    "Shift+F10 did not restore the last command")
        try press(53)
        try require(farMainMenu.isPresented && !farMainMenu.isExpanded, "F9 Escape must close the expanded list first")
        try press(53)
        try require(!farMainMenu.isPresented && right.contentMode == .info && active === left, "F9 Escape must cancel without running the selection")
        return ["F9 starts at the active side, Tab switches sections and preserves the active panel",
                "F9 applies a right-side action to the right pane and restores focus",
                "Shift+F10 selects the last command and Escape cancels without executing it"]
    }
}
