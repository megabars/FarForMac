import AppKit
import FarCore

/// Explicit upload of a saved working copy, preserving the remote base snapshot.
@MainActor final class NetworkEditWindow: FileToolsWindowController {
    private var snapshot: RemoteEditSnapshot
    private let workspace: RemoteWorkspace, provider: any RemoteProvider, editor: TextFileWindow
    private let operations = NetworkOperationController()
    private let canCommit: () -> Bool, onCommitted: () -> Void
    private var pending = false, discard = false, revision = 0, editorClosed = false
    private var observer: NSObjectProtocol?
    private lazy var saveButton = button("Сохранить на сервер", #selector(commit))
    init(snapshot: RemoteEditSnapshot, workspace: RemoteWorkspace, provider: any RemoteProvider, editor: TextFileWindow,
         canCommit: @escaping () -> Bool, onCommitted: @escaping () -> Void) {
        self.snapshot = snapshot; self.workspace = workspace; self.provider = provider; self.editor = editor
        self.canCommit = canCommit; self.onCommitted = onCommitted
        super.init(title: "Сетевая рабочая копия — \(snapshot.entry.name)", width: 650, height: 300)
        let info = NSTextField(wrappingLabelWithString: "\(provider.connection.displayName)\n\(snapshot.entry.path)\nРедактор сохраняет только локальную копию. Для отправки нажмите «Сохранить на сервер». Перед записью проверяется удалённая версия.")
        content([info, status, NSView(), row([button("Редактор", #selector(showEditor)), NSView(), button("Закрыть", #selector(closeSession)), saveButton])])
        status.stringValue = "Сервер ещё не изменён."
        editor.onArchiveWorkingCopySaved = { [weak self] url in
            guard let self else { return }
            if url.standardizedFileURL == self.snapshot.localURL.standardizedFileURL { self.pending = true; self.revision += 1; self.discard = false; self.status.stringValue = "Копия сохранена; отправьте её на сервер отдельной кнопкой." }
        }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: editor.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editorClosed = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func showEditor() { if !editorClosed { editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil) } }
    @objc private func closeSession() { window?.performClose(nil) }
    @objc private func commit() {
        guard !isWorking, canCommit() else { status.stringValue = "Дождитесь текущей файловой операции."; return }
        guard editor.workingFileURL?.standardizedFileURL == snapshot.localURL.standardizedFileURL else { status.stringValue = "После «Сохранить как» файл больше не связан с сервером."; return }
        if !editorClosed, !editor.saveForArchiveCommit() { return }
        commitSaved()
    }
    private func commitSaved() {
        guard pending, !isWorking, canCommit() else { return }
        guard editor.workingFileURL?.standardizedFileURL == snapshot.localURL.standardizedFileURL else { status.stringValue = "Файл сохранён в другое место; сервер не изменён."; return }
        let base = snapshot, revision = revision
        isWorking = true; hasPendingMutation = true; saveButton.isEnabled = false
        operations.run(title: "Сохранение на сервер", work: { [workspace, provider] token, progress in
            try workspace.commit(base, provider: provider, cancellation: token, progress: progress)
        }) { [self] result in
            isWorking = false; hasPendingMutation = false; saveButton.isEnabled = true
            switch result {
            case .success(let value): snapshot = value; pending = self.revision != revision; onCommitted(); status.stringValue = pending ? "Файл отправлен. В копии есть новые сохранённые изменения." : "Файл сохранён на сервере."
            case .failure(let error): status.stringValue = error.localizedDescription + " Локальная копия остаётся доступной; можно повторить или сохранить её как отдельный файл."
            }
        }
    }
    func confirmClose() -> Bool {
        discard = false
        guard window?.isVisible == true else { return true }
        guard !isWorking else { return false }
        guard pending else { return true }
        let alert = NSAlert(); alert.messageText = "Отправить рабочую копию на сервер?"
        alert.informativeText = snapshot.entry.path + "\nВ локальной копии есть сохранённые изменения."
        alert.addButton(withTitle: "Сохранить на сервер"); alert.addButton(withTitle: "Не отправлять"); alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn: commitSaved(); return false
        case .alertSecondButtonReturn: discard = true; return true
        default: return false
        }
    }
    func finalizeClose() { if discard { pending = false; discard = false } }
    func cancel() { operations.cancel() }
    func cleanupForTermination() { workspace.cleanup() }
    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isWorking, (editorClosed || editor.confirmClose()), confirmClose() else { return false }
        if !editorClosed { editor.finalizeClose(); editor.closeArchiveWorkingCopyWithoutSaving() }
        finalizeClose(); return true
    }
    override func windowWillClose(_ notification: Notification) {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        workspace.cleanup(); super.windowWillClose(notification)
    }
}
