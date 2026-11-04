import AppKit
import FarCore

/// Saving the editor changes only a private working copy. Updating the archive
/// is a separate, explicit action, checked against the original archive stamp.
@MainActor
final class ArchiveEditCommitWindow: FileToolsWindowController {
    private var snapshot: ArchiveSnapshot
    private let path: String
    private var workspace: ArchiveWorkspace?
    private let workingURL: URL
    private let editor: TextFileWindow
    private let onCommitted: (ArchiveSnapshot) -> Void
    private let canCommit: () -> Bool
    private let operations = ArchiveOperationController()
    private var pendingChanges = false
    private var pendingDiscard = false
    private var saveRevision = 0
    private var editorWasClosed = false
    private var editorCloseObserver: NSObjectProtocol?
    private var viewingSession: WorkingCopyViewerSession?
    private lazy var commitButton = button("Сохранить в архив", #selector(commitWorkingCopy))
    private lazy var editButton = button("Вернуться в редактор", #selector(showEditor))
    private lazy var closeButton = button("Закрыть", #selector(closeSession))

    init(snapshot: ArchiveSnapshot, path: String, workspace: ArchiveWorkspace, editor: TextFileWindow,
         canCommit: @escaping () -> Bool = { true }, onCommitted: @escaping (ArchiveSnapshot) -> Void) throws {
        guard !snapshot.isReadOnly else {
            throw snapshot.isEncrypted ? ArchiveWriteError.encryptedReadOnly : ArchiveWriteError.nestedReadOnly
        }
        self.snapshot = snapshot; self.path = path; self.workspace = workspace; self.editor = editor
        self.workingURL = try workspace.url(for: path).standardizedFileURL
        self.canCommit = canCommit; self.onCommitted = onCommitted
        super.init(title: "Рабочая копия — \((path as NSString).lastPathComponent)", width: 650, height: 310)
        let source = NSTextField(wrappingLabelWithString: "\(snapshot.sourceURL.path)\n!/\(path)")
        source.isSelectable = true
        let help = NSTextField(wrappingLabelWithString: "Редактор сохраняет файл во временную рабочую копию. Для замены файла в архиве нажмите «Сохранить в архив». При ошибке или отмене исходный архив сохраняется.")
        status.stringValue = "Архив ещё не изменён. Рабочая копия открыта в редакторе."
        content([source, help, status, NSView(), row([editButton, NSView(), closeButton, commitButton])])
        viewingSession = WorkingCopyViewerSession(editor: editor, url: workingURL, title: (path as NSString).lastPathComponent,
                                                   archiveWorkspace: workspace)
        let previous = editor.onArchiveWorkingCopySaved
        editor.onArchiveWorkingCopySaved = { [weak self] url in
            previous?(url)
            guard let self else { return }
            self.pendingDiscard = false
            if url.standardizedFileURL == self.workingURL {
                self.saveRevision += 1; self.pendingChanges = true
                self.status.stringValue = "Рабочая копия сохранена. Нажмите «Сохранить в архив», чтобы применить изменения."
            } else {
                self.status.stringValue = "Файл сохранён в другое место. Этот файл не будет записан обратно в архив."
            }
        }
        editorCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                    object: editor.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.editorWasClosed = true
                self.editButton.isEnabled = false
                self.viewingSession?.close(); self.viewingSession = nil
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func showEditor() {
        guard !editorWasClosed else { return }
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
    }
    @objc private func closeSession() { window?.performClose(nil) }
    @objc private func commitWorkingCopy() {
        guard !isWorking else { return }
        guard canCommit() else { status.stringValue = "Дождитесь завершения другой файловой операции."; return }
        guard editor.workingFileURL?.standardizedFileURL == workingURL else {
            status.stringValue = "После «Сохранить как» редактор работает с другим файлом. Архив не изменён."; return
        }
        if !editorWasClosed, !editor.saveForArchiveCommit() { return }
        guard pendingChanges else { status.stringValue = "Нет сохранённых изменений рабочей копии."; return }
        commitSavedCopy()
    }
    private func commitSavedCopy() {
        guard !isWorking else { return }
        guard canCommit() else { status.stringValue = "Дождитесь завершения другой файловой операции."; return }
        guard editor.workingFileURL?.standardizedFileURL == workingURL else {
            status.stringValue = "Редактор больше не связан с исходной рабочей копией. Архив не изменён."; return
        }
        let revision = saveRevision
        isWorking = true; hasPendingMutation = true
        commitButton.isEnabled = false; closeButton.isEnabled = false
        status.stringValue = "Проверка исходного архива и запись рабочей копии…"
        operations.update(snapshot, replacements: [path: workingURL]) { [self] result in
            isWorking = false; hasPendingMutation = false
            commitButton.isEnabled = true; closeButton.isEnabled = true
            switch result {
            case .success(let updated):
                snapshot = updated; pendingChanges = saveRevision != revision; pendingDiscard = false
                onCommitted(updated)
                status.stringValue = pendingChanges
                    ? "Архив обновлён. В рабочей копии появились новые сохранённые изменения."
                    : "Архив обновлён. Можно продолжить редактирование или закрыть оба окна."
            case .failure(let error): status.stringValue = error.localizedDescription
            }
        }
    }

    /// Called after editor guards during application termination. Only bytes
    /// already saved in the working copy may be committed here: an editor guard
    /// may have chosen to discard a still-dirty buffer, pending finalization.
    func confirmClose() -> Bool {
        pendingDiscard = false
        guard window?.isVisible == true else { return true }
        guard !isWorking else { status.stringValue = "Дождитесь завершения записи архива."; return false }
        guard pendingChanges else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert(); alert.messageText = "Записать рабочую копию в архив?"
        alert.informativeText = "\(path)\nВ рабочей копии есть сохранённые изменения, ещё не записанные в архив."
        alert.addButton(withTitle: "Сохранить в архив"); alert.addButton(withTitle: "Не сохранять в архив"); alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            commitSavedCopy()
            return false // The asynchronous write must finish before closing.
        case .alertSecondButtonReturn: pendingDiscard = true; return true
        default: return false
        }
    }
    /// No buffers or workspaces are discarded until every application guard
    /// has approved. The editor owns its own deferred discard decision.
    func finalizeClose() {
        guard pendingDiscard else { return }
        pendingDiscard = false; pendingChanges = false
    }
    /// NSApplication may terminate without releasing window controllers. Call
    /// only after every application close guard has approved termination.
    func cleanupForTermination() {
        viewingSession?.close(); viewingSession = nil
        workspace?.cleanup(); workspace = nil
    }
    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isWorking else { status.stringValue = "Дождитесь завершения записи архива."; return false }
        if !editorWasClosed, !editor.confirmClose() { return false }
        guard confirmClose() else { return false }
        finalizeClose()
        if !editorWasClosed {
            editor.finalizeClose()
            editor.closeArchiveWorkingCopyWithoutSaving()
        }
        return true
    }
    override func windowWillClose(_ notification: Notification) {
        viewingSession?.close(); viewingSession = nil
        if let editorCloseObserver { NotificationCenter.default.removeObserver(editorCloseObserver); self.editorCloseObserver = nil }
        // Editor and viewer leases keep their working files alive independently.
        // Releasing this lease lets ARC remove the workspace after its final user.
        workspace = nil
        super.windowWillClose(notification)
    }
}

extension ArchiveEditCommitWindow {
    static func runWorkingCopyUISmokeChecks() async throws -> [String] {
        let root = (AppRuntime.smokeDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent("archive-f6-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("member.txt"), archive = root.appendingPathComponent("fixture.zip")
        try Data("one\n🙂two\n".utf8).write(to: source)
        let snapshot = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip)
        let original = try Data(contentsOf: archive)
        let workspace = try ArchiveReader.extract(snapshot, paths: ["member.txt"])
        let editor = try TextFileWindow(url: workspace.url(for: "member.txt"))
        editor.retainedArchiveWorkspace = workspace
        let controller = try ArchiveEditCommitWindow(snapshot: snapshot, path: "member.txt", workspace: workspace, editor: editor,
            onCommitted: { _ in })
        controller.showWindow(nil)
        defer { controller.window?.performClose(nil) }
        guard let session = controller.viewingSession else { throw ViewerError.unsupportedURL }
        let checks = try await WorkingCopyViewerSession.exerciseUISmoke(editor: editor, session: session, kind: "Archive")
        guard try Data(contentsOf: archive) == original, !controller.pendingChanges else {
            throw NSError(domain: "WorkingCopySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "F6 never commits archive bytes"])
        }
        return checks + ["Archive F6 leaves archive unchanged"]
    }
}
