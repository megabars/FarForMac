import AppKit
import FarCore

/// The edit session keeps its editor alive while F6 temporarily shows the saved
/// working bytes. Both windows independently retain the workspace. Upload/archive
/// mutation remains owned by the explicit commit window, outside this bridge.
@MainActor
final class WorkingCopyViewerSession {
    private let editor: TextFileWindow
    private let workingURL: URL
    private let archiveWorkspace: ArchiveWorkspace?
    private let remoteWorkspace: RemoteWorkspace?
    private let title: String
    private(set) var viewer: ViewerWindow?
    private var active = true

    init(editor: TextFileWindow, url: URL, title: String,
         archiveWorkspace: ArchiveWorkspace? = nil, remoteWorkspace: RemoteWorkspace? = nil) {
        self.editor = editor; workingURL = url.standardizedFileURL; self.title = title
        self.archiveWorkspace = archiveWorkspace; self.remoteWorkspace = remoteWorkspace
        editor.onWorkingCopyView = { [weak self] url, offset, encoding in
            self?.showViewer(url: url, offset: offset, encoding: encoding) ?? false
        }
    }

    private func showViewer(url: URL, offset: Int64, encoding: ViewerEncoding) -> Bool {
        guard active, url.standardizedFileURL == editor.workingFileURL?.standardizedFileURL else { return false }
        let linked = url.standardizedFileURL == workingURL
        do {
            // Reopen a fresh snapshot of bytes saved since the previous F6.
            viewer?.window?.close()
            let viewer = try ViewerWindow(url: url, initialByteOffset: offset, initialEncoding: encoding,
                onEdit: { [weak self] url, offset, _ in self?.returnToEditor(url: url, offset: offset) ?? false })
            viewer.retainedArchiveWorkspace = linked ? archiveWorkspace : nil
            viewer.retainedRemoteWorkspace = linked ? remoteWorkspace : nil
            viewer.window?.title = linked ? title + " — Просмотр рабочей копии" : url.lastPathComponent + " — Просмотр"
            self.viewer = viewer; viewer.showWindow(nil); viewer.window?.makeKeyAndOrderFront(nil)
            return true
        } catch {
            let alert = NSAlert(); alert.messageText = "Не удалось открыть просмотр"; alert.informativeText = error.localizedDescription
            alert.runModal(); return false
        }
    }

    private func returnToEditor(url: URL, offset: Int64) -> Bool {
        guard active, editor.workingFileURL?.standardizedFileURL == url.standardizedFileURL else { return false }
        editor.moveToByteOffset(offset)
        editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func close() {
        active = false; editor.onWorkingCopyView = nil
        viewer?.window?.close(); viewer = nil
    }
}

extension WorkingCopyViewerSession {
    static func exerciseUISmoke(editor: TextFileWindow, session: WorkingCopyViewerSession, kind: String) async throws -> [String] {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: "WorkingCopySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let originalWindow = editor.window
        editor.showWindow(nil); editor.moveToByteOffset(9)
        editor.switchWorkingCopyToViewer()
        guard let viewer = session.viewer else { throw NSError(domain: "WorkingCopySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: kind + " F6 opens linked viewer"]) }
        let deadline = Date().addingTimeInterval(5)
        while viewer.extensionText.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(editor.window?.isVisible == false && viewer.window?.isVisible == true, kind + " F6 hides editor and shows viewer")
        try require(viewer.currentByteOffset == 9, kind + " F6 preserves original byte offset")
        try require(FileManager.default.fileExists(atPath: session.workingURL.path), kind + " viewing keeps private workspace")
        _ = viewer.perform(NSSelectorFromString("editRequested"))
        try require(editor.window === originalWindow && editor.window?.isVisible == true && viewer.window?.isVisible == false,
                    kind + " F6 returns to same editor instance")
        try require(editor.extensionSelection.location == 7, kind + " return preserves Unicode cursor position")
        return [kind + " working-copy F6 preserves byte position", kind + " working-copy F6 returns to original editor", kind + " viewer retains private workspace"]
    }

    static func runWorkingCopyUISmokeChecks() async throws -> [String] {
        let archive = try await ArchiveEditCommitWindow.runWorkingCopyUISmokeChecks()
        let remote = try await NetworkEditWindow.runWorkingCopyUISmokeChecks()
        return archive + remote
    }
}
