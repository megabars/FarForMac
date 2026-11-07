import AppKit
import FarCore

@MainActor
final class LocalTransferDialog: NSObject {
    private static let settingsKey = "transfer.dialog.settings.v1"
    private static let historyKey = "transfer.dialog.history.v1"
    private static let multipleKey = "transfer.dialog.multiple"

    private let alert = NSAlert()
    private let destination = NSComboBox()
    private let conflicts = NSPopUpButton()
    private let readOnly = NSButton(checkboxWithTitle: "Также спрашивать для файлов только для чтения", target: nil, action: nil)
    private let timestamps = NSButton(checkboxWithTitle: "Сохранять все времена", target: nil, action: nil)
    private let multiple = NSButton(checkboxWithTitle: "Несколько назначений", target: nil, action: nil)
    private let useFilter = NSButton(checkboxWithTitle: "Использовать фильтр", target: nil, action: nil)
    private let filterButton = NSButton(title: "Фильтр…", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceURLs: [URL]
    private let sourceDirectory: URL
    private let passiveDirectory: URL
    private let maskGroups: [String: String]
    private let move: Bool
    private var rules: [LocalTransferFilterRule]
    private var keyMonitor: Any?

    private init(sources: [FileEntry], sourceDirectory: URL, passiveDirectory: URL, move: Bool,
                 cursorOnly: Bool, maskGroups: [String: String]) {
        self.sourceDirectory = sourceDirectory
        self.passiveDirectory = passiveDirectory
        sourceURLs = sources.map(\.url)
        self.maskGroups = maskGroups
        self.move = move
        let settings = AppPreferences.defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(LocalTransferOptions.self, from: $0) } ?? LocalTransferOptions()
        rules = settings.filterRules
        super.init()
        alert.messageText = move ? "Перенос / переименование" : "Копирование"
        alert.informativeText = sources.count == 1
            ? "\(move ? "Перенести" : "Копировать") «\(sources[0].name)» в"
            : "\(move ? "Перенести" : "Копировать") объектов (\(sources.count)) в"
        multiple.isEnabled = !move
        multiple.state = !move && AppPreferences.defaults.bool(forKey: Self.multipleKey) ? .on : .off
        let path: String
        if sources.count == 1 && (cursorOnly || LocalTransferDestination.sameDirectory(sourceDirectory, passiveDirectory)) {
            let source = sources[0].url
            if LocalTransferDestination.sameDirectory(sourceDirectory, source.deletingLastPathComponent()) {
                let name = source.lastPathComponent
                // A literal leading tilde or quote belongs to this filename.
                path = name.hasPrefix("~") || name.hasPrefix("\"") ? "./" + name : name
            } else {
                path = source.path
            }
        } else {
            path = Self.withSlash(passiveDirectory.path)
        }
        if path.contains("\"") { multiple.state = .off }
        destination.stringValue = multiple.state == .on ? Self.quoteListPath(path) : path
        destination.completes = true
        destination.setAccessibilityLabel("Путь назначения")
        destination.addItems(withObjectValues: AppPreferences.defaults.stringArray(forKey: Self.historyKey) ?? [])
        destination.widthAnchor.constraint(equalToConstant: 565).isActive = true

        conflicts.addItems(withTitles: ["Запрос", "Заменять", "Пропускать", "Переименовывать", "Добавлять", "Только более новые"])
        conflicts.selectItem(at: LocalTransferConflictPolicy.allCases.firstIndex(of: settings.conflictPolicy) ?? 0)
        conflicts.setAccessibilityLabel("Если файл уже существует")
        readOnly.state = settings.confirmReadOnly ? .on : .off
        timestamps.state = settings.preserveAllTimestamps ? .on : .off
        useFilter.isEnabled = sources.count > 1 || sources.first?.isDirectory == true
        useFilter.state = useFilter.isEnabled && !rules.isEmpty && AppPreferences.defaults.bool(forKey: "transfer.dialog.useFilter") ? .on : .off
        useFilter.target = self
        useFilter.action = #selector(toggleFilter)
        filterButton.target = self
        filterButton.action = #selector(editFilters)
        toggleFilter()
        let tree = NSButton(title: "Папка… · F10", target: self, action: #selector(chooseActiveFolder))
        let access = NSTextField(labelWithString: "Права доступа и метаданные копируются средствами macOS")
        let tip = NSTextField(wrappingLabelWithString: "Относительный путь — от активной папки. / в конце создаёт папку. * и ? задают маску конечного имени.")
        tip.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        let controls = vertical([
            destination, horizontal([label("Если файл уже существует", size: 12), conflicts, NSView()]),
            readOnly, timestamps, multiple, horizontal([useFilter, filterButton, NSView()]),
            horizontal([tree, NSView()]), access, tip, errorLabel
        ], spacing: 8)
        controls.alignment = .leading
        controls.frame = NSRect(x: 0, y: 0, width: 565, height: 269)
        tip.preferredMaxLayoutWidth = 565
        errorLabel.preferredMaxLayoutWidth = 565
        alert.accessoryView = controls
        alert.addButton(withTitle: move ? "Перенести" : "Копировать")
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = destination
    }

    static func present(on window: NSWindow, sources: [FileEntry], sourceDirectory: URL, passiveDirectory: URL,
                        move: Bool, cursorOnly: Bool, maskGroups: [String: String],
                        submit: @escaping ([LocalTransferDestination], LocalTransferOptions) throws -> Bool) {
        guard !sources.isEmpty, window.attachedSheet == nil else { return }
        let dialog = LocalTransferDialog(sources: sources, sourceDirectory: sourceDirectory, passiveDirectory: passiveDirectory,
                                        move: move, cursorOnly: cursorOnly, maskGroups: maskGroups)
        dialog.begin(on: window, submit: submit)
    }

    private func begin(on window: NSWindow,
                       submit: @escaping ([LocalTransferDestination], LocalTransferOptions) throws -> Bool) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.alert.window, event.keyCode == 109 else { return event }
            if event.modifierFlags.contains(.option) {
                self.chooseFolder(at: self.passiveDirectory)
            } else if event.modifierFlags.contains(.shift) {
                self.chooseFolder(at: self.enteredFolder())
            } else {
                self.chooseActiveFolder()
            }
            return nil
        }
        alert.beginSheetModal(for: window) { response in
            if let keyMonitor = self.keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            guard response == .alertFirstButtonReturn else { return }
            do {
                let (targets, options) = try self.capture()
                guard try submit(targets, options) else { return }
                self.remember(options: options)
            } catch {
                self.errorLabel.stringValue = error.localizedDescription
                DispatchQueue.main.async { self.begin(on: window, submit: submit) }
            }
        }
    }

    private func capture() throws -> ([LocalTransferDestination], LocalTransferOptions) {
        let targets = try LocalTransferDestination.parse(destination.stringValue, relativeTo: sourceDirectory,
                                                          multiple: !move && multiple.state == .on)
        try LocalTransferDestination.validateDistinctTargets(targets, sources: sourceURLs)
        let options = LocalTransferOptions(conflictPolicy: LocalTransferConflictPolicy.allCases[conflicts.indexOfSelectedItem],
                                           confirmReadOnly: readOnly.state == .on, preserveAllTimestamps: timestamps.state == .on,
                                           filterRules: useFilter.state == .on ? rules : [], maskGroups: maskGroups)
        try options.validateFilter()
        return (targets, options)
    }

    private func remember(options: LocalTransferOptions) {
        var settings = options
        settings.filterRules = rules
        settings.maskGroups = [:]
        if settings.conflictPolicy == .newer { settings.conflictPolicy = .ask }
        let defaults = AppPreferences.defaults
        if let encoded = try? JSONEncoder().encode(settings) { defaults.set(encoded, forKey: Self.settingsKey) }
        if !move { defaults.set(multiple.state == .on, forKey: Self.multipleKey) }
        defaults.set(useFilter.state == .on, forKey: "transfer.dialog.useFilter")
        let path = destination.stringValue
        let previous = defaults.stringArray(forKey: Self.historyKey) ?? []
        defaults.set(Array(([path] + previous.filter { $0 != path }).prefix(20)), forKey: Self.historyKey)
    }

    @objc private func toggleFilter() { filterButton.isEnabled = useFilter.state == .on }
    @objc private func editFilters() {
        guard alert.window.attachedSheet == nil else { return }
        LocalTransferFilters(rules: rules, groups: maskGroups).present(on: alert.window) { self.rules = $0 }
    }

    @objc private func chooseActiveFolder() { chooseFolder(at: sourceDirectory) }
    private func enteredFolder() -> URL {
        let url = (try? LocalTransferDestination.parse(destination.stringValue, relativeTo: sourceDirectory,
                                                       multiple: !move && multiple.state == .on))?.first?.url
        guard var url else { return sourceDirectory }
        while url.path != "/" {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { break }
            url.deleteLastPathComponent()
        }
        return url
    }
    private func chooseFolder(at initial: URL) {
        guard alert.window.attachedSheet == nil else { return }
        let chooser = NSOpenPanel()
        chooser.title = "Папка назначения"
        chooser.prompt = "Выбрать"
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = false
        chooser.directoryURL = initial
        chooser.beginSheetModal(for: alert.window) { response in
            guard response == .OK, let directory = chooser.url else { return }
            let path = Self.withSlash(directory.path)
            let append = !self.move && self.multiple.state == .on
            if append && path.contains("\"") {
                self.errorLabel.stringValue = "Папку с кавычкой в имени можно указать в режиме одного назначения."
                return
            }
            let value = append ? Self.quoteListPath(path) : path
            self.destination.stringValue = append && !self.destination.stringValue.isEmpty
                ? self.destination.stringValue + ";" + value : value
            self.alert.window.makeFirstResponder(self.destination)
        }
    }
    private static func withSlash(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }
    private static func quoteListPath(_ path: String) -> String {
        path.contains(",") || path.contains(";") || path != path.trimmingCharacters(in: .whitespacesAndNewlines)
            ? "\"\(path)\"" : path
    }

    static func smoke(in directory: URL) throws {
        let source = FileEntry(url: directory.appendingPathComponent("report.part.txt"), name: "report.part.txt",
                               isDirectory: false, isSymbolicLink: false, size: 10, modified: nil)
        let dialog = LocalTransferDialog(sources: [source], sourceDirectory: directory, passiveDirectory: directory,
                                         move: false, cursorOnly: true, maskGroups: [:])
        guard dialog.destination.stringValue == source.name, !dialog.useFilter.isEnabled, dialog.multiple.isEnabled else {
            throw LocalTransferSmokeError("Shift+F5 и параметры одиночного источника")
        }
        let sameDirectory = LocalTransferDialog(sources: [source], sourceDirectory: directory, passiveDirectory: directory,
                                                move: true, cursorOnly: false, maskGroups: [:])
        guard sameDirectory.destination.stringValue == source.name else {
            throw LocalTransferSmokeError("начальное имя F6 при совпадающих папках панелей")
        }
        for name in ["~report ", " report ", "\"report\""] {
            let literal = FileEntry(url: directory.appendingPathComponent(name), name: name,
                                    isDirectory: false, isSymbolicLink: false, size: 10, modified: nil)
            let local = LocalTransferDialog(sources: [literal], sourceDirectory: directory, passiveDirectory: directory,
                                            move: true, cursorOnly: false, maskGroups: [:])
            let (literalTargets, _) = try local.capture()
            guard literalTargets.first?.url.path == literal.url.path else {
                throw LocalTransferSmokeError("буквальное начальное имя с пробелом, кавычкой или тильдой")
            }
        }
        let otherDirectory = directory.appendingPathComponent("other")
        let differentDirectories = LocalTransferDialog(sources: [source], sourceDirectory: directory, passiveDirectory: otherDirectory,
                                                       move: false, cursorOnly: false, maskGroups: [:])
        guard differentDirectories.destination.stringValue == Self.withSlash(otherDirectory.path) else {
            throw LocalTransferSmokeError("начальная папка F5 при разных папках панелей")
        }
        dialog.destination.stringValue = "out/*.bak;\"other;folder/\""
        dialog.multiple.state = .on
        dialog.conflicts.selectItem(at: 4)
        let (targets, options) = try dialog.capture()
        guard targets.count == 2, targets[0].url.lastPathComponent == "*.bak", targets[1].forceDirectory,
              options.conflictPolicy == .append else { throw LocalTransferSmokeError("маска, список и политика F5") }
        let move = LocalTransferDialog(sources: [source, source], sourceDirectory: directory, passiveDirectory: directory,
                                       move: true, cursorOnly: false, maskGroups: [:])
        move.useFilter.state = .on
        move.rules = [LocalTransferFilterRule(action: .priorityExclude, mask: "*.tmp")]
        let (_, moveOptions) = try move.capture()
        guard !move.multiple.isEnabled, move.useFilter.isEnabled, moveOptions.filterRules == move.rules else {
            throw LocalTransferSmokeError("фильтр и параметры F6")
        }
    }
}

private struct LocalTransferSmokeError: LocalizedError {
    var errorDescription: String?
    init(_ check: String) { errorDescription = "Диалог операций: \(check)." }
}

@MainActor
private final class LocalTransferFilters: NSObject {
    private let alert = NSAlert()
    private let list = NSPopUpButton()
    private let groups: [String: String]
    private var rules: [LocalTransferFilterRule]

    init(rules: [LocalTransferFilterRule], groups: [String: String]) {
        self.rules = rules
        self.groups = groups
        super.init()
        alert.messageText = "Фильтры копирования и переноса"
        alert.informativeText = "Первое совпадение задаёт действие. Правила I и X имеют приоритет над + и −."
        list.widthAnchor.constraint(equalToConstant: 530).isActive = true
        list.setAccessibilityLabel("Правила фильтра")
        let buttons = [
            NSButton(title: "Добавить", target: self, action: #selector(addRule)),
            NSButton(title: "Изменить", target: self, action: #selector(editRule)),
            NSButton(title: "Удалить", target: self, action: #selector(removeRule)),
            NSButton(title: "Выше", target: self, action: #selector(moveUp)),
            NSButton(title: "Ниже", target: self, action: #selector(moveDown))
        ]
        let content = vertical([list, horizontal(buttons)], spacing: 10)
        content.frame = NSRect(x: 0, y: 0, width: 530, height: 63)
        alert.accessoryView = content
        alert.addButton(withTitle: "Применить фильтры")
        alert.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        reload()
    }
    func present(on parent: NSWindow, completion: @escaping ([LocalTransferFilterRule]) -> Void) {
        alert.beginSheetModal(for: parent) { response in
            if response == .alertFirstButtonReturn { completion(self.rules) }
        }
    }
    private func reload(select index: Int = 0) {
        list.removeAllItems()
        list.addItems(withTitles: rules.enumerated().map { index, rule in
            let name = rule.title.isEmpty ? rule.mask : rule.title
            return "\(index + 1). \(rule.action.rawValue) \(name.isEmpty ? "Все имена" : name)"
        })
        list.isEnabled = !rules.isEmpty
        if !rules.isEmpty { list.selectItem(at: min(index, rules.count - 1)) }
        else { list.addItem(withTitle: "Все объекты · нет правил") }
    }
    @objc private func addRule() {
        guard rules.count < 100 else { NSSound.beep(); return }
        edit(index: nil)
    }
    @objc private func editRule() {
        guard rules.indices.contains(list.indexOfSelectedItem) else { return }
        edit(index: list.indexOfSelectedItem)
    }
    @objc private func removeRule() {
        let index = list.indexOfSelectedItem
        guard rules.indices.contains(index) else { return }
        rules.remove(at: index)
        reload(select: index)
    }
    @objc private func moveUp() { reorder(offset: -1) }
    @objc private func moveDown() { reorder(offset: 1) }
    private func reorder(offset: Int) {
        let old = list.indexOfSelectedItem, new = old + offset
        guard rules.indices.contains(old), rules.indices.contains(new) else { return }
        rules.swapAt(old, new)
        reload(select: new)
    }
    private func edit(index: Int?) {
        guard alert.window.attachedSheet == nil else { return }
        let rule = index.map { rules[$0] } ?? LocalTransferFilterRule()
        let editor = NSAlert()
        editor.messageText = "Правило фильтра"
        let title = NSTextField(string: rule.title)
        let mask = NSTextField(string: rule.mask)
        mask.placeholderString = "Пусто — любая маска"
        let minSize = NSTextField(string: rule.minBytes.map { String($0) } ?? "")
        let maxSize = NSTextField(string: rule.maxBytes.map { String($0) } ?? "")
        minSize.placeholderString = "Например, 1K"
        maxSize.placeholderString = "Без ограничения"
        let actions = NSPopUpButton(), scopes = NSPopUpButton(), times = NSPopUpButton()
        actions.addItems(withTitles: ["+ Включить", "− Исключить", "I Включить с приоритетом", "X Исключить с приоритетом"])
        scopes.addItems(withTitles: ["Файлы и ссылки", "Папки", "Все объекты"])
        times.addItems(withTitles: ["Изменение", "Создание", "Доступ", "Смена метаданных"])
        actions.selectItem(at: LocalTransferFilterRule.Action.allCases.firstIndex(of: rule.action) ?? 0)
        scopes.selectItem(at: LocalTransferFilterRule.Scope.allCases.firstIndex(of: rule.scope) ?? 0)
        times.selectItem(at: LocalTransferFilterRule.TimeField.allCases.firstIndex(of: rule.timeField) ?? 0)
        let formatter = ISO8601DateFormatter()
        let earliest = NSTextField(string: rule.earliest.map(formatter.string(from:)) ?? "")
        let latest = NSTextField(string: rule.latest.map(formatter.string(from:)) ?? "")
        earliest.placeholderString = "2026-01-01T00:00:00Z"
        latest.placeholderString = "Без ограничения"
        let attributes: [(String, LocalTransferFilterRule.Attribute)] = [
            ("Только для чтения", .readOnly), ("Скрытый", .hidden), ("Символическая ссылка", .symbolicLink)
        ]
        let attributeFields = attributes.map { _, attribute in
            let field = NSPopUpButton()
            field.addItems(withTitles: ["Любой", "Требуется", "Исключить"])
            field.selectItem(at: rule.required.contains(attribute) ? 1 : rule.forbidden.contains(attribute) ? 2 : 0)
            return field
        }
        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.textColor = .systemRed
        errorLabel.preferredMaxLayoutWidth = 530
        func row(_ name: String, _ control: NSControl) -> NSStackView {
            let title = label(name, size: 12)
            title.widthAnchor.constraint(equalToConstant: 158).isActive = true
            control.widthAnchor.constraint(equalToConstant: 355).isActive = true
            control.setAccessibilityLabel(name)
            return horizontal([title, control])
        }
        var rows: [NSView] = [
            row("Название", title), row("Действие", actions), row("Объекты", scopes), row("Маска", mask),
            row("Размер от", minSize), row("Размер до", maxSize), row("Тип даты", times),
            row("Дата от (ISO 8601)", earliest), row("Дата до (ISO 8601)", latest)
        ]
        rows += zip(attributes, attributeFields).map { row($0.0.0, $0.1) }
        rows.append(errorLabel)
        let content = vertical(rows, spacing: 5)
        content.alignment = .leading
        content.frame = NSRect(x: 0, y: 0, width: 530, height: 356)
        editor.accessoryView = content
        editor.addButton(withTitle: "Сохранить правило")
        editor.addButton(withTitle: "Отмена").keyEquivalent = "\u{1b}"
        func date(_ field: NSTextField) throws -> Date? {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            guard let date = formatter.date(from: value) else { throw LocalTransferSmokeError("укажите дату в формате ISO 8601, например 2026-01-01T00:00:00Z") }
            return date
        }
        func show() {
            editor.beginSheetModal(for: alert.window) { response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    var required: LocalTransferFilterRule.Attribute = [], forbidden: LocalTransferFilterRule.Attribute = []
                    for ((_, attribute), field) in zip(attributes, attributeFields) {
                        if field.indexOfSelectedItem == 1 { required.insert(attribute) }
                        if field.indexOfSelectedItem == 2 { forbidden.insert(attribute) }
                    }
                    let updated = try LocalTransferFilterRule(
                        title: title.stringValue, action: LocalTransferFilterRule.Action.allCases[actions.indexOfSelectedItem],
                        scope: LocalTransferFilterRule.Scope.allCases[scopes.indexOfSelectedItem], mask: mask.stringValue,
                        minBytes: LocalTransferFilterRule.parseSize(minSize.stringValue), maxBytes: LocalTransferFilterRule.parseSize(maxSize.stringValue),
                        timeField: LocalTransferFilterRule.TimeField.allCases[times.indexOfSelectedItem],
                        earliest: date(earliest), latest: date(latest), required: required, forbidden: forbidden)
                    try LocalTransferOptions(filterRules: [updated], maskGroups: self.groups).validateFilter()
                    if let index { self.rules[index] = updated }
                    else { self.rules.append(updated) }
                    self.reload(select: index ?? self.rules.count - 1)
                } catch {
                    errorLabel.stringValue = error.localizedDescription
                    DispatchQueue.main.async { show() }
                }
            }
        }
        show()
    }
}
