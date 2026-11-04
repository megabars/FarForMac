import AppKit
import FarCore

/// A result click must establish keyboard focus as well as row selection.
/// AppKit can otherwise leave Return and arrows with the window responder.
private final class SearchResultsTable: NSTableView {
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// A search owns its worker and event stream; it never navigates a file panel
/// until the user explicitly invokes the reveal callback.
@MainActor
final class SearchWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let helpText = """
    РЕКУРСИВНЫЙ ПОИСК — Alt+F7

    Укажите абсолютные пути корневых папок, по одному в строке. Маска имени поддерживает те же выражения и группы, что файловые панели. Режим содержимого: без проверки, буквальная подстрока или регулярное выражение. Поиск содержимого применяется к обычным текстовым файлам UTF-8; недоступные, двоичные, слишком большие и неподдерживаемые объекты отмечаются в замечаниях.

    Даты вводятся как ГГГГ-ММ-ДД, по местному времени: «с» включает начало дня, «по» — весь указанный день. Пустые поля даты и размера снимают соответствующее ограничение. Размер задаётся в байтах. Ограничение чтения одного файла — от 1 до 64 МиБ; результатов — от 1 до 10000. Поиск прекращается при достижении лимита результатов.

    Скрытые объекты и переход по символическим ссылкам включаются отдельно. Типы определяют, какие объекты могут стать результатами; папки обходятся также при поиске только файлов. Циклы ссылок и специальные файлы не должны задерживать поиск.

    Cmd+Enter запускает поиск из любого поля; обычный Enter в списке корней добавляет новую строку. Результаты появляются по мере поиска. «Отменить» сохраняет уже найденные строки. Счётчики учитывают все замечания, внизу показаны первые 200. Параметры сохраняются, но поиск после открытия окна не запускается автоматически.

    Выберите результат: Enter или двойной щелчок — перейти к нему в файловой панели; F3 — просмотр, F4 — редактирование без смены каталогов панелей. Кнопка «Во временную панель» передаёт все найденные на этот момент результаты. Временная панель является снимком. Удалённые или заменённые объекты проверяются повторно перед действием.

    Поиск в архивах и удалённых провайдерах появится после подключения этих провайдеров. Сейчас поиск работает с локальной файловой системой.
    """

    private static let parametersKey = "search.parameters.v1"
    private static let issueLimit = 200
    private let maskGroups: [String: String]
    private let onReveal: (SearchResult) -> Void
    private let onOpen: (SearchResult, Bool) -> Void
    private let onSendToPanel: ([SearchResult]) -> Void
    private let roots = NSTextView()
    private let pattern = NSTextField(string: "*")
    private let query = NSTextField(string: "")
    private let contentMode = NSPopUpButton()
    private let caseSensitive = NSButton(checkboxWithTitle: "Учитывать регистр", target: nil, action: nil)
    private let hidden = NSButton(checkboxWithTitle: "Скрытые объекты", target: nil, action: nil)
    private let followLinks = NSButton(checkboxWithTitle: "Переходить по ссылкам", target: nil, action: nil)
    private let files = NSButton(checkboxWithTitle: "Файлы", target: nil, action: nil)
    private let directories = NSButton(checkboxWithTitle: "Папки", target: nil, action: nil)
    private let links = NSButton(checkboxWithTitle: "Ссылки", target: nil, action: nil)
    private let minSize = NSTextField(string: "")
    private let maxSize = NSTextField(string: "")
    private let afterDate = NSTextField(string: "")
    private let beforeDate = NSTextField(string: "")
    private let contentMB = NSTextField(string: "8")
    private let resultLimit = NSTextField(string: "10000")
    private let table = SearchResultsTable()
    private let issues = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "Задайте параметры и нажмите «Найти».")
    private let currentPath = NSTextField(labelWithString: "")
    private let issueHeading = NSTextField(labelWithString: "Ошибки и замечания: 0")
    private let progress = NSProgressIndicator()
    private lazy var startButton = button("Найти", #selector(startSearch))
    private lazy var cancelButton = button("Отменить", #selector(cancelSearch))
    private lazy var revealButton = button("Перейти ↵", #selector(revealSelected))
    private lazy var viewButton = button("F3 Просмотр", #selector(viewSelected))
    private lazy var editButton = button("F4 Правка", #selector(editSelected))
    private lazy var sendButton = button("Во временную панель", #selector(sendResults))
    private var results: [SearchResult] = []
    private var displayedIssues: [String] = []
    private var issueCount = 0
    private var cancellation: SearchCancellation?
    private var generation = UUID()
    private var keyMonitor: Any?
    private var parameterControls: [NSControl] = []
    private var retainedWhileOpen: SearchWindow?
    private(set) var isSearching = false
    var selectedResult: SearchResult? {
        results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
    }

    init(directory: URL, maskGroups: [String: String], onReveal: @escaping (SearchResult) -> Void,
         onOpen: @escaping (SearchResult, Bool) -> Void, onSendToPanel: @escaping ([SearchResult]) -> Void) {
        self.maskGroups = maskGroups
        self.onReveal = onReveal
        self.onOpen = onOpen
        self.onSendToPanel = onSendToPanel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Поиск файлов — Alt+F7"
        window.minSize = NSSize(width: 940, height: 730)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        configureContent()
        var options = SearchOptions(roots: [directory])
        if let data = AppPreferences.defaults.data(forKey: Self.parametersKey),
           let saved = try? JSONDecoder().decode(SearchOptions.self, from: data) { options = saved }
        restore(options)
        refreshActions()
        window.initialFirstResponder = pattern
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self
        installKeyMonitor()
        super.showWindow(sender)
    }

    func cancel() {
        guard isSearching else { return }
        cancellation?.cancel()
        cancelButton.isEnabled = false
        status.stringValue = "Отмена… Уже найденные результаты сохраняются."
    }

    func windowWillClose(_ notification: Notification) {
        persistParameters()
        cancellation?.cancel()
        generation = UUID() // Any callbacks already waiting for the main thread are stale.
        cancellation = nil
        isSearching = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        retainedWhileOpen = nil
    }

    private func configureContent() {
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = .command
        contentMode.addItems(withTitles: ["Без проверки", "Подстрока", "Regex"])
        contentMode.target = self; contentMode.action = #selector(modeChanged)
        configureTextView(roots, editable: true)
        roots.setAccessibilityLabel("Корневые папки, по одному абсолютному пути в строке")
        let rootScroll = scroll(roots)
        rootScroll.heightAnchor.constraint(equalToConstant: 58).isActive = true
        pattern.placeholderString = "Например: *.swift;*.txt|build*"
        pattern.setAccessibilityLabel("Маска имени")
        query.placeholderString = "Искомый текст или регулярное выражение"
        query.setAccessibilityLabel("Содержимое")
        for (field, placeholder, title) in [(minSize, "нет", "Минимальный размер в байтах"), (maxSize, "нет", "Максимальный размер в байтах"),
                                          (afterDate, "ГГГГ-ММ-ДД", "Изменён начиная с даты"), (beforeDate, "ГГГГ-ММ-ДД", "Изменён по дату включительно"),
                                          (contentMB, "1…64", "Лимит чтения файла в МиБ"), (resultLimit, "1…10000", "Лимит результатов")] {
            field.placeholderString = placeholder
            field.setAccessibilityLabel(title)
            field.widthAnchor.constraint(equalToConstant: field === afterDate || field === beforeDate ? 118 : 95).isActive = true
        }
        let choose = button("Добавить папку…", #selector(addRoot))
        parameterControls = [pattern, query, contentMode, caseSensitive, hidden, followLinks,
                             files, directories, links, minSize, maxSize, afterDate, beforeDate,
                             contentMB, resultLimit, choose]
        let rootTitle = row([text("Корневые папки — по одному пути в строке", bold: true), NSView(), choose])
        let nameRow = row([text("Маска имени:"), pattern])
        let contentRow = row([text("Содержимое:"), contentMode, query])
        query.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let flags = row([caseSensitive, hidden, followLinks, NSView()])
        let types = row([text("Типы:"), files, directories, links, NSView()])
        let sizes = row([text("Размер, байт: от"), minSize, text("до"), maxSize, NSView(), text("Читать файл до, МиБ:"), contentMB])
        let dates = row([text("Изменён с:"), afterDate, text("по:"), beforeDate, text("включительно; пусто — без границы", size: 11), NSView()])
        let limits = row([text("Максимум результатов:"), resultLimit, NSView(), startButton, cancelButton])
        let form = column([rootTitle, rootScroll, nameRow, contentRow, flags, types, sizes, dates, limits], spacing: 7)
        for view in [rootTitle, rootScroll, nameRow, contentRow, flags, types, sizes, dates, limits] {
            view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        table.delegate = self; table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.target = self; table.doubleAction = #selector(revealSelected)
        table.setAccessibilityLabel("Результаты рекурсивного поиска")
        for (identifier, title, width) in [("name", "Имя", 190.0), ("parent", "Родительская папка", 280.0), ("size", "Байт", 80.0),
                                           ("modified", "Изменён", 140.0), ("snippet", "Совпадение", 270.0)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            col.title = title; col.width = width; col.minWidth = 60
            table.addTableColumn(col)
        }
        let resultsScroll = scroll(table)
        resultsScroll.hasHorizontalScroller = true
        resultsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        configureTextView(issues, editable: false)
        issues.setAccessibilityLabel("Ошибки и замечания поиска")
        let issuesScroll = scroll(issues)
        issuesScroll.heightAnchor.constraint(equalToConstant: 85).isActive = true
        issueHeading.font = .systemFont(ofSize: 11, weight: .medium)
        status.font = .systemFont(ofSize: 12)
        status.isSelectable = true
        status.setAccessibilityLabel("Состояние поиска")
        currentPath.font = .systemFont(ofSize: 10)
        currentPath.textColor = .secondaryLabelColor
        currentPath.lineBreakMode = .byTruncatingMiddle
        currentPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        let statusRow = row([progress, status])
        let actions = row([revealButton, viewButton, editButton, NSView(), sendButton])
        let content = NSView()
        let stack = column([form, statusRow, currentPath, resultsScroll, actions, issueHeading, issuesScroll], spacing: 8)
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        for view in [form, statusRow, currentPath, resultsScroll, actions, issueHeading, issuesScroll] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.contentView = content
    }

    private func restore(_ options: SearchOptions) {
        roots.string = options.roots.map(\.path).joined(separator: "\n")
        pattern.stringValue = options.namePattern
        query.stringValue = options.contentQuery
        switch options.contentMode { case .none: contentMode.selectItem(at: 0); case .literal: contentMode.selectItem(at: 1); case .regex: contentMode.selectItem(at: 2) }
        caseSensitive.state = options.caseSensitive ? .on : .off
        hidden.state = options.includeHidden ? .on : .off
        followLinks.state = options.followSymbolicLinks ? .on : .off
        files.state = options.kinds.contains(.file) ? .on : .off
        directories.state = options.kinds.contains(.directory) ? .on : .off
        links.state = options.kinds.contains(.symbolicLink) ? .on : .off
        minSize.stringValue = options.minSize.map(String.init) ?? ""
        maxSize.stringValue = options.maxSize.map(String.init) ?? ""
        let formatter = dateFormatter()
        afterDate.stringValue = options.modifiedAfter.map { formatter.string(from: $0) } ?? ""
        beforeDate.stringValue = options.modifiedBefore.map { formatter.string(from: $0) } ?? ""
        contentMB.stringValue = String(max(1, min(64, options.maximumContentBytes / (1024 * 1024))))
        resultLimit.stringValue = String(max(1, min(10000, options.maximumResults)))
        modeChanged()
    }

    private struct InputError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private func readOptions() throws -> SearchOptions {
        let paths = roots.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !paths.isEmpty else { throw InputError(message: "Укажите хотя бы одну корневую папку.") }
        let expanded = paths.map { ($0 as NSString).expandingTildeInPath }
        guard expanded.allSatisfy({ ($0 as NSString).isAbsolutePath && !$0.contains("\0") }) else {
            throw InputError(message: "Для каждой корневой папки нужен абсолютный путь, по одному в строке.")
        }
        var options = SearchOptions(roots: expanded.map { URL(fileURLWithPath: $0).standardizedFileURL })
        options.namePattern = pattern.stringValue
        options.contentQuery = query.stringValue
        options.contentMode = contentMode.indexOfSelectedItem == 1 ? .literal : contentMode.indexOfSelectedItem == 2 ? .regex : .none
        options.caseSensitive = caseSensitive.state == .on
        options.includeHidden = hidden.state == .on
        options.followSymbolicLinks = followLinks.state == .on
        var kinds = Set<SearchFileKind>()
        if files.state == .on { kinds.insert(.file) }
        if directories.state == .on { kinds.insert(.directory) }
        if links.state == .on { kinds.insert(.symbolicLink) }
        guard !kinds.isEmpty else { throw InputError(message: "Выберите хотя бы один тип объектов.") }
        options.kinds = kinds
        options.minSize = try optionalSize(minSize, title: "Минимальный размер")
        options.maxSize = try optionalSize(maxSize, title: "Максимальный размер")
        if let low = options.minSize, let high = options.maxSize, low > high { throw InputError(message: "Минимальный размер больше максимального.") }
        options.modifiedAfter = try optionalDate(afterDate, upperBound: false)
        options.modifiedBefore = try optionalDate(beforeDate, upperBound: true)
        if let low = options.modifiedAfter, let high = options.modifiedBefore, low > high { throw InputError(message: "Начальная дата позже конечной.") }
        guard let mb = Int(contentMB.stringValue.trimmingCharacters(in: .whitespaces)), (1...64).contains(mb) else {
            throw InputError(message: "Лимит чтения файла должен быть целым числом от 1 до 64 МиБ.")
        }
        guard let limit = Int(resultLimit.stringValue.trimmingCharacters(in: .whitespaces)), (1...10000).contains(limit) else {
            throw InputError(message: "Лимит результатов должен быть целым числом от 1 до 10000.")
        }
        options.maximumContentBytes = mb * 1024 * 1024
        options.maximumResults = limit
        return options
    }

    private func optionalSize(_ field: NSTextField, title: String) throws -> Int64? {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        guard let value = Int64(raw), value >= 0 else { throw InputError(message: "\(title): введите неотрицательное целое число байт или очистите поле.") }
        return value
    }
    private func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
    private func optionalDate(_ field: NSTextField, upperBound: Bool) throws -> Date? {
        let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return nil }
        let formatter = dateFormatter()
        guard raw.count == 10, let date = formatter.date(from: raw), formatter.string(from: date) == raw else {
            throw InputError(message: "Дата должна иметь вид ГГГГ-ММ-ДД, например 2026-10-28, или быть пустой.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: date)
        if upperBound {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { throw InputError(message: "Не удалось определить конец дня.") }
            // The closest representable instant before midnight includes the
            // full day without accidentally excluding its final microsecond.
            return Date(timeIntervalSinceReferenceDate: nextDay.timeIntervalSinceReferenceDate.nextDown)
        }
        return start
    }

    private func persistParameters() {
        guard let options = try? readOptions(), let data = try? JSONEncoder().encode(options) else { return }
        AppPreferences.defaults.set(data, forKey: Self.parametersKey)
    }

    @objc private func startSearch() {
        guard !isSearching else { return }
        do {
            let options = try readOptions()
            let request = SearchRequest(options: options, maskGroups: maskGroups)
            try SearchEngine.validate(request)
            persistParameters()
            let id = UUID()
            generation = id
            let token = SearchCancellation()
            cancellation = token
            results.removeAll(keepingCapacity: true)
            displayedIssues.removeAll(keepingCapacity: true)
            issueCount = 0; issues.string = ""; currentPath.stringValue = ""
            issueHeading.stringValue = "Ошибки и замечания: 0"
            table.reloadData()
            isSearching = true
            status.stringValue = "Поиск… Просмотрено: 0 · Найдено: 0 · Замечаний: 0"
            progress.startAnimation(nil)
            refreshActions()
            // At most 64 events await delivery. The worker blocks at the batch
            // boundary, so a fast scan cannot flood the main dispatch queue.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var batch: [SearchEvent] = []
                var lastDelivery = Date.timeIntervalSinceReferenceDate
                func flush() {
                    guard !batch.isEmpty else { return }
                    let events = batch
                    batch.removeAll(keepingCapacity: true)
                    lastDelivery = Date.timeIntervalSinceReferenceDate
                    DispatchQueue.main.sync { self?.receive(events, generation: id) }
                }
                let summary = SearchEngine.run(request, cancellation: token) { event in
                    batch.append(event)
                    if batch.count >= 64 || Date.timeIntervalSinceReferenceDate - lastDelivery >= 0.08 { flush() }
                }
                flush()
                DispatchQueue.main.async { self?.finish(summary, generation: id) }
            }
        } catch {
            status.stringValue = error.localizedDescription
            status.textColor = .systemRed
        }
    }

    private func receive(_ events: [SearchEvent], generation id: UUID) {
        guard generation == id, isSearching else { return }
        var addedResults = false
        var addedIssues = false
        var latestProgress: SearchProgress?
        for event in events {
            switch event {
            case .result(let result):
                if results.count < 10000 { results.append(result); addedResults = true }
            case .issue(let issue):
                issueCount += 1
                if displayedIssues.count < Self.issueLimit {
                    // Keep issue text bounded even when an OS error embeds a long string.
                    displayedIssues.append("\(String(describing: issue.path).prefix(4096)): \(issue.message.prefix(2048))")
                    addedIssues = true
                }
            case .progress(let value): latestProgress = value
            }
        }
        if addedResults {
            let selection = table.selectedRow
            table.reloadData()
            if results.indices.contains(selection) { table.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
            refreshActions()
        }
        if addedIssues { issues.string = displayedIssues.joined(separator: "\n\n") }
        updateIssueHeading()
        if let latestProgress {
            status.stringValue = "Просмотрено: \(latestProgress.scanned) · Найдено: \(latestProgress.matches) · Замечаний: \(latestProgress.errors)"
            currentPath.stringValue = latestProgress.currentPath
            currentPath.toolTip = latestProgress.currentPath
        }
    }

    private func finish(_ summary: SearchSummary, generation id: UUID) {
        guard generation == id, isSearching else { return }
        isSearching = false; cancellation = nil
        progress.stopAnimation(nil)
        issueCount = max(issueCount, summary.errors)
        updateIssueHeading()
        status.stringValue = summary.summary
        currentPath.stringValue = ""
        refreshActions()
    }
    private func updateIssueHeading() {
        issueHeading.stringValue = "Ошибки и замечания: \(issueCount)" + (issueCount > Self.issueLimit ? " · показаны первые \(Self.issueLimit), остальные учтены в счётчике" : "")
    }

    @objc private func cancelSearch() { cancel() }
    @objc private func modeChanged() { query.isEnabled = !isSearching && contentMode.indexOfSelectedItem != 0 }
    @objc private func addRoot() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            var paths = self.roots.string.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for url in panel.urls where !paths.contains(url.path) { paths.append(url.path) }
            self.roots.string = paths.joined(separator: "\n")
        }
    }
    @objc private func revealSelected() { performSelected { onReveal($0) } }
    @objc private func viewSelected() { performSelected { onOpen($0, false) } }
    @objc private func editSelected() { performSelected { onOpen($0, true) } }
    private func performSelected(_ action: (SearchResult) -> Void) {
        guard let result = selectedResult else { NSSound.beep(); return }
        do { try result.verifyCurrent(); action(result) }
        catch { status.stringValue = error.localizedDescription; NSSound.beep() }
    }
    @objc private func sendResults() {
        guard !results.isEmpty else { return }
        onSendToPanel(results)
    }
    private func refreshActions() {
        parameterControls.forEach { $0.isEnabled = !isSearching }
        roots.isEditable = !isSearching
        modeChanged()
        startButton.isEnabled = !isSearching
        cancelButton.isEnabled = isSearching && cancellation?.isCancelled == false
        revealButton.isEnabled = selectedResult != nil
        viewButton.isEnabled = selectedResult != nil
        editButton.isEnabled = selectedResult != nil
        sendButton.isEnabled = !results.isEmpty
        if isSearching { status.textColor = .labelColor }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == [.command], event.keyCode == 36 || event.keyCode == 76 {
                self.startSearch()
                return nil
            }
            if modifiers.isEmpty {
                if self.window?.firstResponder === self.window, self.resultsHaveKeyboardFocus,
                   [UInt16(123), 124, 125, 126, 115, 119, 116, 121].contains(event.keyCode) {
                    self.window?.makeFirstResponder(self.table)
                    self.table.keyDown(with: event)
                    return nil
                }
                switch event.keyCode {
                case 99: self.viewSelected(); return nil // F3
                case 118: self.editSelected(); return nil // F4
                case 53: if self.isSearching { self.cancel(); return nil }
                case 36, 76:
                    if self.resultsHaveKeyboardFocus { self.revealSelected(); return nil }
                default: break
                }
            }
            return event
        }
    }

    private var resultsHaveKeyboardFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === table { return true }
        // Accessibility row selection may retain the window itself as responder.
        if responder === window { return selectedResult != nil }
        return (responder as? NSView)?.isDescendant(of: table) == true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshActions() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let result = results[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")
        let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle
        switch identifier.rawValue {
        case "name": field.stringValue = (result.isSymbolicLink ? "↗ " : result.isDirectory ? "▸ " : "") + result.name
        case "parent": field.stringValue = result.url.deletingLastPathComponent().path
        case "size": field.stringValue = String(result.size); field.alignment = .right
        case "modified": field.stringValue = result.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—"
        default: field.stringValue = result.snippet.map { (result.lineNumber.map { "\($0): " } ?? "") + $0 } ?? ""
        }
        field.toolTip = identifier.rawValue == "snippet" ? result.snippet : result.url.path
        return field
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func text(_ value: String, size: CGFloat = 12, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        return field
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal; stack.spacing = 8
        return stack
    }
    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    private func scroll(_ view: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }
    private func configureTextView(_ view: NSTextView, editable: Bool) {
        view.isRichText = false; view.isEditable = editable; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false; view.isAutomaticSpellingCorrectionEnabled = false
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 6, height: 5)
    }
}
