import AppKit
import FarCore

/// Immediate-directory comparison and a read-only directional sync preview.
@MainActor
final class DirectoryComparisonWindow: FileToolsWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let left: URL
    private let right: URL
    private let onMarkDifferences: ([URL], [URL]) -> Void
    private let compareContents = NSButton(checkboxWithTitle: "Проверить байты файлов", target: nil, action: nil)
    private let caseSensitive = NSButton(checkboxWithTitle: "Учитывать регистр имён", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "Скрытые объекты", target: nil, action: nil)
    private let direction = NSPopUpButton()
    private let table = NSTableView()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private lazy var startButton = button("Сравнить ⌘↵", #selector(startComparison))
    private lazy var cancelButton = button("Закрыть Esc", #selector(cancelOrClose))
    private lazy var markButton = button("Пометить отличия ⌘M", #selector(markDifferences))
    private lazy var planButton = button("Предпросмотр плана ⌘P", #selector(makePlan))
    private var report: DirectoryComparisonReport?
    private var cancellation: DirectoryComparisonCancellation?
    private var generation = UUID()

    init(left: URL, right: URL, onMarkDifferences: @escaping ([URL], [URL]) -> Void) {
        self.left = left; self.right = right; self.onMarkDifferences = onMarkDifferences
        super.init(title: "Сравнение каталогов", width: 980, height: 760)
        window?.minSize = NSSize(width: 800, height: 650)
        hidden.state = .on
        direction.addItems(withTitles: ["Слева → направо", "Справа → налево"])
        direction.target = self; direction.action = #selector(directionChanged)
        for control in [compareContents, caseSensitive, hidden] {
            control.target = self; control.action = #selector(parametersChanged)
        }
        configureTable()
        preview.isEditable = false; preview.isRichText = false
        preview.isSelectable = true; preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.setAccessibilityLabel("Предпросмотр синхронизации и замечания")
        details.isSelectable = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        let planScroll = NSScrollView(); planScroll.documentView = preview; planScroll.hasVerticalScroller = true
        planScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let paths = NSTextField(wrappingLabelWithString: "Слева: \(left.path)\nСправа: \(right.path)")
        paths.isSelectable = true
        let help = NSTextField(wrappingLabelWithString: "Сравниваются обычные файлы непосредственно в этих папках по имени, размеру и точному времени изменения. Вложенные папки, ссылки и специальные файлы показаны как пропущенные. Предел: 10 000 записей на папку, 64 МиБ на файл, 512 МиБ чтения всего. Помечаются отсутствующие и более новые файлы; при равном времени и отличии размера или байтов — обе стороны. Пометки доступны только для видимых строк файловых панелей; скрытые и отфильтрованные строки не помечаются. План показывает выбранное направление; данные не изменяются.")
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = .command
        markButton.keyEquivalent = "m"; markButton.keyEquivalentModifierMask = .command
        planButton.keyEquivalent = "p"; planButton.keyEquivalentModifierMask = .command
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        status.stringValue = "Выберите параметры и нажмите «Сравнить». Проверка байтов выключена."
        content([paths, help, row([compareContents, caseSensitive, hidden]),
                 row([startButton, cancelButton, markButton]), scroll, details,
                 row([direction, planButton]), planScroll, status])
        refreshActions()
        window?.initialFirstResponder = startButton
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    override func windowWillClose(_ notification: Notification) {
        cancellation?.cancel(); generation = UUID()
        super.windowWillClose(notification)
    }

    private func configureTable() {
        for (id, title, width) in [("name", "Имя", 240.0), ("status", "Сравнение", 260.0),
                                   ("left", "Слева: байты / время", 230.0), ("right", "Справа: байты / время", 230.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false; table.rowHeight = 24
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Результаты сравнения каталогов")
    }
    func numberOfRows(in tableView: NSTableView) -> Int { report?.rows.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let report, report.rows.indices.contains(row) else { return nil }
        let result = report.rows[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = result.name
        case "left": text = metadata(result.left)
        case "right": text = metadata(result.right)
        default: text = result.status.description
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle; label.toolTip = text
        return label
    }
    private func metadata(_ item: DirectoryComparisonItem?) -> String {
        guard let item else { return "—" }
        return "\(item.size) / \(item.modified.formatted(date: .numeric, time: .standard))"
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let report, report.rows.indices.contains(table.selectedRow) else { details.stringValue = ""; return }
        let row = report.rows[table.selectedRow]
        details.stringValue = "\(row.name) — \(row.status.description). \(row.detail)\n\(row.left?.url.path ?? "Нет слева")\n\(row.right?.url.path ?? "Нет справа")"
    }
    private func refreshActions() {
        startButton.isEnabled = !isWorking
        markButton.isEnabled = !isWorking && report?.isComplete == true
        planButton.isEnabled = !isWorking && report?.isComplete == true
        for control in [compareContents, caseSensitive, hidden] { control.isEnabled = !isWorking }
        direction.isEnabled = !isWorking
        cancelButton.title = isWorking ? "Отменить Esc" : "Закрыть Esc"
    }
    @objc private func parametersChanged() {
        report = nil; table.reloadData(); preview.string = ""; details.stringValue = ""
        status.stringValue = "Параметры изменены. Повторите сравнение."
        refreshActions()
    }
    @objc private func directionChanged() {
        preview.string = "Направление изменено. Постройте новый предпросмотр плана."
    }
    @objc private func cancelOrClose() {
        if isWorking {
            cancellation?.cancel()
            status.stringValue = "Отмена проверки…"
        } else { close() }
    }
    @objc private func startComparison() {
        guard !isWorking else { return }
        var options = DirectoryComparisonOptions()
        options.compareContents = compareContents.state == .on
        options.caseSensitiveNames = caseSensitive.state == .on
        options.includeHidden = hidden.state == .on
        let selectedOptions = options
        let token = DirectoryComparisonCancellation(), id = UUID()
        cancellation = token; generation = id; isWorking = true; report = nil
        table.reloadData(); preview.string = ""; details.stringValue = ""
        status.stringValue = "Чтение каталогов…"; refreshActions()
        let l = left, r = right
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DirectoryComparisonEngine.run(left: l, right: r, options: selectedOptions, cancellation: token) { count in
                if count % 100 == 0 {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        self.status.stringValue = "Сравнено строк: \(count)…"
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == id else { return }
                self.report = result; self.isWorking = false; self.cancellation = nil
                self.table.reloadData()
                self.preview.string = result.issues.isEmpty ? "План ещё не построен. Выберите направление и нажмите «Предпросмотр плана»." : result.issues.joined(separator: "\n")
                let outcome = result.cancelled ? "Сравнение отменено" : (result.isComplete ? "Сравнение завершено" : "Сравнение неполное")
                let skipped = result.rows.filter { [.directorySkipped, .symbolicLinkSkipped, .unsupported, .ambiguousName, .typeConflict, .error].contains($0.status) }.count
                self.status.stringValue = "\(outcome). Строк: \(result.rows.count); пропусков/конфликтов: \(skipped); прочитано байт: \(result.contentBytesRead). \(result.isComplete ? "" : "Пометка и план недоступны; повторите проверку.")"
                self.refreshActions()
                if !result.rows.isEmpty {
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.window?.makeFirstResponder(self.table)
                }
            }
        }
    }
    /// Revalidation itself is cancellable and stays away from the UI thread.
    private func withCurrentReport(prepare: @escaping (DirectoryComparisonReport, DirectoryComparisonCancellation) -> String? = { _, _ in nil },
                                   _ completion: @escaping (DirectoryComparisonReport, String?) -> Void) {
        guard !isWorking, let report, report.isComplete else { return }
        let token = DirectoryComparisonCancellation(), id = generation
        cancellation = token; isWorking = true; status.stringValue = "Проверка актуальности снимка…"; refreshActions()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try report.verifyCurrent(cancellation: token); return prepare(report, token) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == id else { return }
                self.isWorking = false; self.cancellation = nil
                if token.isCancelled { self.status.stringValue = "Проверка отменена."; self.refreshActions(); return }
                switch outcome {
                case .success(let prepared): completion(report, prepared)
                case .failure(let error):
                    self.report = nil; self.table.reloadData(); self.details.stringValue = ""
                    self.preview.string = "Снимок устарел. Повторите сравнение."
                    self.status.stringValue = error.localizedDescription
                }
                self.refreshActions()
            }
        }
    }
    @objc private func markDifferences() {
        withCurrentReport { [weak self] report, _ in
            guard let self else { return }
            self.onMarkDifferences(report.markedLeftURLs, report.markedRightURLs)
            self.status.stringValue = "Пометка передана файловым панелям: слева \(report.markedLeftURLs.count), справа \(report.markedRightURLs.count). Снимок может устареть при внешнем изменении."
        }
    }
    @objc private func makePlan() {
        let selectedDirection: DirectorySyncDirection = direction.indexOfSelectedItem == 0 ? .leftToRight : .rightToLeft
        withCurrentReport(prepare: { report, token in
            let entries = report.syncPreview(selectedDirection)
            let heading = selectedDirection == .leftToRight ? "СЛЕВА → НАПРАВО" : "СПРАВА → НАЛЕВО"
            var lines = ["\(heading) — ТОЛЬКО ПРЕДПРОСМОТР. ДАННЫЕ НЕ ИЗМЕНЯЮТСЯ."]
            if entries.count > 1_000 { lines.append("Показаны первые 1000 из \(entries.count) строк плана. Остальные результаты доступны в таблице сравнения.") }
            for entry in entries.prefix(1_000) {
                if token.isCancelled { return nil }
                lines.append("\(entry.action.description): \(entry.name)\n  Источник: \(entry.source?.path ?? "—")\n  Назначение: \(entry.destination.path)\n  \(entry.detail)")
            }
            return lines.joined(separator: "\n\n")
        }) { [weak self] _, text in
            guard let self, let text else { return }
            self.preview.string = text
            self.status.stringValue = "План построен по проверенному снимку; показано до 1000 строк. Удаление не предлагается. Выполнение синхронизации в этом окне отсутствует."
        }
    }
}
