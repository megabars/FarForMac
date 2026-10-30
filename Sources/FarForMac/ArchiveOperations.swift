import AppKit
import FarCore

private enum ArchiveOperationUIError: LocalizedError {
    case busy
    var errorDescription: String? { "Дождитесь завершения текущей операции с архивом." }
}

/// Worker callbacks replace a single value. The UI reads it at a bounded rate,
/// so archives with many small members cannot flood the main queue.
private final class ArchiveProgressMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ArchiveProgress?
    func publish(_ progress: ArchiveProgress) { lock.lock(); value = progress; lock.unlock() }
    func take() -> ArchiveProgress? { lock.lock(); defer { lock.unlock() }; let result = value; value = nil; return result }
}

@MainActor
private final class ArchiveProgressWindow: FileToolsWindowController {
    private let cancellation: TransferCancellation
    private let mailbox: ArchiveProgressMailbox
    private let progress = NSProgressIndicator()
    private let member = NSTextField(labelWithString: "")
    private var timer: Timer?
    private lazy var cancelButton = button("Отменить", #selector(cancelArchiveWork))

    init(title: String, detail: String, cancellation: TransferCancellation, mailbox: ArchiveProgressMailbox) {
        self.cancellation = cancellation; self.mailbox = mailbox
        super.init(title: title, width: 600, height: 240)
        let path = NSTextField(wrappingLabelWithString: detail); path.isSelectable = true
        member.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        member.lineBreakMode = .byTruncatingMiddle
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil)
        status.stringValue = "Подготовка…"
        content([path, member, progress, status, row([NSView(), cancelButton])])
        cancelButton.keyEquivalent = "\u{1b}"
        isWorking = true; hasPendingMutation = true
        timer = Timer.scheduledTimer(timeInterval: 0.12, target: self, selector: #selector(refreshProgress), userInfo: nil, repeats: true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func refreshProgress() {
        guard let value = mailbox.take() else { return }
        member.stringValue = value.currentPath
        if value.totalBytes > 0 {
            progress.isIndeterminate = false; progress.maxValue = Double(value.totalBytes)
            progress.doubleValue = Double(min(value.completedBytes, value.totalBytes))
        } else if value.totalItems > 0 {
            progress.isIndeterminate = false; progress.maxValue = Double(value.totalItems)
            progress.doubleValue = Double(min(value.completedItems, value.totalItems))
        }
        if cancellation.isCancelled { status.stringValue = "Отмена… Дождитесь завершения очистки." }
        else {
            let amount = ByteCountFormatter.string(fromByteCount: value.completedBytes, countStyle: .file)
            status.stringValue = "Объектов: \(value.completedItems) / \(value.totalItems) · \(amount)"
        }
    }
    @objc private func cancelArchiveWork() {
        cancellation.cancel(); cancelButton.isEnabled = false
        status.stringValue = "Отмена… Дождитесь завершения очистки."
    }
    func finish() {
        timer?.invalidate(); timer = nil
        isWorking = false; hasPendingMutation = false
        close()
    }
    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isWorking { cancelArchiveWork(); return false }
        return true
    }
}

/// One host-owned controller serializes archive operations. Completion is always
/// on the main thread. Returned workspaces belong to the caller until cleanup.
@MainActor
final class ArchiveOperationController {
    private(set) var isWorking = false
    private var cancellation: TransferCancellation?
    private var progressWindow: ArchiveProgressWindow?

    func cancel() { cancellation?.cancel() }

    func open(_ url: URL, completion: @escaping (Result<ArchiveSnapshot, Error>) -> Void) {
        open(url, password: nil, completion: completion)
    }
    private func open(_ url: URL, password: String?, completion: @escaping (Result<ArchiveSnapshot, Error>) -> Void) {
        run(title: "Чтение архива", detail: url.path, work: { token, progress in
            try ArchiveReader.open(url, password: password, cancellation: token, onProgress: progress)
        }) { [weak self] result in
            if case .failure(let error) = result, Self.needsPassword(error), let self {
                guard let value = Self.requestPassword(url, incorrect: Self.incorrectPassword(error)) else {
                    completion(.failure(ArchiveError.cancelled)); return
                }
                self.open(url, password: value, completion: completion)
            } else { completion(result) }
        }
    }

    func extract(_ snapshot: ArchiveSnapshot, paths: [String]? = nil,
                 completion: @escaping (Result<ArchiveWorkspace, Error>) -> Void) {
        guard !isWorking else { completion(.failure(ArchiveOperationUIError.busy)); return }
        let selected = paths.map(Set.init)
        let encrypted = snapshot.entries.contains { entry in
            entry.isEncrypted && (selected == nil || selected!.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }))
        }
        var password: String?
        if encrypted {
            guard let value = Self.requestPassword(snapshot.sourceURL, incorrect: false) else { completion(.failure(ArchiveError.cancelled)); return }
            password = value
        }
        extract(snapshot, paths: paths, password: password, completion: completion)
    }
    private func extract(_ snapshot: ArchiveSnapshot, paths: [String]?, password: String?,
                         completion: @escaping (Result<ArchiveWorkspace, Error>) -> Void) {
        run(title: "Извлечение из архива", detail: snapshot.sourceURL.path, work: { token, progress in
            try ArchiveReader.extract(snapshot, paths: paths, password: password, cancellation: token, onProgress: progress)
        }) { [weak self] result in
            if case .failure(let error) = result, Self.needsPassword(error), let self {
                guard let value = Self.requestPassword(snapshot.sourceURL, incorrect: Self.incorrectPassword(error)) else {
                    completion(.failure(ArchiveError.cancelled)); return
                }
                self.extract(snapshot, paths: paths, password: value, completion: completion)
            } else { completion(result) }
        }
    }

    func create(sources: [URL], destination: URL, format: ArchiveFormat,
                completion: @escaping (Result<ArchiveSnapshot, Error>) -> Void) {
        create(sources: sources, destination: destination, format: format, policy: .error, completion: completion)
    }
    private func create(sources: [URL], destination: URL, format: ArchiveFormat, policy: ArchiveOverwritePolicy,
                        completion: @escaping (Result<ArchiveSnapshot, Error>) -> Void) {
        run(title: "Создание архива", detail: destination.path, work: { token, progress in
            try ArchiveWriter.create(sources: sources, destination: destination, format: format, policy: policy,
                                     cancellation: token, onProgress: progress)
        }) { [weak self] result in
            if case .failure(let error) = result, case .conflict(let path) = error as? ArchiveWriteError, let self {
                guard let decision = Self.overwriteDecision(path) else { completion(.failure(ArchiveError.cancelled)); return }
                self.create(sources: sources, destination: destination, format: format, policy: decision, completion: completion)
            } else { completion(result) }
        }
    }

    func update(_ snapshot: ArchiveSnapshot, additions: [URL] = [], deletions: [String] = [],
                replacements: [String: URL] = [:], prefix: String = "",
                completion: @escaping (Result<ArchiveSnapshot, Error>) -> Void) {
        update(snapshot, additions: additions, deletions: deletions, replacements: replacements, prefix: prefix,
               policy: .error, completion: completion)
    }
    private func update(_ snapshot: ArchiveSnapshot, additions: [URL], deletions: [String],
                        replacements: [String: URL], prefix: String, policy: ArchiveOverwritePolicy,
                        completion: @escaping (Result<ArchiveSnapshot, Error>) -> Void) {
        run(title: "Обновление архива", detail: snapshot.sourceURL.path, work: { token, progress in
            try ArchiveWriter.update(snapshot, additions: additions, deletions: deletions, replacements: replacements,
                                     prefix: prefix, policy: policy, cancellation: token, onProgress: progress)
        }) { [weak self] result in
            if case .failure(let error) = result, case .conflict(let path) = error as? ArchiveWriteError, let self {
                guard let decision = Self.overwriteDecision(path) else { completion(.failure(ArchiveError.cancelled)); return }
                self.update(snapshot, additions: additions, deletions: deletions, replacements: replacements,
                            prefix: prefix, policy: decision, completion: completion)
            } else { completion(result) }
        }
    }

    private func run<Value>(title: String, detail: String,
                            work: @escaping (TransferCancellation, @escaping (ArchiveProgress) -> Void) throws -> Value,
                            completion: @escaping (Result<Value, Error>) -> Void) {
        guard !isWorking else { completion(.failure(ArchiveOperationUIError.busy)); return }
        let token = TransferCancellation(), mailbox = ArchiveProgressMailbox()
        cancellation = token; isWorking = true
        let window = ArchiveProgressWindow(title: title, detail: detail, cancellation: token, mailbox: mailbox)
        progressWindow = window; window.showWindow(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(token, mailbox.publish) }
            DispatchQueue.main.async { [self] in
                window.finish(); progressWindow = nil; cancellation = nil; isWorking = false
                completion(result)
            }
        }
    }

    private static func needsPassword(_ error: Error) -> Bool {
        guard let error = error as? ArchiveError else { return false }
        switch error { case .passwordRequired, .incorrectPassword: return true; default: return false }
    }
    private static func incorrectPassword(_ error: Error) -> Bool {
        guard let error = error as? ArchiveError else { return false }
        if case .incorrectPassword = error { return true }; return false
    }
    private static func requestPassword(_ url: URL, incorrect: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = incorrect ? "Неверный пароль архива" : "Пароль архива"
        alert.informativeText = "\(url.lastPathComponent)\nПароль используется только для этой операции и не сохраняется."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        field.placeholderString = "Пароль"; field.setAccessibilityLabel("Пароль архива")
        alert.accessoryView = field
        alert.addButton(withTitle: "Открыть"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        let result = response == .alertFirstButtonReturn ? field.stringValue : nil
        field.stringValue = ""
        return result
    }
    private static func overwriteDecision(_ path: String) -> ArchiveOverwritePolicy? {
        let alert = NSAlert(); alert.messageText = "Объект уже существует"
        alert.informativeText = "\(path)\nВыбор применяется ко всем совпадающим именам этой операции."
        alert.addButton(withTitle: "Заменить все"); alert.addButton(withTitle: "Пропустить все"); alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .skip
        default: return nil
        }
    }
}
