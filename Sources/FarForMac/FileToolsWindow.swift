import AppKit
import FarCore

/// Independent tool windows retain themselves until closed; all filesystem work
/// runs away from the main thread. Callers only need to showWindow(nil).
@MainActor
class FileToolsWindowController: NSWindowController, NSWindowDelegate {
    let status = NSTextField(wrappingLabelWithString: "")
    var isWorking = false
    var hasPendingMutation = false
    private var retainedWhileOpen: FileToolsWindowController?

    init(title: String, width: CGFloat = 680, height: CGFloat = 450) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 300)
        window.center()
        window.delegate = self
        status.textColor = .secondaryLabelColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func showWindow(_ sender: Any?) {
        retainedWhileOpen = self
        super.showWindow(sender)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasPendingMutation { status.stringValue = "Дождитесь завершения файловой операции."; NSSound.beep(); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { retainedWhileOpen = nil }
    func content(_ views: [NSView]) {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let container = NSView()
        container.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window?.contentView = container
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 10
        return row
    }
    func worker<T>(_ work: @escaping () throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result(catching: work)
            DispatchQueue.main.async { completion(result) }
        }
    }
}

@MainActor
final class BatchRenameWindow: FileToolsWindowController, NSTextFieldDelegate {
    private let urls: [URL]
    private let onComplete: () -> Void
    private let canMutate: () -> Bool
    private let template = NSTextField(string: "{name}_{n}.{ext}")
    private let preview = NSTextView()
    private var plan: [BatchRenameEntry] = []
    private var reviewedTemplate = ""
    private lazy var previewButton = button("Предпросмотр", #selector(makePreview))
    private lazy var applyButton = button("Переименовать по предпросмотру", #selector(applyRename))

    init(urls: [URL], canMutate: @escaping () -> Bool = { true }, onComplete: @escaping () -> Void) {
        self.urls = urls; self.onComplete = onComplete; self.canMutate = canMutate
        super.init(title: "Групповое переименование", height: 490)
        template.delegate = self
        let help = NSTextField(wrappingLabelWithString: "Шаблон: {name} — имя без расширения, {ext} — расширение без точки, {n} — номер с 1. Точка вводится явно. Для папок {ext} пусто. Это буквальный шаблон, а не маски FAR. Пример для файлов: {name}_{n}.{ext}")
        preview.isEditable = false; preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]
        preview.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = preview; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        applyButton.isEnabled = false
        status.stringValue = "Выбрано: \(urls.count). Сначала проверьте новые имена. Перезапись и циклы запрещены."
        content([help, template, row([previewButton, applyButton]), scroll, status])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ obj: Notification) {
        plan = []; applyButton.isEnabled = false; preview.string = ""
        status.stringValue = "Шаблон изменён. Создайте новый предпросмотр."
    }
    @objc private func makePreview() {
        let value = template.stringValue
        previewButton.isEnabled = false; applyButton.isEnabled = false
        status.stringValue = "Проверка имён…"
        worker({ try FileTools.renamePlan(self.urls, template: value) }) { [self] result in
            previewButton.isEnabled = true
            guard value == template.stringValue else { return }
            switch result {
            case .success(let entries):
                plan = entries; reviewedTemplate = value
                preview.string = entries.map { "\($0.source.url.lastPathComponent)  →  \($0.destination.lastPathComponent)" }.joined(separator: "\n")
                applyButton.isEnabled = true
                status.stringValue = "Проверьте каждую строку. Будет переименовано объектов: \(entries.count)."
            case .failure(let error): plan = []; status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func applyRename() {
        guard !plan.isEmpty, reviewedTemplate == template.stringValue else { return }
        guard canMutate() else { status.stringValue = "Другая файловая операция ещё выполняется."; return }
        isWorking = true; hasPendingMutation = true
        let entries = plan
        applyButton.isEnabled = false; previewButton.isEnabled = false; template.isEnabled = false
        status.stringValue = "Переименование…"
        worker({ try FileTools.executeRename(entries) }) { [self] result in
            isWorking = false; hasPendingMutation = false
            onComplete() // refresh even after a partial failure
            template.isEnabled = true; previewButton.isEnabled = true; plan = []
            switch result {
            case .success(let count): status.stringValue = "Переименовано: \(count)."; preview.string = ""
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
}

@MainActor
final class FilePropertiesWindow: FileToolsWindowController {
    private let url: URL
    private let onComplete: () -> Void
    private let canMutate: () -> Bool
    private let details = NSTextField(wrappingLabelWithString: "Загрузка…")
    private let permissions = NSTextField(string: "")
    private var source: FileToolItem?
    private lazy var saveButton = button("Применить права", #selector(savePermissions))

    init(url: URL, canMutate: @escaping () -> Bool = { true }, onComplete: @escaping () -> Void) {
        self.url = url; self.onComplete = onComplete; self.canMutate = canMutate
        super.init(title: "Свойства — \(url.lastPathComponent)", height: 360)
        details.isSelectable = true
        permissions.placeholderString = "0755"
        permissions.isEnabled = false; saveButton.isEnabled = false
        content([details, NSTextField(labelWithString: "Права POSIX (восьмеричные, например 0644 или 0755):"), permissions, saveButton, status, NSView()])
        load()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func load() {
        worker({ try FileTools.metadata(self.url) }) { [self] result in
            switch result {
            case .success(let item):
                source = item
                let type = item.isSymbolicLink ? "Символическая ссылка" : (item.isDirectory ? "Папка" : "Файл")
                details.stringValue = "\(item.url.path)\n\(type) · \(item.size) байт\nИзменён: \(item.modified.formatted(date: .numeric, time: .standard))"
                permissions.stringValue = String(format: "%04o", Int(item.permissions))
                permissions.isEnabled = !item.isSymbolicLink; saveButton.isEnabled = !item.isSymbolicLink
                status.stringValue = item.isSymbolicLink ? "Права ссылки доступны только для чтения. Цель ссылки не изменяется." : "Изменяются только права выбранного объекта, без рекурсии."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func savePermissions() {
        guard let source else { return }
        guard canMutate() else { status.stringValue = "Другая файловая операция ещё выполняется."; return }
        isWorking = true; hasPendingMutation = true
        let value = permissions.stringValue
        saveButton.isEnabled = false; permissions.isEnabled = false
        worker({ try FileTools.setPermissions(value, for: source) }) { [self] result in
            isWorking = false; hasPendingMutation = false
            saveButton.isEnabled = true; permissions.isEnabled = true
            switch result {
            case .success: onComplete(); load(); status.stringValue = "Права обновлены."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
}

@MainActor
final class DirectorySizeWindow: FileToolsWindowController {
    private let cancellation = FileToolCancellation()
    private let progress = NSProgressIndicator()
    private lazy var cancelButton = button("Отменить подсчёт", #selector(cancelCount))
    init(url: URL) {
        super.init(title: "Размер папки — \(url.lastPathComponent)", height: 310)
        let path = NSTextField(wrappingLabelWithString: url.path); path.isSelectable = true
        progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil)
        status.stringValue = "Подсчёт… Символические ссылки не обходятся. Размер — сумма логических размеров обычных файлов."
        content([path, progress, status, cancelButton, NSView()])
        let token = cancellation
        isWorking = true
        worker({ try FileTools.directorySize(url, cancellation: token) }) { [self] result in
            isWorking = false
            progress.stopAnimation(nil); cancelButton.isEnabled = false
            switch result {
            case .success(let size):
                status.stringValue = "\(size.isCancelled ? "Подсчёт отменён. Частичный результат:" : "Результат:")\n\(size.bytes) байт (\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file)))\nФайлов: \(size.files); вложенных папок: \(size.directories); ссылок: \(size.symbolicLinks).\nНедоступных объектов или ошибок чтения: \(size.unreadable)."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func cancelCount() { cancellation.cancel(); status.stringValue = "Отмена подсчёта…" }
    override func windowWillClose(_ notification: Notification) {
        cancellation.cancel(); super.windowWillClose(notification)
    }
}
