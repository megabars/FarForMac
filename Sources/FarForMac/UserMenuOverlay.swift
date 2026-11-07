import AppKit
import FarCore

@MainActor
final class UserMenuOverlay {
    enum Outcome {
        case command(UserMenuEntry, title: String)
        case editFile(LoadedUserMenu)
    }

    private let store: UserCommandStore
    private let context: UserCommandContext
    private let menu = PanelListMenu(title: "Пользовательское меню",
        hint: "Enter — выполнить · Shift+F2 — следующий источник · Backspace — меню родителя\nIns — вставить · F4 / Shift+F4 — править · Alt+F4 — текст · Del — удалить · Ctrl+↑/↓ — переместить")
    private var loaded: LoadedUserMenu
    private var branch: [Int] = []
    private var outcome: Outcome?
    var onHelp: (() -> Void)?
    var onPlugins: (() -> Void)?

    init(store: UserCommandStore, context: UserCommandContext) throws {
        menu.macroArea = "UserMenu"
        self.store = store
        self.context = context
        loaded = try store.loadMenu(in: context.activeDirectory)
    }

    func run(relativeTo owner: NSWindow?, smokeKey: PanelListMenu.SmokeKey? = nil) -> Outcome? {
        redraw()
        menu.onActivate = { [weak self] in self?.activate($0) }
        menu.onKey = { [weak self] in self?.key($0) ?? false }
        menu.run(relativeTo: owner, smokeKey: smokeKey)
        return outcome
    }

    private var level: [UserMenuEntry] {
        branch.reduce(loaded.entries) { entries, index in entries[index].children ?? [] }
    }

    private func redraw(_ cursor: Int = 0) {
        let base: String
        switch loaded.location {
        case .local: base = "Локальное меню · " + loaded.source.deletingLastPathComponent().path
        case .installation: base = "Главное меню · установка"
        case .profile: base = "Главное меню · профиль"
        }
        let breadcrumb = branch.reduce(into: (entries: loaded.entries, titles: [String]())) { state, index in
            let entry = state.entries[index]
            state.titles.append(title(of: entry))
            state.entries = entry.children ?? []
        }
        menu.window?.title = ([base] + breadcrumb.titles).joined(separator: " » ")
        menu.replaceRows(level.map { entry in
            let prefix = entry.key.map { $0 + "  " } ?? "    "
            let suffix = entry.children == nil ? "" : "   ▸"
            return entry.separator == true
                ? .init(title: entry.title.isEmpty || entry.title == "—" ? "──────────────────────────────────" : "────  " + entry.title, selectable: false)
                : .init(title: prefix + title(of: entry) + suffix)
        }, selection: cursor)
    }

    private func title(of entry: UserMenuEntry) -> String {
        entry.farSyntax == true ? FarMenuMetasymbols.title(entry.title, context: context) : entry.title
    }

    private func activate(_ index: Int) {
        guard level.indices.contains(index) else { return }
        let entry = level[index]
        if entry.children != nil { branch.append(index); redraw() }
        else if entry.command != nil { outcome = .command(entry, title: title(of: entry)); menu.dismiss() }
    }

    private func switchSource() throws {
        loaded = try store.nextMenu(after: loaded, in: context.activeDirectory)
        branch = []
        redraw()
    }

    private func parentSource() throws {
        loaded = try store.loadParentMenu(of: loaded)
        branch = []
        redraw()
    }

    private func key(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = event.keyCode
        do {
            if modifiers.isEmpty || modifiers == .shift {
                if let token = hotKey(event), (modifiers.isEmpty || token.count == 1),
                   let row = token.count > 1
                    ? level.lastIndex(where: { $0.key?.uppercased() == token })
                    : level.firstIndex(where: { $0.key?.uppercased() == token }) {
                    activate(row)
                    return true
                }
            }
            if modifiers.isEmpty {
                switch code {
                case 114, 82: try edit(insert: true)
                case 118: try edit(insert: false)
                case 117, 65: try removeSelected()
                case 51:
                    guard loaded.isLocal else { return false }
                    try parentSource()
                case 122:
                    guard let onHelp else { return false }
                    onHelp()
                case 103:
                    guard let onPlugins else { return false }
                    onPlugins()
                case 124, 88:
                    if let index = menu.selection, level[index].children != nil { activate(index) }
                case 123, 86, 53:
                    guard let previous = branch.popLast() else { return false }
                    redraw(previous)
                default: return false
                }
            } else if modifiers == .shift {
                switch code {
                case 120: try switchSource()
                case 122:
                    guard let onHelp else { return false }
                    onHelp()
                case 103:
                    guard let onPlugins else { return false }
                    onPlugins()
                case 118: try edit(insert: false)
                case 109: menu.dismiss()
                default: return false
                }
            } else if modifiers == .control && [125, 126].contains(code) {
                try moveSelected(delta: code == 126 ? -1 : 1)
            } else if modifiers == .option && code == 118 {
                outcome = .editFile(loaded); menu.dismiss()
            } else { return false }
        } catch {
            menu.report(error.localizedDescription)
        }
        return true
    }

    private func hotKey(_ event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
              let scalar = characters.unicodeScalars.first else { return nil }
        let first = UInt32(NSF1FunctionKey)
        if (first..<(first + 24)).contains(scalar.value) { return "F" + String(scalar.value - first + 1) }
        return characters.uppercased()
    }

    private func edit(insert: Bool) throws {
        let position = menu.selection ?? 0
        let original: UserMenuEntry?
        if insert { original = nil }
        else {
            guard let index = menu.selection else { return }
            original = level[index]
        }
        let isSubmenu: Bool
        if let original { isSubmenu = original.children != nil }
        else {
            let chooser = NSAlert()
            chooser.messageText = "Вставить в пользовательское меню"
            chooser.addButton(withTitle: "Команду")
            chooser.addButton(withTitle: "Подменю")
            chooser.addButton(withTitle: "Отмена")
            switch chooser.runModal() {
            case .alertFirstButtonReturn: isSubmenu = false
            case .alertSecondButtonReturn: isSubmenu = true
            default: return
            }
        }
        guard let edited = editEntry(original, isSubmenu: isSubmenu) else { return }
        try changeLevel(at: position) { entries in
            if insert { entries.insert(edited, at: position) }
            else { entries[position] = edited }
        }
    }

    private func editEntry(_ original: UserMenuEntry?, isSubmenu: Bool) -> UserMenuEntry? {
        let title = NSTextField(string: original?.title ?? "")
        let hotkey = NSTextField(string: original?.key ?? "")
        hotkey.placeholderString = loaded.isFarMenu || original?.farSyntax == true
            ? "Символ, F1…F24 или --" : "Буква, цифра, F1…F24 или --"
        let command = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 110))
        command.string = original?.command ?? ""
        command.isRichText = false
        command.isAutomaticQuoteSubstitutionEnabled = false
        command.isAutomaticDashSubstitutionEnabled = false
        command.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = command
        scroll.hasVerticalScroller = true
        var fields: [[NSView]] = [[NSTextField(labelWithString: "Клавиша"), hotkey],
                                  [NSTextField(labelWithString: "Название"), title]]
        if !isSubmenu { fields.append([NSTextField(labelWithString: "Команда"), scroll]) }
        let grid = NSGridView(views: fields)
        grid.columnSpacing = 9
        grid.rowSpacing = 7
        title.widthAnchor.constraint(equalToConstant: 440).isActive = true
        if !isSubmenu { scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true }
        grid.frame = NSRect(x: 0, y: 0, width: 540, height: isSubmenu ? 65 : 190)
        let alert = NSAlert()
        alert.messageText = isSubmenu ? "Параметры подменю" : "Параметры команды"
        alert.accessoryView = grid
        alert.window.initialFirstResponder = hotkey
        alert.addButton(withTitle: "Сохранить")
        alert.addButton(withTitle: "Отмена")
        let farSyntax = loaded.isFarMenu || original?.farSyntax == true
        let originalCommand = original?.command ?? ""
        while true {
            if alert.runModal() != .alertFirstButtonReturn {
                guard farSyntax, command.string != originalCommand else { return nil }
                let confirmation = NSAlert()
                confirmation.messageText = "Сохранить изменения команд?"
                confirmation.addButton(withTitle: "Сохранить")
                confirmation.addButton(withTitle: "Не сохранять")
                confirmation.addButton(withTitle: "Отмена")
                switch confirmation.runModal() {
                case .alertFirstButtonReturn: break
                case .alertSecondButtonReturn: return nil
                default: continue
                }
            }
            let key = hotkey.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate: UserMenuEntry
            if key == "--" {
                candidate = UserMenuEntry(title: farSyntax ? title.stringValue : "--", separator: true, farSyntax: farSyntax)
            } else {
                candidate = UserMenuEntry(title: title.stringValue, command: isSubmenu ? nil : command.string,
                    children: isSubmenu ? (original?.children ?? []) : nil, key: key.isEmpty ? nil : key, farSyntax: farSyntax)
            }
            do {
                try UserCommandConfiguration(menu: [candidate]).validate()
                return candidate
            } catch {
                let problem = NSAlert(error: error)
                problem.runModal()
                alert.window.initialFirstResponder = title.stringValue.isEmpty ? title : hotkey
            }
        }
    }

    private func removeSelected() throws {
        guard let index = menu.selection else { return }
        let entry = level[index]
        let alert = NSAlert()
        alert.messageText = entry.children == nil ? "Удалить пункт меню?" : "Удалить подменю?"
        alert.informativeText = entry.title
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try changeLevel(at: index) { $0.remove(at: index) }
    }

    private func moveSelected(delta: Int) throws {
        guard let index = menu.selection, level.indices.contains(index + delta) else { return }
        try changeLevel(at: index + delta) { $0.swapAt(index, index + delta) }
    }

    private func changeLevel(at selection: Int, _ edit: (inout [UserMenuEntry]) -> Void) throws {
        func apply(_ entries: inout [UserMenuEntry], path: ArraySlice<Int>) {
            guard let index = path.first else { edit(&entries); return }
            guard var children = entries[index].children else { return }
            apply(&children, path: path.dropFirst())
            entries[index].children = children
        }
        var updated = loaded.entries
        apply(&updated, path: branch[...])
        loaded = try store.saveMenu(updated, replacing: loaded)
        menu.report("")
        redraw(selection)
    }
}
