import AppKit
import FarCore

/// A LuaFar editor saves locally and publishes on close, as FAR does after its
/// modal editor returns. A failed upload leaves both the buffer and copy open.
@MainActor
final class FarLuaPluginEditSession {
    let editor: TextFileWindow
    let pluginID: UUID
    private let workspace: RemoteWorkspace
    private let commit: @MainActor (Data, Data, String, String) async throws -> Void
    private let onClosed: @MainActor (FarLuaPluginEditSession) -> Void
    private var original: Data
    private var originalName: String
    private var savedURL: URL?
    private var revision = 0
    private var cleaned = false
    private var observer: NSObjectProtocol?
    private var preview: WorkingCopyViewerSession?
    private var uploading = false
    private var closingRequested = false
    var isWorking: Bool { uploading || closingRequested }

    init(editor: TextFileWindow, workspace: RemoteWorkspace, url: URL, original: Data,
         title: String, pluginID: UUID, commit: @escaping @MainActor (Data, Data, String, String) async throws -> Void,
         onClosed: @escaping @MainActor (FarLuaPluginEditSession) -> Void) {
        self.editor = editor
        self.pluginID = pluginID
        self.workspace = workspace
        self.original = original
        originalName = url.lastPathComponent
        self.commit = commit
        self.onClosed = onClosed
        editor.retainedRemoteWorkspace = workspace
        editor.workingCopyDisplayName = url.lastPathComponent
        editor.workingCopyDisplayPath = title
        editor.window?.subtitle = "Рабочая копия · сохранённые изменения отправятся при закрытии"
        preview = WorkingCopyViewerSession(editor: editor, url: url, title: url.lastPathComponent, remoteWorkspace: workspace)
        editor.onArchiveWorkingCopySaved = { [weak self] saved in
            self?.revision += 1
            self?.savedURL = saved.standardizedFileURL
        }
        editor.onWorkingCopyCloseRequested = { [weak self] in self?.requestClose() ?? true }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                          object: editor.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanup() }
        }
    }

    func open() {
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
    }

    private func requestClose() -> Bool {
        guard !isWorking else { NSSound.beep(); return false }
        guard savedURL != nil else { return true }
        closingRequested = true
        let capturedRevision = editor.extensionRevision
        let initialSubtitle = editor.window?.subtitle
        editor.window?.subtitle = "Отправка рабочей копии в плагин…"
        Task {
            defer { self.closingRequested = false }
            do {
                try await uploadSaved()
                if self.editor.extensionRevision == capturedRevision, self.savedURL == nil {
                    self.editor.window?.close()
                } else {
                    self.editor.window?.subtitle = initialSubtitle ?? ""
                }
            } catch {
                self.editor.window?.subtitle = initialSubtitle ?? ""
                FarLuaWorkspace.shared.report(error)
                let alert = NSAlert(error: error)
                alert.informativeText += "\nРабочая копия осталась открытой. После устранения ошибки можно закрыть редактор повторно или сохранить копию в другой файл."
                alert.runModal()
            }
        }
        return false
    }

    func uploadSaved() async throws {
        guard let savedURL else { return }
        guard !uploading else { throw ExtensionAPIError("Рабочая копия уже отправляется.") }
        let bytes = try Self.read(savedURL)
        let submittedRevision = revision
        uploading = true
        defer { uploading = false }
        try await commit(original, bytes, originalName, savedURL.lastPathComponent)
        original = bytes
        originalName = savedURL.lastPathComponent
        if revision == submittedRevision { self.savedURL = nil }
    }

    func cleanup() {
        guard !cleaned else { return }; cleaned = true
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        preview?.close()
        preview = nil
        editor.onArchiveWorkingCopySaved = nil
        editor.onWorkingCopyCloseRequested = nil
        editor.retainedRemoteWorkspace = nil
        workspace.cleanup()
        onClosed(self)
    }

    static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let limit = 8 * 1024 * 1024
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= limit else {
            throw ExtensionAPIError("Рабочая копия должна быть обычным файлом до 8 МиБ.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw ExtensionAPIError("Рабочая копия превышает 8 МиБ.") }
        return bytes
    }
}
