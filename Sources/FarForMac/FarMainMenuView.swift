import AppKit

/// Keyboard-driven FAR menu inside the file manager window.
@MainActor final class FarMainMenuView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Section: Int, CaseIterable {
        case left, files, commands, options, right

        @MainActor var title: String {
            let names: (ru: String, en: String)
            switch self {
            case .left: names = ("Левая", "Left")
            case .files: names = ("Файлы", "Files")
            case .commands: names = ("Команды", "Commands")
            case .options: names = ("Параметры", "Options")
            case .right: names = ("Правая", "Right")
            }
            return L10n.language == .english ? names.en : names.ru
        }
    }

    struct Item {
        let id: String
        let title: String
        var shortcut = ""
        var checked = false
        var action: (() -> Void)? = nil
    }

    private let headings = NSStackView()
    private let scroll = NSScrollView()
    private let table = FileTable()
    private var buttons: [NSButton] = []
    private var rows: [Section: [Item?]] = [:]
    private var lastCommand: (section: Section, id: String)?
    private var rightPanelActive = false
    private var position: NSLayoutConstraint?
    private var preferredHeight: NSLayoutConstraint?
    private weak var previousResponder: NSResponder?

    private(set) var selectedSection: Section = .left
    private(set) var isExpanded = false
    var isPresented: Bool { superview != nil }
    var selectedCommandID: String? { item(at: table.selectedRow)?.id }
    private var items: [Item?] { rows[selectedSection] ?? [] }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("FarForMac F9")
        headings.orientation = .horizontal
        headings.spacing = 6
        headings.distribution = .fill
        for section in Section.allCases {
            let button = NSButton(title: section.title, target: self, action: #selector(chooseSection))
            button.tag = section.rawValue
            button.bezelStyle = .recessed
            button.setButtonType(.toggle)
            button.setContentHuggingPriority(.required, for: .horizontal)
            headings.addArrangedSubview(button)
            buttons.append(button)
        }
        headings.addArrangedSubview(NSView())
        let bar = inset(headings, x: 10, y: 5, color: Palette.raised)
        bar.translatesAutoresizingMaskIntoConstraints = false

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseItem)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.focusRingType = .none
        table.backgroundColor = Palette.panel
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let title = NSTableColumn(identifier: .init("title"))
        title.width = 285
        table.addTableColumn(title)
        let shortcut = NSTableColumn(identifier: .init("shortcut"))
        shortcut.width = 89
        shortcut.minWidth = 89
        table.addTableColumn(shortcut)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.isHidden = true
        addSubview(bar)
        addSubview(scroll)
        let height = scroll.heightAnchor.constraint(equalToConstant: 0)
        height.priority = .defaultHigh
        preferredHeight = height
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            scroll.widthAnchor.constraint(equalToConstant: 380),
            scroll.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            height
        ])
        updateHeadings()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    func present(in host: NSView, rightPanelActive: Bool, restoringLast: Bool, rows: [Section: [Item?]]) {
        guard !isPresented else { return }
        self.rows = rows
        self.rightPanelActive = rightPanelActive
        previousResponder = host.window?.firstResponder
        host.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: host.topAnchor), bottomAnchor.constraint(equalTo: host.bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor), trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        let last = restoringLast ? lastCommand : nil
        selectedSection = last?.section ?? (rightPanelActive ? .right : .left)
        for section in Section.allCases { buttons[section.rawValue].title = section.title }
        updateHeadings()
        if restoringLast { expand(preferred: last?.id) }
        host.window?.makeFirstResponder(self)
    }

    func dismiss() {
        guard isPresented else { return }
        let owner = window
        collapse()
        removeFromSuperview()
        rows = [:]
        table.reloadData()
        if let previousResponder { owner?.makeFirstResponder(previousResponder) }
        previousResponder = nil
    }

    override func mouseDown(with event: NSEvent) { dismiss() }

    func handleKey(_ event: NSEvent) {
        guard isPresented, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return }
        switch event.keyCode {
        case 53, 109:
            if isExpanded { collapse() } else { dismiss() }
        case 48:
            let target: Section
            switch selectedSection {
            case .left: target = .right
            case .right: target = .left
            default: target = rightPanelActive ? .left : .right
            }
            selectSection(target, expand: isExpanded)
        case 123, 124:
            let count = Section.allCases.count
            let offset = event.keyCode == 123 ? -1 : 1
            let next = (selectedSection.rawValue + offset + count) % count
            selectSection(Section.allCases[next], expand: isExpanded)
        case 115, 119:
            if isExpanded {
                moveSelection(toEnd: event.keyCode == 119)
            } else {
                selectSection(event.keyCode == 115 ? .left : .right, expand: false)
            }
        case 125, 126:
            if isExpanded { moveSelection(by: event.keyCode == 125 ? 1 : -1) }
            else { expand() }
        case 36, 76:
            if isExpanded { execute(at: table.selectedRow) } else { expand() }
        default: break
        }
    }

    private func selectSection(_ section: Section, expand shouldExpand: Bool) {
        selectedSection = section
        updateHeadings()
        if shouldExpand { expand() }
    }

    private func updateHeadings() {
        for section in Section.allCases {
            buttons[section.rawValue].state = section == selectedSection ? .on : .off
        }
        position?.isActive = false
        position = scroll.leadingAnchor.constraint(equalTo: buttons[selectedSection.rawValue].leadingAnchor)
        position?.isActive = true
    }

    private func expand(preferred: String? = nil) {
        isExpanded = true
        preferredHeight?.constant = CGFloat(items.count) * table.rowHeight + 2
        table.setAccessibilityLabel(selectedSection.title)
        scroll.isHidden = false
        table.reloadData()
        let enabled = selectableRows()
        if let row = enabled.first(where: { item(at: $0)?.id == preferred }) ?? enabled.first {
            selectRow(row)
        } else {
            table.deselectAll(nil)
        }
    }

    private func collapse() {
        isExpanded = false
        scroll.isHidden = true
        preferredHeight?.constant = 0
    }

    private func moveSelection(by offset: Int) {
        let enabled = selectableRows()
        guard !enabled.isEmpty else { return }
        let current = enabled.firstIndex(of: table.selectedRow) ?? 0
        selectRow(enabled[(current + offset + enabled.count) % enabled.count])
    }

    private func moveSelection(toEnd: Bool) {
        let enabled = selectableRows()
        if let row = toEnd ? enabled.last : enabled.first { selectRow(row) }
    }

    private func selectRow(_ row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func item(at row: Int) -> Item? { items.indices.contains(row) ? items[row] : nil }
    private func selectableRows() -> [Int] { items.indices.filter { item(at: $0)?.action != nil } }

    @objc private func chooseSection(_ sender: NSButton) {
        guard let section = Section(rawValue: sender.tag) else { return }
        selectSection(section, expand: true)
        window?.makeFirstResponder(self)
    }

    @objc private func chooseItem() { execute(at: table.clickedRow) }

    private func execute(at row: Int) {
        guard let item = item(at: row), let action = item.action else { return }
        lastCommand = (selectedSection, item.id)
        dismiss()
        action()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { item(at: row)?.action != nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = FileRow()
        view.active = true
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let isTitle = column?.identifier.rawValue == "title"
        guard let item = item(at: row) else {
            return label(isTitle ? " ────────────────────────────────" : "", color: Palette.muted)
        }
        let title = isTitle ? (item.checked ? " ✓  " : "     ") + item.title : item.shortcut
        let field = label(title, size: 12, color: item.action == nil ? Palette.muted : Palette.text)
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityEnabled(item.action != nil)
        return field
    }
}
