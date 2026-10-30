import AppKit
import FarCore

// Worker callbacks wait on these one-shot answers, never on the main thread.
private final class TransferAnswer<Value> {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var value: Value?

    var isResolved: Bool {
        lock.lock(); defer { lock.unlock() }
        return value != nil
    }
    func resolve(_ answer: Value) {
        lock.lock()
        guard value == nil else { lock.unlock(); return }
        value = answer
        lock.unlock()
        ready.signal()
    }
    func wait(cancellation: TransferCancellation, fallback: Value) -> Value {
        while ready.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            if cancellation.isCancelled { resolve(fallback) }
        }
        lock.lock(); defer { lock.unlock() }
        return value ?? fallback
    }
}

// Coalesce fast file writes so that progress cannot flood the main event queue.
private final class TransferProgressRelay {
    private let lock = NSLock()
    private var latest: TransferProgress?
    private var scheduled = false
    private let deliver: @MainActor (TransferProgress) -> Void

    init(deliver: @escaping @MainActor (TransferProgress) -> Void) { self.deliver = deliver }
    func submit(_ progress: TransferProgress) {
        lock.lock()
        latest = progress
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            let snapshot = latest
            latest = nil
            scheduled = false
            lock.unlock()
            if let snapshot { deliver(snapshot) }
        }
    }
}

@MainActor
final class FileOperationQueue: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let helpText = """
    ОЧЕРЕДЬ ФАЙЛОВЫХ ОПЕРАЦИЙ

    F5 и F6 добавляют копирование или перенос в общую очередь. Задания выполняются последовательно в порядке добавления. Пока операция работает, обе файловые панели доступны для навигации и добавления следующих заданий.

    Верхняя шкала показывает байты текущего файла, нижняя — байты всего задания и число обработанных объектов. Непустые папки являются контейнерами; в счётчик входят файлы, ссылки и пустые папки. При подготовке объём ещё может быть неизвестен.

    Выберите строку и нажмите «Отменить выбранное», чтобы удалить ожидающее задание или запросить отмену текущего. «Отменить всё» отменяет ожидающие задания и текущую операцию. Уже завершённые изменения сохраняются; отмена не откатывает скопированные или перенесённые объекты. Закрытие окна не останавливает очередь.

    При совпадении имён доступны замена, пропуск, новое имя и отмена. Для двух папок используется отдельное объединение содержимого; дерево назначения не заменяется. «Для всех таких конфликтов» действует только до конца текущего задания, отдельно для объединений папок и остальных совпадений.

    При ошибке можно повторить текущий объект, пропустить его и продолжить либо отменить задание. Подробности и ошибки выбранного задания доступны в журнале. «Повторить задание» заново ставит все его исходные пути в конец очереди; уже существующие файлы снова вызовут проверку конфликтов.

    Журнал хранит до 100 заданий. После аварийного завершения сохранённые ожидавшие и выполнявшиеся задания отмечаются как прерванные; автоматического возобновления нет. Проверьте источники и назначение: завершённые файлы остаются, а при сбое могут остаться скрытые временные объекты .farmac-transfer-*. Повтор создаёт новое задание, а не продолжает незавершённый файл.
    """

    private enum State: String, Codable {
        case queued, running, cancelling, completed, partial, failed, cancelled, interrupted
        var pending: Bool { self == .queued || self == .running || self == .cancelling }
        var title: String {
            switch self {
            case .queued: return "Ожидает"
            case .running: return "Выполняется"
            case .cancelling: return "Отмена…"
            case .completed: return "Завершено"
            case .partial: return "С пропусками / ошибками"
            case .failed: return "Ошибка"
            case .cancelled: return "Отменено"
            case .interrupted: return "Прервано при выходе"
            }
        }
    }
    private struct Job: Codable {
        let id: UUID
        let sources: [String]
        let destination: String
        let move: Bool
        let created: Date
        var state: State
        var summary: String
        var issues: [String]
        var temporarySources: Bool? = nil
        var request: TransferRequest {
            TransferRequest(sources: sources.map { URL(fileURLWithPath: $0) }, destination: URL(fileURLWithPath: destination), move: move)
        }
        var title: String { "\(move ? "Перенос" : "Копирование"): \(sources.count == 1 ? URL(fileURLWithPath: sources[0]).lastPathComponent : "\(sources.count) исходных объектов")" }
    }

    var canEnqueue: (() -> Bool)?
    var onChange: (() -> Void)?
    var onFinished: ((TransferResult) -> Void)?
    var hasPendingOperations: Bool { jobs.contains { $0.state.pending } }
    private var jobs: [Job] = []
    private var temporaryResources: [UUID: AnyObject] = [:]
    // Keep the enqueue-time source fingerprints captured by TransferRequest.
    private var runtimeRequests: [UUID: TransferRequest] = [:]
    private var activeID: UUID?
    private var cancellation: TransferCancellation?
    private var cancelDecision: (() -> Void)?
    private var decisionAlert: NSAlert?
    private var conflictPolicies: [Bool: TransferDecision] = [:]
    private let worker = DispatchQueue(label: "FarMac.file-transfer", qos: .userInitiated)
    private let journalKey = "FarMac.transferJournal.v1"
    private let table = NSTableView()
    private let heading = label("Нет активных операций", size: 15, bold: true)
    private let fileLabel = label("Текущий файл: —", size: 11, color: Palette.muted)
    private let fileProgress = NSProgressIndicator()
    private let batchLabel = label("Задание: —", size: 11, color: Palette.muted)
    private let batchProgress = NSProgressIndicator()
    private let details = NSTextView()
    private let cancelButton = NSButton(title: "Отменить выбранное", target: nil, action: nil)
    private let cancelAllButton = NSButton(title: "Отменить всё", target: nil, action: nil)
    private let retryButton = NSButton(title: "Повторить задание", target: nil, action: nil)
    private let clearButton = NSButton(title: "Очистить журнал", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 890, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Очередь файловых операций"
        window.minSize = NSSize(width: 720, height: 620)
        window.backgroundColor = Palette.background
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("FarMac.operationQueue")
        window.center()
        configureUI()
        restoreJournal()
        refreshUI()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult func enqueue(_ request: TransferRequest, retaining resource: AnyObject? = nil) -> Bool {
        guard !request.sources.isEmpty else { return false }
        guard canEnqueue?() ?? true else {
            heading.stringValue = "Добавление недоступно: дождитесь завершения текущего изменения файлов."
            showWindow(nil)
            return false
        }
        guard jobs.filter({ $0.state.pending }).count < 100 else {
            let alert = NSAlert()
            alert.messageText = "В очереди уже 100 заданий"
            alert.informativeText = "Дождитесь завершения или отмените часть заданий перед добавлением новых."
            alert.beginSheetModal(for: window!)
            showWindow(nil)
            return false
        }
        var job = Job(id: UUID(), sources: request.sources.map(\.path), destination: request.destination.path, move: request.move, created: Date(), state: .queued, summary: "Ожидает выполнения", issues: [])
        job.temporarySources = resource != nil
        temporaryResources[job.id] = resource
        runtimeRequests[job.id] = request
        jobs.append(job)
        trimJournal()
        persist()
        refreshUI(select: job.id)
        showWindow(nil)
        onChange?()
        startNext()
        return true
    }

    func cancelAll() {
        for index in jobs.indices where jobs[index].state == .queued {
            jobs[index].state = .cancelled
            jobs[index].summary = "Отменено до начала выполнения."
            runtimeRequests.removeValue(forKey: jobs[index].id)
            temporaryResources.removeValue(forKey: jobs[index].id)
        }
        cancelActive()
        persist()
        refreshUI()
        onChange?()
    }

    private func configureUI() {
        for bar in [fileProgress, batchProgress] {
            bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1
        }
        fileProgress.setAccessibilityLabel("Байты текущего файла")
        batchProgress.setAccessibilityLabel("Байты всего задания")
        let operation = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("operation"))
        operation.title = "Задания (FIFO)"; operation.width = 600; operation.minWidth = 380
        let state = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        state.title = "Состояние"; state.width = 225; state.minWidth = 180
        table.addTableColumn(operation); table.addTableColumn(state)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self; table.dataSource = self
        table.rowHeight = 43; table.usesAlternatingRowBackgroundColors = true
        table.allowsEmptySelection = true
        let list = NSScrollView()
        list.documentView = table; list.hasVerticalScroller = true; list.borderType = .bezelBorder
        details.isEditable = false; details.isSelectable = true; details.isRichText = false
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.backgroundColor = Palette.panel; details.textColor = Palette.text
        details.textContainerInset = NSSize(width: 10, height: 8)
        details.isVerticallyResizable = true; details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        let detailScroll = NSScrollView()
        detailScroll.documentView = details; detailScroll.hasVerticalScroller = true; detailScroll.borderType = .bezelBorder
        for (button, action) in [(cancelButton, #selector(cancelSelected)), (cancelAllButton, #selector(cancelAllAction)), (retryButton, #selector(retrySelected)), (clearButton, #selector(clearHistory))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        retryButton.toolTip = "Заново добавить все исходные пути выбранного задания. Существующие результаты вызовут проверку конфликтов."
        cancelButton.toolTip = "Уже выполненные изменения сохраняются."
        let buttons = horizontal([cancelButton, cancelAllButton, NSView(), retryButton, clearButton])
        let note = label("Панели доступны во время работы. Закрытие этого окна не останавливает очередь.  F1 — помощь", size: 10, color: Palette.muted)
        let content = NSView()
        let views: [NSView] = [heading, fileLabel, fileProgress, batchLabel, batchProgress, list, detailScroll, buttons, note]
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        var constraints: [NSLayoutConstraint] = []
        for view in views {
            constraints += [view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18)]
        }
        constraints += [
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            fileLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            fileProgress.topAnchor.constraint(equalTo: fileLabel.bottomAnchor, constant: 5),
            batchLabel.topAnchor.constraint(equalTo: fileProgress.bottomAnchor, constant: 9),
            batchProgress.topAnchor.constraint(equalTo: batchLabel.bottomAnchor, constant: 5),
            list.topAnchor.constraint(equalTo: batchProgress.bottomAnchor, constant: 16),
            list.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            detailScroll.topAnchor.constraint(equalTo: list.bottomAnchor, constant: 10),
            detailScroll.heightAnchor.constraint(equalToConstant: 160),
            buttons.topAnchor.constraint(equalTo: detailScroll.bottomAnchor, constant: 12),
            note.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 10),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ]
        NSLayoutConstraint.activate(constraints)
        window?.contentView = content
    }

    private func startNext() {
        guard activeID == nil, let index = jobs.firstIndex(where: { $0.state == .queued }) else { return }
        let job = jobs[index]
        guard let request = runtimeRequests[job.id] else {
            jobs[index].state = .interrupted
            jobs[index].summary = "Нет исходного снимка задания. Для запуска требуется явное повторное добавление."
            persist(); refreshUI(); onChange?()
            startNext()
            return
        }
        let token = TransferCancellation()
        activeID = job.id; cancellation = token
        conflictPolicies.removeAll()
        jobs[index].state = .running; jobs[index].summary = "Подготовка…"
        persist(); refreshUI()
        heading.stringValue = job.title
        fileLabel.stringValue = "Подготовка списка объектов…"
        batchLabel.stringValue = "Подсчёт общего объёма…"
        for bar in [fileProgress, batchProgress] { bar.doubleValue = 0; bar.isIndeterminate = true; bar.startAnimation(nil) }
        onChange?()
        let relay = TransferProgressRelay { [weak self] progress in self?.update(progress, id: job.id) }
        worker.async { [weak self] in
            let result = TransferEngine.run(request, cancellation: token, onProgress: { relay.submit($0) }, onConflict: { conflict in
                let answer = TransferAnswer<TransferDecision>()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { answer.resolve(.cancel); return }
                    self.resolveConflict(conflict, id: job.id, cancellation: token, answer: answer)
                }
                return answer.wait(cancellation: token, fallback: .cancel)
            }, onError: { failure in
                let answer = TransferAnswer<TransferErrorDecision>()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { answer.resolve(.cancel); return }
                    self.resolveError(failure, id: job.id, cancellation: token, answer: answer)
                }
                return answer.wait(cancellation: token, fallback: .cancel)
            })
            DispatchQueue.main.async { [weak self] in self?.finish(result, id: job.id) }
        }
    }

    private func update(_ progress: TransferProgress, id: UUID) {
        guard activeID == id else { return }
        fileLabel.stringValue = "\(progress.phase): \(progress.currentPath) • \(bytes(progress.fileBytes)) / \(bytes(progress.fileTotalBytes))"
        fileLabel.toolTip = progress.currentPath
        batchLabel.stringValue = "Объекты: \(progress.completedItems) / \(progress.totalItems) • \(bytes(progress.completedBytes)) / \(bytes(progress.totalBytes))"
        for (bar, current, total) in [(fileProgress, progress.fileBytes, progress.fileTotalBytes), (batchProgress, progress.completedBytes, progress.totalBytes)] {
            bar.stopAnimation(nil); bar.isIndeterminate = false
            bar.doubleValue = total > 0 ? min(1, max(0, Double(current) / Double(total))) : 0
        }
    }

    private func finish(_ result: TransferResult, id: UUID) {
        guard activeID == id, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = result.cancelled ? .cancelled : result.failed > 0 ? (result.completed > 0 ? .partial : .failed) : result.skipped > 0 ? .partial : .completed
        jobs[index].summary = result.summary + (jobs[index].temporarySources == true ? " Для повтора снова извлеките объекты из архива." : "")
        jobs[index].issues = result.issues
        runtimeRequests.removeValue(forKey: id)
        temporaryResources.removeValue(forKey: id)
        activeID = nil; cancellation = nil; cancelDecision = nil; decisionAlert = nil
        conflictPolicies.removeAll()
        heading.stringValue = jobs[index].state.title + ": " + jobs[index].title
        for bar in [fileProgress, batchProgress] { bar.stopAnimation(nil); bar.isIndeterminate = false }
        trimJournal(); persist(); refreshUI()
        onChange?(); onFinished?(result)
        // Give the completed journal entry and panel refreshes a turn before the next job.
        DispatchQueue.main.async { [weak self] in self?.startNext() }
    }

    private func resolveConflict(_ conflict: TransferConflict, id: UUID, cancellation token: TransferCancellation, answer: TransferAnswer<TransferDecision>, nameError: String? = nil) {
        guard activeID == id, !token.isCancelled, !answer.isResolved else { answer.resolve(.cancel); return }
        if let decision = conflictPolicies[conflict.isDirectoryMerge] {
            if case .replace = decision, !conflict.canReplace {
                // A file policy never authorizes replacing a directory tree.
            } else { answer.resolve(decision); return }
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = nameError ?? (conflict.isDirectoryMerge ? "Объединить папки?" : "Объект уже существует")
        alert.informativeText = "Источник: \(conflict.source.path)\nНазначение: \(conflict.destination.path)\n\n" + (conflict.isDirectoryMerge ? "Содержимое папок будет объединено. Совпадения внутри проверяются отдельно; дерево назначения сохраняется." : (conflict.canReplace ? "Замена удалит существующий файл назначения только для этого совпадения." : "Типы объектов различаются. Папки не заменяются целиком: пропустите объект или укажите новое имя."))
        alert.addButton(withTitle: conflict.isDirectoryMerge ? "Объединить" : "Заменить").isEnabled = conflict.isDirectoryMerge || conflict.canReplace
        alert.addButton(withTitle: "Пропустить")
        alert.addButton(withTitle: "Новое имя")
        alert.addButton(withTitle: "Отменить задание").keyEquivalent = "\u{1b}"
        let name = NSTextField(string: conflict.destination.lastPathComponent)
        name.placeholderString = "Новое имя без пути"
        let applyAll = NSButton(checkboxWithTitle: "Для всех таких конфликтов в этом задании", target: nil, action: nil)
        let accessory = vertical([label("Имя для кнопки «Новое имя»:", size: 11), name, applyAll], spacing: 8)
        accessory.frame = NSRect(x: 0, y: 0, width: 420, height: 80)
        alert.accessoryView = accessory
        present(alert, cancel: { answer.resolve(.cancel) }) { [weak self] response in
            guard let self, !token.isCancelled, !answer.isResolved else { answer.resolve(.cancel); return }
            let decision: TransferDecision
            switch response {
            case .alertFirstButtonReturn: decision = conflict.isDirectoryMerge ? .merge : .replace
            case .alertSecondButtonReturn: decision = .skip
            case .alertThirdButtonReturn:
                let newName = name.stringValue
                guard !newName.isEmpty, newName != ".", newName != "..", !newName.contains("/"), !newName.contains("\0"), newName != conflict.destination.lastPathComponent else {
                    self.resolveConflict(conflict, id: id, cancellation: token, answer: answer, nameError: "Укажите другое непустое имя без /, . и ..")
                    return
                }
                decision = .rename(newName)
            default: decision = .cancel
            }
            if applyAll.state == .on {
                switch decision {
                case .replace, .skip, .merge: self.conflictPolicies[conflict.isDirectoryMerge] = decision
                default: break
                }
            }
            if case .cancel = decision { token.cancel() }
            answer.resolve(decision)
        }
    }

    private func resolveError(_ failure: TransferFailure, id: UUID, cancellation token: TransferCancellation, answer: TransferAnswer<TransferErrorDecision>) {
        guard activeID == id, !token.isCancelled, !answer.isResolved else { answer.resolve(.cancel); return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Не удалось обработать объект"
        alert.informativeText = "Источник: \(failure.source.path)\nНазначение: \(failure.destination.path)\n\n\(failure.message)\n\nПовторить — повтор текущего объекта. Пропустить — продолжить со следующим."
        alert.addButton(withTitle: "Повторить")
        alert.addButton(withTitle: "Пропустить и продолжить")
        alert.addButton(withTitle: "Отменить задание").keyEquivalent = "\u{1b}"
        present(alert, cancel: { answer.resolve(.cancel) }) { response in
            guard !token.isCancelled else { answer.resolve(.cancel); return }
            switch response {
            case .alertFirstButtonReturn: answer.resolve(.retry)
            case .alertSecondButtonReturn: answer.resolve(.skip)
            default: token.cancel(); answer.resolve(.cancel)
            }
        }
    }

    private func present(_ alert: NSAlert, cancel: @escaping () -> Void, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window else { cancel(); return }
        showWindow(nil)
        decisionAlert = alert
        cancelDecision = cancel
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, self.decisionAlert === alert else { return }
            self.cancelDecision = nil; self.decisionAlert = nil
            completion(response)
        }
    }

    private func cancelActive() {
        guard let id = activeID else { return }
        cancellation?.cancel()
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].state = .cancelling }
        // Resolve before dismissing the sheet: the worker can always exit, even if its completion is deferred.
        cancelDecision?(); cancelDecision = nil
        if let sheet = decisionAlert?.window { window?.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
        decisionAlert = nil
        heading.stringValue = "Отмена текущего задания…"
    }

    @objc private func cancelSelected() {
        guard let index = selectedIndex else { return }
        if jobs[index].state == .queued {
            jobs[index].state = .cancelled; jobs[index].summary = "Отменено до начала выполнения."
            runtimeRequests.removeValue(forKey: jobs[index].id)
            temporaryResources.removeValue(forKey: jobs[index].id)
        } else if jobs[index].id == activeID { cancelActive() }
        persist(); refreshUI(); onChange?()
    }
    @objc private func cancelAllAction() { cancelAll() }
    @objc private func retrySelected() {
        guard let index = selectedIndex, !jobs[index].state.pending, jobs[index].temporarySources != true else { return }
        enqueue(jobs[index].request)
    }
    @objc private func clearHistory() {
        jobs.removeAll { !$0.state.pending }
        persist(); refreshUI(); onChange?()
    }
    private var selectedIndex: Int? { jobs.indices.contains(table.selectedRow) ? table.selectedRow : nil }

    private func refreshUI(select id: UUID? = nil) {
        let selection = id ?? selectedIndex.map { jobs[$0].id }
        table.reloadData()
        if let selection, let index = jobs.firstIndex(where: { $0.id == selection }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        if let id, let index = jobs.firstIndex(where: { $0.id == id }) { table.scrollRowToVisible(index) }
        window?.subtitle = "В очереди: \(jobs.filter { $0.state == .queued }.count) • Журнал: \(jobs.count) / 100"
        refreshSelection()
    }
    private func refreshSelection() {
        cancelAllButton.isEnabled = hasPendingOperations
        clearButton.isEnabled = jobs.contains { !$0.state.pending }
        guard let index = selectedIndex else {
            cancelButton.isEnabled = false; retryButton.isEnabled = false
            details.string = "Выберите задание для просмотра исходных путей, результата и ошибок."
            return
        }
        let job = jobs[index]
        cancelButton.isEnabled = job.state == .queued || job.state == .running
        retryButton.isEnabled = !job.state.pending && job.temporarySources != true
        let date = DateFormatter.localizedString(from: job.created, dateStyle: .short, timeStyle: .medium)
        details.string = "\(job.title)\n\(date) • \(job.state.title)\nНазначение: \(job.destination)\nИсточники:\n\(job.sources.joined(separator: "\n"))\n\n\(job.summary)" + (job.issues.isEmpty ? "" : "\n\nОшибки и замечания:\n" + job.issues.joined(separator: "\n"))
    }
    func numberOfRows(in tableView: NSTableView) -> Int { jobs.count }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshSelection() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard jobs.indices.contains(row) else { return nil }
        let job = jobs[row]
        let field = label("", size: 11)
        if tableColumn?.identifier.rawValue == "operation" {
            field.stringValue = "\(job.title)\n→ \(job.destination)"
            field.maximumNumberOfLines = 2
        } else {
            field.stringValue = job.state.title
            field.textColor = job.state == .completed ? Palette.accent : (job.state == .failed || job.state == .partial || job.state == .interrupted) ? .systemOrange : Palette.text
        }
        field.toolTip = job.summary
        return field
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // AppKit sheets are confined to this window, so the main panels stay usable.
        if decisionAlert != nil { NSSound.beep(); return false }
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(jobs) { UserDefaults.standard.set(data, forKey: journalKey) }
    }
    private func restoreJournal() {
        guard let data = UserDefaults.standard.data(forKey: journalKey), let restored = try? JSONDecoder().decode([Job].self, from: data) else { return }
        jobs = Array(restored.suffix(100))
        for index in jobs.indices where jobs[index].state.pending {
            jobs[index].state = .interrupted
            jobs[index].summary = "Выполнение не подтверждено: приложение завершилось до окончания задания. Автоматического возобновления нет. Проверьте источники и назначение перед повтором: завершённые файлы сохраняются, могут остаться скрытые временные объекты .farmac-transfer-*. Повтор запускает новое задание, а не продолжает файл с места сбоя."
        }
        persist()
    }
    private func trimJournal() {
        while jobs.count > 100 {
            guard let index = jobs.firstIndex(where: { !$0.state.pending }) else { break }
            jobs.remove(at: index)
        }
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file) }
}
