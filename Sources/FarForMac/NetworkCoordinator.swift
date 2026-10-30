import AppKit
import FarCore

@MainActor private final class NetworkViewLease {
    let workspace: RemoteWorkspace, snapshot: RemoteEditSnapshot, provider: any RemoteProvider
    init(_ workspace: RemoteWorkspace, _ snapshot: RemoteEditSnapshot, _ provider: any RemoteProvider) { self.workspace = workspace; self.snapshot = snapshot; self.provider = provider }
}
private final class NetworkDownloadBatch {
    let tasks: [RemoteDownloadTask]
    private(set) var index = 0
    init(_ tasks: [RemoteDownloadTask]) { self.tasks = tasks }
    func run(_ token: TransferCancellation, _ progress: @escaping (NetworkProgress) -> Void) throws {
        while index < tasks.count { try tasks[index].run(cancellation: token, progress: progress); index += 1 }
    }
    func cleanup() { tasks.forEach { $0.cleanup() } }
}
@MainActor final class NetworkCoordinator {
    var canStart: () -> Bool = { true }
    var onStatus: (String) -> Void = { _ in }, onError: (Error) -> Void = { _ in }
    var onChanged: () -> Void = {}
    private let operations = NetworkOperationController()
    private var pendingDownload: NetworkDownloadBatch?
    var hasPendingDownload: Bool { pendingDownload != nil && !isWorking }
    private var connectionWindow: NetworkConnectionWindow?
    private var editors: [TextFileWindow] = [], viewers: [ViewerWindow] = [], edits: [NetworkEditWindow] = []
    var isWorking: Bool { operations.isWorking || edits.contains { $0.isWorking } }
    func cancel() { operations.cancel(); edits.forEach { $0.cancel() } }
    func retryDownload() {
        guard available(), let batch = pendingDownload else { return }
        runDownload(batch)
    }
    func discardDownload() {
        guard available(), let batch = pendingDownload else { return }
        batch.cleanup(); pendingDownload = nil; onStatus("Незавершённая локальная копия удалена. Сервер не изменён.")
    }
    private func runDownload(_ batch: NetworkDownloadBatch) {
        operations.run(title: "Скачивание / проверенная докачка", work: { token, progress in try batch.run(token, progress) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                batch.cleanup(); self.pendingDownload = nil; self.onStatus("Скачивание завершено."); self.onChanged()
            case .failure(let error):
                self.onError(NetworkError.io(error.localizedDescription + "\nЧастичная копия удерживается до повтора или сброса. Используйте «Сеть → Продолжить скачивание»; если версия изменилась, сбросьте задание и начните заново."))
            }
        }
    }
    func connect(in panel: PanelView) {
        guard available() else { return }
        let window = NetworkConnectionWindow(); connectionWindow = window
        window.onConnect = { [weak self, weak panel] connection, password, save, saveSecret in
            guard let self, let panel else { return }
            self.connect(connection, password: password, in: panel, save: save, saveSecret: saveSecret)
        }
        window.showWindow(nil)
    }
    private func connect(_ connection: NetworkConnection, password: String?, in panel: PanelView, save: Bool, saveSecret: Bool) {
        guard available() else { return }
        let generation = panel.locationGeneration
        let provider: any RemoteProvider
        switch connection.kind {
        case .sftp: provider = SFTPProvider(connection: connection)
        case .ftp, .ftps: provider = FTPRemoteProvider(connection: connection, password: password)
        case .webdav, .webdavs: provider = WebRemoteProvider(connection: connection, password: password)
        }
        operations.run(title: "Подключение: " + connection.displayName, work: { token, _ in try provider.list(path: connection.rootPath, cancellation: token) }) { [weak self, weak panel] result in
            guard let self, let panel, panel.locationGeneration == generation else { return }
            switch result {
            case .success(let entries):
                do {
                    if save {
                        var profiles = try NetworkProfileStore.load(); profiles.removeAll { $0.id == connection.id }; profiles.append(connection)
                        try NetworkProfileStore.save(profiles)
                        if saveSecret, let password { try NetworkCredentials.save(password: password, for: connection.id) }
                    }
                } catch { self.onError(error) }
                let browser = RemotePanelView(provider: provider, path: connection.rootPath, entries: entries)
                browser.onNavigate = { [weak self, weak panel] path in if let panel { self?.refresh(panel, path: path) } }
                browser.onView = { [weak self, weak panel] _ in if let panel { self?.open(panel, editable: false) } }
                panel.showRemote(browser); self.onStatus("Подключено: " + connection.displayName)
            case .failure(let error):
                if error as? SFTPError == .unknownHostKey { self.verifyHost(connection, password: password, panel: panel, save: save, saveSecret: saveSecret) }
                else { self.onError(error) }
            }
        }
    }
    private func verifyHost(_ connection: NetworkConnection, password: String?, panel: PanelView, save: Bool, saveSecret: Bool) {
        let store = SFTPHostKeyStore(), generation = panel.locationGeneration
        operations.run(title: "Отпечаток SSH-сервера", work: { token, _ in try store.probe(connection: connection, cancellation: token) }) { [weak self, weak panel] result in
            guard let self, let panel, panel.locationGeneration == generation else { return }
            switch result {
            case .failure(let error): self.onError(error)
            case .success(let keys):
                guard let key = keys.first(where: { $0.keyType == "ssh-ed25519" }) ?? keys.first else { self.onError(NetworkError.io("Сервер не предоставил ключ.")); return }
                let alert = NSAlert(); alert.messageText = "Проверьте ключ SSH-сервера"
                alert.informativeText = "\(connection.host):\(connection.port)\n\(key.keyType)\n\(key.fingerprint)\n\nСравните этот отпечаток с полученным от владельца сервера по доверенному каналу. Само получение ключа из сети не подтверждает подлинность сервера."
                alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Отпечаток проверен — доверять")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                do { try store.trust(key); self.connect(connection, password: password, in: panel, save: save, saveSecret: saveSecret) } catch { self.onError(error) }
            }
        }
    }
    func refresh(_ panel: PanelView, path: String? = nil, completion: @escaping () -> Void = {}) {
        guard available(quiet: true), let browser = panel.remotePanel else { completion(); return }
        let target = path ?? browser.currentPath
        operations.run(title: "Чтение сетевой папки", work: { token, _ in try browser.provider.list(path: target, cancellation: token) }) { [weak self, weak panel, weak browser] result in
            defer { completion() }
            guard let self, let panel, panel.remotePanel === browser else { return }
            switch result { case .success(let entries): browser?.update(path: target, entries: entries); if path != nil && panel.active { panel.focus() }; case .failure(let error): self.onError(error) }
        }
    }
    func goTo(_ panel: PanelView) {
        guard let browser = panel.remotePanel, available() else { return }
        if let path = prompt("Удалённая папка", value: browser.currentPath) { do { refresh(panel, path: try RemotePath.validate(path)) } catch { onError(error) } }
    }
    func open(_ panel: PanelView, editable: Bool) {
        guard available(), let browser = panel.remotePanel, let entry = browser.cursor, !entry.isDirectory, !entry.isSymbolicLink else { return }
        operations.run(title: "Рабочая копия: " + entry.name, work: { token, progress -> (RemoteWorkspace, RemoteEditSnapshot) in
            let workspace = try RemoteWorkspace()
            return (workspace, try workspace.open(provider: browser.provider, path: entry.path, cancellation: token, progress: progress))
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.onError(error)
            case .success(let (workspace, snapshot)):
                if editable { _ = self.edit(workspace, snapshot, browser.provider) }
                else {
                    let lease = NetworkViewLease(workspace, snapshot, browser.provider)
                    do {
                        let viewer = try ViewerWindow(url: snapshot.localURL, onEdit: { [weak self, weak lease] url, offset, encoding in
                            guard let self, let lease, url.standardizedFileURL == lease.snapshot.localURL.standardizedFileURL else { return false }
                            return self.edit(lease.workspace, lease.snapshot, lease.provider, offset: offset, encoding: encoding)
                        })
                        viewer.retainedRemoteWorkspace = workspace; viewer.retainedRemoteLease = lease
                        self.viewers.removeAll { $0.window?.isVisible == false }; self.viewers.append(viewer)
                        viewer.showWindow(nil); viewer.window?.title = entry.name + " — Просмотр"; viewer.window?.subtitle = browser.caption + (browser.currentPath == "/" ? "" : "/") + entry.name
                    } catch { self.onError(error) }
                }
            }
        }
    }
    private func edit(_ workspace: RemoteWorkspace, _ snapshot: RemoteEditSnapshot, _ provider: any RemoteProvider,
                      offset: Int64? = nil, encoding: ViewerEncoding = .automatic) -> Bool {
        do {
            let editor = try TextFileWindow(url: snapshot.localURL, initialByteOffset: offset, encoding: encoding)
            editor.retainedRemoteWorkspace = workspace
            editor.workingCopyDisplayName = snapshot.entry.name
            editor.workingCopyDisplayPath = provider.connection.displayName + " · " + snapshot.entry.path
            let session = NetworkEditWindow(snapshot: snapshot, workspace: workspace, provider: provider, editor: editor,
                canCommit: { [weak self] in self?.available() ?? false }, onCommitted: { [weak self] in self?.onChanged() })
            editors.removeAll { $0.window?.isVisible == false }; edits.removeAll { $0.window?.isVisible == false }
            editors.append(editor); edits.append(session)
            session.showWindow(nil); editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            editor.window?.subtitle = "Сетевая рабочая копия · отправка отдельной кнопкой"
            return true
        } catch { onError(error); return false }
    }
    func transfer(from active: PanelView, to passive: PanelView, move: Bool, cursorOnly: Bool = false) {
        guard available(), active.isRemote != passive.isRemote, !active.isArchive, !passive.isArchive else { onStatus("Для сетевой передачи выберите одну обычную и одну сетевую панель."); return }
        let remote = active.remotePanel ?? passive.remotePanel!
        let download = active.isRemote
        let entries = download ? (cursorOnly ? remote.cursor.map { [$0] } ?? [] : remote.selectedEntries) : []
        let files = download ? [] : (cursorOnly ? active.cursorEntry.map { [$0] } ?? [] : active.selectedEntries)
        guard !(download ? entries.isEmpty : files.isEmpty) else { return }
        let initial = download ? passive.directory.path : remote.currentPath
        guard let value = prompt(move ? "Перенести — источник удаляется после проверки копии" : "Копировать", value: initial) else { return }
        let alert = NSAlert(); alert.messageText = "Если файл назначения существует"
        alert.informativeText = "Выбор применяется к этому заданию. Каталоги копируются в новые папки; объединение удалённых каталогов и перенос каталогов пока недоступны."
        alert.addButton(withTitle: "Остановиться на конфликте"); alert.addButton(withTitle: "Разрешить замену файлов"); alert.addButton(withTitle: "Отмена")
        let answer = alert.runModal(); guard answer != .alertThirdButtonReturn else { return }; let replace = answer == .alertSecondButtonReturn
        do {
            let target = download ? (value as NSString).expandingTildeInPath : try RemotePath.validate(value)
            if download, !target.hasPrefix("/") { throw NetworkError.invalidPath(target) }
            let captured = active.capturedSearchResults(for: files)
            try captured.forEach { try $0.verifyCurrent() }
            if download && !move && entries.allSatisfy({ !$0.isDirectory && !$0.isSymbolicLink }) {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else { throw NetworkError.invalidPath("Назначение должно быть существующей локальной папкой.") }
                if pendingDownload != nil {
                    let alert = NSAlert(); alert.messageText = "Начать новое скачивание?"; alert.informativeText = "Прежняя незавершённая локальная копия будет удалена."
                    alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Начать новое")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                    pendingDownload?.cleanup(); pendingDownload = nil
                }
                let tasks = try entries.map { try RemoteDownloadTask(provider: remote.provider, path: $0.path, destination: URL(fileURLWithPath: target).appendingPathComponent($0.name), replace: replace) }
                let batch = NetworkDownloadBatch(tasks); pendingDownload = batch; runDownload(batch); return
            }
            operations.run(title: move ? "Сетевое перемещение" : "Сетевое копирование", work: { token, progress in
                try captured.forEach { try $0.verifyCurrent() }
                if download {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else { throw NetworkError.invalidPath("Назначение должно быть существующей локальной папкой.") }
                    for entry in entries {
                        guard try remote.provider.stat(path: entry.path, cancellation: token) == entry else { throw NetworkError.changedSource }
                        try RemoteTransferEngine.download(provider: remote.provider, path: entry.path, to: URL(fileURLWithPath: target).appendingPathComponent(entry.name), replace: replace, move: move, cancellation: token, progress: progress) }
                } else {
                    for file in files { try RemoteTransferEngine.upload(provider: remote.provider, from: file.url, to: RemotePath.child(file.name, of: target), replace: replace, move: move, cancellation: token, progress: progress) }
                }
            }) { [weak self] result in self?.finished(result) }
        } catch { onError(error) }
    }
    func remove(_ panel: PanelView) {
        guard available(), let browser = panel.remotePanel, !browser.selectedEntries.isEmpty else { return }
        let entries = browser.selectedEntries
        let alert = NSAlert(); alert.messageText = "Удалить с сервера без Корзины?"
        alert.informativeText = entries.prefix(8).map(\.path).joined(separator: "\n") + "\nУдаление необратимо. Непустые каталоги требуют удаления содержимого отдельными действиями."
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Удалить с сервера")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        operations.run(title: "Удаление с сервера", work: { token, _ in
            for entry in entries { try RemoteTransferEngine.delete(provider: browser.provider, entry: entry, cancellation: token) }
        }) { [weak self] result in self?.finished(result) }
    }
    func makeDirectory(_ panel: PanelView) {
        guard available(), let browser = panel.remotePanel, let name = prompt("Новая папка на сервере", value: "") else { return }
        do {
            let path = try RemotePath.child(name, of: browser.currentPath)
            operations.run(title: "Создание сетевой папки", work: { token, _ in try browser.provider.makeDirectory(path: path, cancellation: token) }) { [weak self] result in self?.finished(result) }
        } catch { onError(error) }
    }
    private func finished(_ result: Result<Void, Error>) {
        switch result { case .success: onStatus("Сетевая операция завершена."); case .failure(let error): onError(error) }
        onChanged()
    }
    private func available(quiet: Bool = false) -> Bool {
        if isWorking || !canStart() { if !quiet { onStatus("Дождитесь завершения текущей файловой операции.") }; return false }; return true
    }
    private func prompt(_ title: String, value: String) -> String? {
        let alert = NSAlert(); alert.messageText = title
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 500, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    func confirmTermination() -> Bool {
        guard !isWorking else { return false }
        for editor in editors where editor.window?.isVisible == true { if !editor.confirmClose() { return false } }
        for session in edits where session.window?.isVisible == true { if !session.confirmClose() { return false } }
        return true
    }
    func finalizeTermination() {
        pendingDownload?.cleanup(); pendingDownload = nil
        editors.forEach { $0.finalizeClose(); $0.retainedRemoteWorkspace?.cleanup() }
        edits.forEach { $0.finalizeClose(); $0.cleanupForTermination() }
        viewers.forEach { $0.cancelBackgroundWork(); $0.retainedRemoteWorkspace?.cleanup() }
        editors.removeAll(); edits.removeAll(); viewers.removeAll()
    }
}
