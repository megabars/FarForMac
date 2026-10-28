import AppKit
import FarCore

extension FileSort {
    var title: String {
        switch self {
        case .name: return "Имя"
        case .size: return "Размер"
        case .modified: return "Изменён"
        case .extension: return "Расширение"
        case .created: return "Создан"
        case .accessed: return "Последний доступ"
        case .selected: return "Пометки"
        }
    }
}

@MainActor
final class PanelSettingsWindow: NSWindowController {
    private let panel: PanelView
    private let sortPicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let ascending = NSButton(checkboxWithTitle: "По возрастанию", target: nil, action: nil)
    private let directories = NSButton(checkboxWithTitle: "Папки первыми", target: nil, action: nil)
    private let caseSensitive = NSButton(checkboxWithTitle: "Учитывать регистр", target: nil, action: nil)
    private let natural = NSButton(checkboxWithTitle: "Естественный порядок: file2 перед file10", target: nil, action: nil)
    private let colors = NSButton(checkboxWithTitle: "Раскрашивать папки, ссылки, программы и архивы", target: nil, action: nil)
    private var columns: [String: NSButton] = [:]
    private let modes: [PanelDisplayMode] = [.brief, .full, .custom]

    init(panel: PanelView) {
        self.panel = panel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 590), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Настройки \(panel.locationKey == "left" ? "левой" : "правой") панели"
        window.isReleasedWhenClosed = false
        window.center()
        window.backgroundColor = Palette.background
        sortPicker.addItems(withTitles: FileSort.allCases.map(\.title))
        sortPicker.selectItem(at: FileSort.allCases.firstIndex(of: panel.sortOptions.sort) ?? 0)
        modePicker.addItems(withTitles: ["Краткий — только имя", "Полный — основные сведения", "Свои колонки"])
        modePicker.selectItem(at: modes.firstIndex(of: panel.displayMode) ?? 1)
        modePicker.target = self; modePicker.action = #selector(modeChanged)
        ascending.state = panel.sortOptions.ascending ? .on : .off
        directories.state = panel.sortOptions.directoriesFirst ? .on : .off
        caseSensitive.state = panel.sortOptions.caseSensitive ? .on : .off
        natural.state = panel.sortOptions.naturalOrder ? .on : .off
        colors.state = panel.colorizeFiles ? .on : .off
        let heading = label("Вид и сортировка", size: 19, bold: true)
        let note = label("Настройки сохраняются отдельно для каждой панели.", color: Palette.muted)
        let rows = NSStackView()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10
        for view in [heading, note, horizontal([label("Сортировать по", bold: true), sortPicker]), ascending, directories, caseSensitive, natural, horizontal([label("Режим", bold: true), modePicker]), colors] { rows.addArrangedSubview(view) }
        rows.addArrangedSubview(label("Колонки в своём режиме (имя всегда видно)", bold: true))
        let columnNames = [("size", "Размер"), ("modified", "Изменён"), ("extension", "Расширение"), ("created", "Создан"), ("accessed", "Доступ"), ("permissions", "Права POSIX"), ("owner", "Владелец")]
        for chunk in stride(from: 0, to: columnNames.count, by: 3) {
            let group = horizontal([])
            for (id, title) in columnNames[chunk..<min(chunk + 3, columnNames.count)] {
                let checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
                checkbox.state = panel.customColumnIDs.contains(id) ? .on : .off
                columns[id] = checkbox; group.addArrangedSubview(checkbox)
            }
            rows.addArrangedSubview(group)
        }
        let hint = label("При большом числе колонок доступна горизонтальная прокрутка.", size: 11, color: Palette.muted)
        rows.addArrangedSubview(hint)
        let apply = NSButton(title: "Применить", target: self, action: #selector(applySettings))
        apply.bezelStyle = .rounded; apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(cancelSettings))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let actions = horizontal([NSView(), cancel, apply])
        let content = NSView()
        for item in [rows, actions] { item.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(item) }
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            actions.topAnchor.constraint(greaterThanOrEqualTo: rows.bottomAnchor, constant: 20),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22)
        ])
        window.contentView = content
        modeChanged()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func modeChanged() { columns.values.forEach { $0.isEnabled = modePicker.indexOfSelectedItem == 2 } }
    @objc private func cancelSettings() { close() }
    @objc private func applySettings() {
        panel.setSortOptions(FileSortOptions(sort: FileSort.allCases[sortPicker.indexOfSelectedItem], ascending: ascending.state == .on, directoriesFirst: directories.state == .on, caseSensitive: caseSensitive.state == .on, naturalOrder: natural.state == .on))
        let mode = modes[modePicker.indexOfSelectedItem]
        panel.setDisplayMode(mode)
        if mode == .custom {
            panel.setVisibleColumns(Set(columns.compactMap { $0.value.state == .on ? $0.key : nil }).union(["name"]))
        }
        panel.setColorizeFiles(colors.state == .on)
        close()
    }
}

@MainActor
final class MaskGroupsWindow: NSWindowController {
    private let textView = NSTextView()
    private let errorLabel = label("", size: 11, color: .systemRed)
    private let onSave: ([String: String]) -> Void

    init(groups: [String: String], onSave: @escaping ([String: String]) -> Void) {
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Группы масок"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 360)
        window.center()
        textView.isRichText = false; textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = groups.keys.sorted().map { "\($0)=\(groups[$0]!)" }.joined(separator: "\n")
        textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true
        let scroll = NSScrollView(); scroll.documentView = textView; scroll.hasVerticalScroller = true
        let intro = label("Одна группа в строке: имя=маска. Применение: <text>|README*", color: Palette.text)
        let save = NSButton(title: "Сохранить", target: self, action: #selector(saveGroups))
        save.bezelStyle = .rounded; save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "Отмена", target: self, action: #selector(closeGroups)); cancel.bezelStyle = .rounded
        let actions = horizontal([NSView(), cancel, save])
        let content = NSView()
        for item in [intro, scroll, errorLabel, actions] { item.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(item) }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            errorLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8), errorLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            actions.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12), actions.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), actions.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.contentView = content
        window.initialFirstResponder = textView
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func closeGroups() { close() }
    @objc private func saveGroups() {
        var groups: [String: String] = [:]
        for line in textView.string.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { errorLabel.stringValue = "Нужен формат имя=маска в каждой строке."; return }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 64, name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }), groups[name] == nil else { errorLabel.stringValue = "Имя группы должно быть уникальным: буквы, цифры, _, - или точка."; return }
            groups[name] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        do {
            guard groups.count <= 100 else { errorLabel.stringValue = "Допустимо не более 100 групп."; return }
            for name in groups.keys { _ = try FileMask("<\(name)>", groups: groups) }
            onSave(groups)
            close()
        } catch { errorLabel.stringValue = error.localizedDescription }
    }
}

@MainActor
final class HelpWindow: NSWindowController {
    private let textView = NSTextView()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 730, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false; window.center()
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        textView.isEditable = false; textView.isSelectable = true; textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView; window.contentView = scroll
        window.minSize = NSSize(width: 540, height: 340)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(title: String, text: String) {
        window?.title = title + " — справка"
        textView.string = text
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        showWindow(nil)
    }
}
