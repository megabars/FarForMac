import AppKit
import FarCore

extension AppDelegate: NSMenuDelegate {
    var maskGroups: [String: String] {
        get { AppPreferences.defaults.dictionary(forKey: "maskGroups") as? [String: String] ?? ["text": "*.txt;*.md;*.swift;*.json;*.xml", "archives": "*.zip;*.tar;*.gz;*.7z;*.rar", "images": "*.png;*.jpg;*.jpeg;*.gif;*.heic"] }
        set {
            AppPreferences.defaults.set(newValue, forKey: "maskGroups")
            left?.maskGroups = newValue; right?.maskGroups = newValue
        }
    }
    var bookmarks: [String] {
        get { AppPreferences.defaults.stringArray(forKey: "bookmarks") ?? [] }
        set { AppPreferences.defaults.set(Array(newValue.prefix(100)), forKey: "bookmarks") }
    }
    var quickFolders: [String: String] {
        get { AppPreferences.defaults.dictionary(forKey: "quickFolders") as? [String: String] ?? [:] }
        set { AppPreferences.defaults.set(newValue, forKey: "quickFolders") }
    }
    func addBookmark() {
        let path = active.directory.path
        if !bookmarks.contains(path) { bookmarks.append(path) }
        status.stringValue = "Папка добавлена в избранное"
    }
    func removeBookmark() { bookmarks.removeAll { $0 == active.directory.path } }
    func quickFolder(_ number: Int, save: Bool) {
        if save {
            quickFolders[String(number)] = active.directory.path
            status.stringValue = "Быстрая папка \(number) сохранена"
        } else if let path = quickFolders[String(number)] {
            active.navigateHistory(to: path)
        } else { status.stringValue = "Папка \(number) не задана. Ctrl+Shift+\(number) сохранит текущую." }
    }
    @objc func quickFolderMenu(_ sender: NSMenuItem) {
        if sender.representedObject as? String == "clear" {
            quickFolders.removeValue(forKey: String(sender.tag))
            status.stringValue = "Быстрая папка \(sender.tag) удалена из списка"
        } else { quickFolder(sender.tag, save: sender.representedObject as? String == "save") }
    }
    @objc func visitLocation(_ sender: NSMenuItem) {
        guard window.isKeyWindow, window.attachedSheet == nil, let path = sender.representedObject as? String else { return }
        active.navigateHistory(to: path)
    }
    @objc func sortMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let sort = FileSort(rawValue: value) else { return }
        active.setSort(sort)
    }
    func menuCommand(_ title: String, _ id: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(command(_:)), keyEquivalent: key)
        item.target = self; item.representedObject = id; item.keyEquivalentModifierMask = modifiers
        return item
    }
    func attachPanelMenus(to bar: NSMenu) {
        for name in ["История", "Избранное", "Вид", "Тома"] {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: name); menu.delegate = self
            item.submenu = menu; bar.addItem(item)
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard active != nil else { return }
        guard ["История", "Избранное", "Вид", "Тома"].contains(menu.title) else { return }
        menu.removeAllItems()
        switch menu.title {
        case "История":
            let back = menuCommand("Назад", "back", key: "[")
            let forward = menuCommand("Вперёд", "forward", key: "]")
            menu.addItem(back); menu.addItem(forward); menu.addItem(.separator())
            var seen = Set<String>()
            for path in active.historyPaths.reversed() where seen.insert(path).inserted {
                let item = NSMenuItem(title: path, action: #selector(visitLocation(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = path
                item.state = path == active.directory.path ? .on : .off
                menu.addItem(item)
            }
        case "Избранное":
            menu.addItem(menuCommand("Добавить текущую папку", "bookmark"))
            menu.addItem(menuCommand("Убрать текущую папку из избранного", "unbookmark"))
            menu.addItem(.separator())
            for path in bookmarks {
                let item = NSMenuItem(title: path, action: #selector(visitLocation(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = path; menu.addItem(item)
            }
            menu.addItem(.separator())
            for number in 0...9 {
                let item = NSMenuItem(title: "\(number): \(quickFolders[String(number)] ?? "не задана")", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                let open = NSMenuItem(title: "Открыть — Ctrl+\(number)", action: #selector(quickFolderMenu(_:)), keyEquivalent: "")
                open.tag = number; open.target = self; open.representedObject = "open"
                let save = NSMenuItem(title: "Запомнить текущую — Ctrl+Shift+\(number)", action: #selector(quickFolderMenu(_:)), keyEquivalent: "")
                save.tag = number; save.target = self; save.representedObject = "save"
                let clear = NSMenuItem(title: "Очистить быструю папку", action: #selector(quickFolderMenu(_:)), keyEquivalent: "")
                clear.tag = number; clear.target = self; clear.representedObject = "clear"
                submenu.addItem(open); submenu.addItem(save); submenu.addItem(clear); item.submenu = submenu; menu.addItem(item)
            }
        case "Вид":
            for sort in FileSort.allCases {
                let titles: [FileSort: String] = [.name: "По имени", .size: "По размеру", .modified: "По времени изменения", .extension: "По расширению", .created: "По времени создания", .accessed: "По времени доступа", .selected: "По пометкам"]
                let item = NSMenuItem(title: titles[sort] ?? sort.title, action: #selector(sortMenu(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = sort.rawValue
                item.state = active.sortOptions.sort == sort ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(menuCommand("Обратить порядок", "reverseSort")); menu.addItem(.separator())
            for (name, id, mode) in [("Краткий режим", "brief", PanelDisplayMode.brief), ("Полный режим", "full", .full), ("Свои колонки", "custom", .custom)] {
                let item = menuCommand(name, id); item.state = active.displayMode == mode ? .on : .off; menu.addItem(item)
            }
            menu.addItem(.separator())
            menu.addItem(menuCommand("Настройки активной панели…", "panelSettings", key: ","))
        case "Тома":
            let resources = resourceMenu(for: active)
            for item in resources.items { resources.removeItem(item); menu.addItem(item) }
        default: break
        }
    }
    func showPanelMenu(named name: String) {
        guard let menu = NSApp.mainMenu?.item(withTitle: name)?.submenu else { return }
        menuNeedsUpdate(menu)
        menu.popUp(positioning: nil, at: NSPoint(x: 18, y: window.contentView!.bounds.height - 10), in: window.contentView)
    }
    func showCommandMenu(restoringLast: Bool = false) {
        presentFarMainMenu(restoringLast: restoringLast)
    }
    func openPanelSettings() {
        settingsWindow?.close()
        settingsWindow = PanelSettingsWindow(panel: active)
        settingsWindow?.showWindow(nil)
    }
    func openMaskGroups() {
        groupsWindow?.close()
        groupsWindow = MaskGroupsWindow(groups: maskGroups) { [weak self] groups in self?.maskGroups = groups }
        groupsWindow?.showWindow(nil)
    }
}
