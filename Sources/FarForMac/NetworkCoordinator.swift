import AppKit
import FarCore

@MainActor private final class NetworkViewLease {
    let workspace: RemoteWorkspace, snapshot: RemoteEditSnapshot, provider: any RemoteProvider
    init(_ workspace: RemoteWorkspace, _ snapshot: RemoteEditSnapshot, _ provider: any RemoteProvider) { self.workspace = workspace; self.snapshot = snapshot; self.provider = provider }
}
private final class WeakSFTPConnection {
    weak var provider: SFTPProvider?
    init(_ provider: SFTPProvider) { self.provider = provider }
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
    private lazy var sshAuthentication = SSHAuthenticationPresenter()
    private var authenticationHandler: SFTPAuthenticationHandler {
        let presenter = sshAuthentication
        return { [weak presenter] challenge in
            guard let presenter else { try? challenge.respond(nil); return }
            presenter.handle(challenge)
        }
    }
    private var pendingDownload: NetworkDownloadBatch?
    var hasPendingDownload: Bool { pendingDownload != nil && !isWorking }
    private var connectionWindow: NetworkConnectionWindow?
    private var sshConnections: [WeakSFTPConnection] = []
    private func rememberConnection(_ provider: any RemoteProvider) {
        sshConnections.removeAll { $0.provider == nil }
        guard let ssh = provider as? SFTPProvider, !sshConnections.contains(where: { $0.provider === ssh }) else { return }
        sshConnections.append(WeakSFTPConnection(ssh))
    }
    /// Installs lazy restoration dependencies. Configuration itself does not read
    /// credentials, construct connections or navigate either panel.
    func configureSavedPanelRestore(_ controller: SavedPanelRestoreController) {
        let handler = authenticationHandler
        controller.providerFactory = { [weak self, weak controller] connection, token in
            try connection.validate()
            guard !token.isCancelled, let controller else { throw ViewerError.cancelled }
            let password = try SavedRestoreNetworkCredentials.password(for: connection, request: {
                try controller.requestPassword(title: "Вход на исходный сервер", detail: $0, cancellation: token)
            })
            guard !token.isCancelled else { throw ViewerError.cancelled }
            let provider: any RemoteProvider
            switch connection.kind {
            case .sftp:
                provider = SFTPProvider(connection: connection, password: password, authenticationHandler: handler)
            case .ftp, .ftps: provider = FTPRemoteProvider(connection: connection, password: password)
            case .webdav, .webdavs: provider = WebRemoteProvider(connection: connection, password: password)
            }
            DispatchQueue.main.async { self?.rememberConnection(provider) }
            return provider
        }
        controller.recoverNetworkTrust = { [weak controller] error, connection, token in
            guard let controller else { throw ViewerError.cancelled }
            return try SavedRestoreNetworkTrust.recover(error, connection: connection, cancellation: token,
                authenticationHandler: handler, confirm: { key, endpoint in
                    try controller.confirmHostKey(key, endpoint: endpoint, cancellation: token)
                })
        }
        controller.onCancel = { [weak self] in self?.sshAuthentication.cancelAll() }
    }
    func disconnected(_ provider: any RemoteProvider) {
        // Cancel the whole job as well as its current SSH request. Otherwise a
        // tree worker between requests could reconnect on its next stat/remove.
        cancel()
        guard let ssh = provider as? SFTPProvider else { return }
        ssh.closeConnection()
    }
    func reconnect(_ panel: PanelView) {
        guard available(), let browser = panel.remotePanel, let provider = browser.provider as? SFTPProvider else { return }
        let path = browser.currentPath
        operations.run(title: L10n.text("Новое SSH-соединение"), work: { token, _ in
            provider.closeConnection()
            return try provider.list(path: path, cancellation: token)
        }) { [weak self, weak panel, weak browser] result in
            guard let self, let panel, let browser, panel.remotePanel === browser else { return }
            switch result {
            case .success(let entries): browser.update(path: path, entries: entries); self.onStatus(L10n.text("SSH-соединение установлено заново."))
            case .failure(let error): self.onError(error)
            }
        }
    }
    private var editors: [TextFileWindow] = [], viewers: [ViewerWindow] = [], edits: [NetworkEditWindow] = []
    var isWorking: Bool { operations.isWorking || edits.contains { $0.isWorking } }
    func cancel() { operations.cancel(); edits.forEach { $0.cancel() }; sshAuthentication.cancelAll() }
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
        let window = NetworkConnectionWindow(profiles: AppRuntime.isSmoke ? [] : nil); connectionWindow = window
        window.onConnect = { [weak self, weak panel] connection, password, save, saveSecret in
            guard let self, let panel else { return }
            self.connect(connection, password: password, in: panel, save: save, saveSecret: saveSecret)
        }
        window.showWindow(nil)
    }
    func connectProfile(_ connection: NetworkConnection, password suppliedPassword: String? = nil, in panel: PanelView) {
        guard available(), NetworkConnectionWindow.confirmCleartextConnection(connection.kind) else { return }
        do {
            var password = suppliedPassword
            let needsPassword = connection.kind != .sftp || connection.sftpAuthenticationMode == .password
            if needsPassword, password == nil { password = try NetworkCredentials.password(for: connection.id) }
            if needsPassword, password == nil {
                let alert = NSAlert(); alert.messageText = "Вход на сервер"
                alert.informativeText = "\(connection.username)@\(connection.host):\(connection.port)"
                let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                field.placeholderString = "Пароль"; field.setAccessibilityLabel("Пароль")
                alert.accessoryView = field; alert.addButton(withTitle: "Подключиться"); alert.addButton(withTitle: "Отмена")
                alert.window.initialFirstResponder = field
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                password = field.stringValue; field.stringValue = ""
            }
            connect(connection, password: password, in: panel, save: false, saveSecret: false)
        } catch { onError(error) }
    }
    private func connect(_ connection: NetworkConnection, password: String?, in panel: PanelView, save: Bool, saveSecret: Bool) {
        guard available() else { return }
        let generation = panel.locationGeneration
        let provider: any RemoteProvider
        switch connection.kind {
        case .sftp:
            if connection.sftpAuthenticationMode == .password && (password?.isEmpty ?? true) {
                onError(NetworkError.invalidConnection(L10n.text("Введите пароль для входа SFTP."))); return
            }
            provider = SFTPProvider(connection: connection, password: connection.sftpAuthenticationMode == .password ? password : nil, authenticationHandler: authenticationHandler)
        case .ftp, .ftps: provider = FTPRemoteProvider(connection: connection, password: password)
        case .webdav, .webdavs: provider = WebRemoteProvider(connection: connection, password: password)
        }
        rememberConnection(provider)
        operations.run(title: "Подключение: " + connection.displayName, work: { token, _ in try provider.list(path: connection.rootPath, cancellation: token) }) { [weak self, weak panel] result in
            guard let self, let panel, panel.locationGeneration == generation else { return }
            switch result {
            case .success(let entries):
                do {
                    if save {
                        var profiles = try NetworkProfileStore.load(); profiles.removeAll { $0.id == connection.id }; profiles.append(connection)
                        // Remove the old credential before changing metadata: a failed Keychain
                        // update must never associate an old host's secret with a new host.
                        try NetworkCredentials.remove(for: connection.id)
                        try NetworkProfileStore.save(profiles)
                        if saveSecret, connection.kind != .sftp || connection.sftpAuthenticationMode == .password, let password {
                            try NetworkCredentials.save(password: password, for: connection.id)
                        }
                    }
                } catch { self.onError(error) }
                let browser = RemotePanelView(provider: provider, path: connection.rootPath, entries: entries)
                browser.onNavigate = { [weak self, weak panel] path in if let panel { self?.refresh(panel, path: path) } }
                browser.onView = { [weak self, weak panel] _ in if let panel { self?.open(panel, editable: false) } }
                panel.showRemote(browser); self.onStatus("Подключено: " + connection.displayName)
            case .failure(let error):
                self.connectionFailed(error, connection: connection, password: password, panel: panel, save: save, saveSecret: saveSecret)
            }
        }
    }
    private func connectionFailed(_ error: Error, connection: NetworkConnection, password: String?, panel: PanelView, save: Bool, saveSecret: Bool) {
        if let jumpError = error as? SFTPJumpHostError {
            if jumpError.error == .unknownHostKey {
                verifyHost(connection, jumpHostIndex: jumpError.index, password: password, panel: panel, save: save, saveSecret: saveSecret)
            } else {
                onError(NetworkError.io(sshEndpoint(connection, jumpHostIndex: jumpError.index) + "\n" + jumpError.error.localizedDescription))
            }
        } else if error as? SFTPError == .unknownHostKey {
            verifyHost(connection, password: password, panel: panel, save: save, saveSecret: saveSecret)
        } else if connection.kind == .sftp {
            onError(NetworkError.io(sshEndpoint(connection) + "\n" + error.localizedDescription))
        } else { onError(error) }
    }
    private func sshEndpoint(_ connection: NetworkConnection, jumpHostIndex: Int? = nil) -> String {
        if let index = jumpHostIndex, connection.sftpJumpHosts.indices.contains(index) {
            let jump = connection.sftpJumpHosts[index]
            return L10n.text("Промежуточный SSH-сервер") + " \(index + 1): \(jump.host):\(jump.port)"
        }
        return L10n.text("Целевой SSH-сервер") + ": \(connection.host):\(connection.port)"
    }
    private func verifyHost(_ connection: NetworkConnection, jumpHostIndex: Int? = nil, password: String?, panel: PanelView, save: Bool, saveSecret: Bool) {
        let store = SFTPHostKeyStore(), generation = panel.locationGeneration
        let handler = authenticationHandler
        operations.run(title: L10n.text("Отпечаток SSH-сервера") + " · " + sshEndpoint(connection, jumpHostIndex: jumpHostIndex), work: { token, _ in try store.probe(connection: connection, jumpHostIndex: jumpHostIndex, cancellation: token, authenticationHandler: handler) }) { [weak self, weak panel] result in
            guard let self, let panel, panel.locationGeneration == generation else { return }
            switch result {
            case .failure(let error):
                if let jumpError = error as? SFTPJumpHostError {
                    self.connectionFailed(jumpError, connection: connection, password: password, panel: panel, save: save, saveSecret: saveSecret)
                } else { self.onError(NetworkError.io(self.sshEndpoint(connection, jumpHostIndex: jumpHostIndex) + "\n" + error.localizedDescription)) }
            case .success(let keys):
                guard let key = keys.first(where: { $0.keyType == "ssh-ed25519" }) ?? keys.first else { self.onError(NetworkError.io("Сервер не предоставил ключ.")); return }
                let alert = NSAlert(); alert.messageText = L10n.text("Проверьте ключ SSH-сервера")
                alert.informativeText = self.sshEndpoint(connection, jumpHostIndex: jumpHostIndex) + "\n\(key.host):\(key.port)\n\(key.keyType)\n\(key.fingerprint)\n\n" + L10n.text("Сравните этот отпечаток с полученным от владельца сервера по доверенному каналу. Само получение ключа из сети не подтверждает подлинность сервера.")
                alert.addButton(withTitle: L10n.text("Отмена")); alert.addButton(withTitle: L10n.text("Отпечаток проверен — доверять"))
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
        guard let browser = panel.remotePanel, let entry = browser.cursor else { return }
        open(provider: browser.provider, entry: entry, caption: browser.caption, editable: editable)
    }
    func openSearchResult(_ result: ProviderSearchResult, provider: any RemoteProvider, editable: Bool) {
        guard let entry = result.remoteEntry else { return }
        open(provider: provider, entry: entry, caption: provider.connection.displayName, editable: editable,
             byteOffset: result.byteOffset, expectedSearchResult: result)
    }
    func open(provider: any RemoteProvider, entry: RemoteEntry, caption: String, editable: Bool, byteOffset: Int64? = nil,
              expectedSearchResult: ProviderSearchResult? = nil) {
        guard available(), !entry.isDirectory, !entry.isSymbolicLink else { return }
        operations.run(title: "Рабочая копия: " + entry.name, work: { token, progress -> (RemoteWorkspace, RemoteEditSnapshot) in
            try expectedSearchResult?.verifyRemoteCurrent(provider: provider, cancellation: token)
            guard try provider.stat(path: entry.path, cancellation: token) == entry else { throw NetworkError.changedSource }
            let workspace = try RemoteWorkspace()
            let snapshot = try workspace.open(provider: provider, path: entry.path, cancellation: token, progress: progress)
            guard snapshot.entry == entry else { workspace.cleanup(); throw NetworkError.changedSource }
            try expectedSearchResult?.verifyRemoteCurrent(provider: provider, cancellation: token)
            return (workspace, snapshot)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.onError(error)
            case .success(let (workspace, snapshot)):
                if editable { _ = self.edit(workspace, snapshot, provider, offset: byteOffset) }
                else {
                    let lease = NetworkViewLease(workspace, snapshot, provider)
                    do {
                        let viewer = try ViewerWindow(url: snapshot.localURL, initialByteOffset: byteOffset, initialDisplayMode: byteOffset == nil ? nil : .hex, onEdit: { [weak self, weak lease] url, offset, encoding in
                            guard let self, let lease, url.standardizedFileURL == lease.snapshot.localURL.standardizedFileURL else { return false }
                            return self.edit(lease.workspace, lease.snapshot, lease.provider, offset: offset, encoding: encoding)
                        })
                        viewer.retainedRemoteWorkspace = workspace; viewer.retainedRemoteLease = lease
                        self.viewers.removeAll { $0.window?.isVisible == false }; self.viewers.append(viewer)
                        viewer.showWindow(nil); viewer.window?.title = entry.name + " — Просмотр"; viewer.window?.subtitle = caption + " · " + entry.path
                    } catch { self.onError(error) }
                }
            }
        }
    }
    func revealSearchResult(_ result: ProviderSearchResult, provider: any RemoteProvider, in panel: PanelView,
                            completion: @escaping () -> Void) {
        guard available(), let expected = result.remoteEntry else { return }
        rememberConnection(provider)
        let parent = RemotePath.parent(expected.path)
        let generation = panel.locationGeneration
        operations.run(title: "Переход к результату поиска", work: { token, _ in
            try result.verifyRemoteCurrent(provider: provider, cancellation: token)
            let entries = try provider.list(path: parent, cancellation: token)
            guard entries.contains(expected), try provider.stat(path: expected.path, cancellation: token) == expected else { throw NetworkError.changedSource }
            return entries
        }) { [weak self, weak panel] value in
            guard let self, let panel, panel.locationGeneration == generation else { return }
            switch value {
            case .failure(let error): self.onError(error)
            case .success(let entries):
                let browser = RemotePanelView(provider: provider, path: parent, entries: entries)
                browser.onNavigate = { [weak self, weak panel] path in if let panel { self?.refresh(panel, path: path) } }
                browser.onView = { [weak self, weak panel] _ in if let panel { self?.open(panel, editable: false) } }
                panel.showRemote(browser)
                browser.selectPath(expected.path)
                completion()
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
            editors.removeAll { $0.window?.isVisible == false && $0.retainedRemoteWorkspace == nil }
            edits.removeAll { $0.window?.isVisible == false }
            editors.append(editor); edits.append(session)
            session.showWindow(nil); editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
            editor.window?.subtitle = "Сетевая рабочая копия · отправка отдельной кнопкой"
            return true
        } catch { onError(error); return false }
    }
    func transfer(from active: PanelView, to passive: PanelView, move: Bool, cursorOnly: Bool = false) {
        guard available(), !active.isResource, !passive.isResource, !active.isVirtual, !passive.isVirtual, !passive.isTemporary else { return }
        if active.isRemote && passive.isRemote {
            guard move else { onStatus("Копирование между двумя сетевыми панелями пока недоступно."); return }
            moveRemote(from: active, to: passive, cursorOnly: cursorOnly); return
        }
        guard active.isRemote != passive.isRemote, !active.isArchive, !passive.isArchive else { onStatus("Для сетевой передачи выберите одну обычную и одну сетевую панель."); return }
        let remote = active.remotePanel ?? passive.remotePanel!
        let download = active.isRemote
        let entries = download ? (cursorOnly ? remote.cursor.map { [$0] } ?? [] : remote.selectedEntries) : []
        let files = download ? [] : (cursorOnly ? active.cursorEntry.map { [$0] } ?? [] : active.selectedEntries)
        guard !(download ? entries.isEmpty : files.isEmpty) else { return }
        let initial = download ? passive.directory.path : remote.currentPath
        guard let value = prompt(move ? "Перенести — источник удаляется после проверки копии" : "Копировать", value: initial) else { return }
        if download ? entries.contains(where: { $0.isDirectory }) : files.contains(where: { $0.isDirectory }) {
            if move && download && !(remote.provider is RemoteNonRecursiveDirectoryRemoval) {
                onError(NetworkError.unsupported("Перенос папок с удалением источника доступен с SFTP/FTP. WebDAV удаляет папку рекурсивно; для него используйте копирование.")); return
            }
            prepareDirectoryTransfer(from: active, to: passive, provider: remote.provider, entries: entries, files: files,
                                     destination: value, download: download, move: move)
            return
        }
        let alert = NSAlert(); alert.messageText = "Если файл назначения существует"
        alert.informativeText = "Выбор применяется к этому заданию. Это задание содержит только обычные файлы. Для папок используется отдельный предпросмотр дерева и конфликтов."
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
    private func prepareDirectoryTransfer(from active: PanelView, to passive: PanelView, provider: any RemoteProvider,
                                          entries: [RemoteEntry], files: [FileEntry], destination: String, download: Bool, move: Bool) {
        let policyAlert = NSAlert(); policyAlert.messageText = move ? L10n.text("Перенос дерева: конфликты") : L10n.text("Копирование дерева: конфликты")
        policyAlert.informativeText = L10n.text("Выберите новые назначения или слияние папок. При слиянии для каждого конфликта можно выбрать пропуск, замену обычного файла или другое имя. Затем будет показан итоговый план.")
        policyAlert.addButton(withTitle: "Отмена"); policyAlert.addButton(withTitle: "Только новые назначения"); policyAlert.addButton(withTitle: L10n.text("Слияние / выбрать конфликты"))
        let answer = policyAlert.runModal(); guard answer != .alertFirstButtonReturn else { return }
        let policy: RemoteDirectoryConflictPolicy = answer == .alertThirdButtonReturn ? .mergeSkippingExisting : .requireNew
        let sourceGeneration = active.locationGeneration, targetGeneration = passive.locationGeneration
        let captured = active.capturedSearchResults(for: files)
        operations.run(title: "Предпросмотр сетевого копирования дерева", work: { token, progress in
            try captured.forEach { try $0.verifyCurrent() }
            if download {
                let target = (destination as NSString).expandingTildeInPath
                guard target.hasPrefix("/") else { throw NetworkError.invalidPath(target) }
                return try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: entries,
                    into: URL(fileURLWithPath: target), policy: policy, cancellation: token, progress: progress)
            }
            return try RemoteDirectoryTransfer.prepareUpload(provider: provider, sources: files.map(\.url),
                into: destination, policy: policy, cancellation: token, progress: progress)
        }) { [weak self, weak active, weak passive] result in
            guard let self, let active, let passive,
                  active.locationGeneration == sourceGeneration, passive.locationGeneration == targetGeneration else { return }
            switch result {
            case .failure(let error): self.onError(error)
            case .success(let plan):
                if plan.conflicts.isEmpty { self.confirmDirectoryTransfer(provider: provider, plan: plan, move: move, captured: captured); return }
                let editor = NetworkConflictEditor(plan: plan)
                let alert = NSAlert(); alert.messageText = L10n.text("Конфликты при слиянии")
                alert.informativeText = L10n.text("Выберите действие для каждой строки. Папки и ссылки не заменяются. Новое имя относится к копии в папке назначения. Этот шаг не изменяет файлы.")
                alert.accessoryView = editor.view
                alert.addButton(withTitle: L10n.text("Отмена")); alert.addButton(withTitle: L10n.text("Проверить решения"))
                guard alert.runModal() == .alertSecondButtonReturn, self.available() else { return }
                let decisions = editor.decisions()
                self.operations.run(title: L10n.text("Проверка решений конфликтов"), work: { token, progress in
                    try RemoteDirectoryTransfer.resolve(provider: provider, plan: plan, decisions: decisions, cancellation: token, progress: progress)
                }) { [weak self, weak active, weak passive] resolved in
                    guard let self, let active, let passive,
                          active.locationGeneration == sourceGeneration, passive.locationGeneration == targetGeneration else { return }
                    switch resolved {
                    case .success(let resolvedPlan): self.confirmDirectoryTransfer(provider: provider, plan: resolvedPlan, move: move, captured: captured)
                    case .failure(let error): self.onError(error)
                    }
                }
            }
        }
    }
    private func confirmDirectoryTransfer(provider: any RemoteProvider, plan: RemoteDirectoryTransferPlan, move: Bool, captured: [SearchResult]) {
        guard Self.directoryTransferPreview(plan, move: move).runModal() == .alertSecondButtonReturn, available() else { return }
        operations.run(title: move ? L10n.text("Перенос дерева с проверкой копии") : L10n.text("Копирование дерева"), work: { token, progress in
            try captured.forEach { try $0.verifyCurrent() }
            return try RemoteDirectoryTransfer.copy(provider: provider, plan: plan, move: move, cancellation: token, progress: progress)
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let report):
                self.onStatus(Self.directoryTransferSummary(report))
                if report.moving && !report.retainedSources.isEmpty { Self.directoryTransferResult(report).runModal() }
            case .failure(let error): self.onError(error)
            }
            self.onChanged()
        }
    }
    static func directoryTransferSummary(_ report: RemoteDirectoryTransferReport) -> String {
        let copied = "Скопировано поддеревьев: \(report.completed.count); пропущено конфликтов: \(report.skipped.count)."
        return report.moving ? copied + " Удалено исходников: \(report.removedSources.count); сохранено: \(report.retainedSources.count)." : copied + " Исходники сохранены."
    }
    static func directoryTransferResult(_ report: RemoteDirectoryTransferReport) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = L10n.text("Перенос выполнен частично")
        alert.informativeText = directoryTransferSummary(report)
        let reasons = report.failedSourceRemovals.reduce(into: [String: String]()) { $0[$1.source] = $1.reason }
        previewPaths(report.retainedSources.map { $0 + " — " + (reasons[$0] ?? L10n.text("Пропущен или содержит сохранённые элементы")) }, in: alert)
        alert.addButton(withTitle: L10n.text("Закрыть")); return alert
    }
    static func directoryTransferPreview(_ plan: RemoteDirectoryTransferPlan, move: Bool = false) -> NSAlert {
        let alert = NSAlert(); alert.messageText = move ? L10n.text("Перенести дерево после проверки копии?") : L10n.text("Копировать дерево по плану?")
        alert.informativeText = "Выбрано файлов: \(plan.fileCount), папок: \(plan.directoryCount), байт: \(plan.totalBytes); к передаче байт: \(plan.transferBytes). Поддеревьев к записи: \(plan.copies.count), замен файлов: \(plan.replacementSources.count), пропущено конфликтов: \(plan.skipped.count). " +
            (plan.policy == .mergeSkippingExisting ? "Существующие папки объединяются; решения для файлов перечислены ниже. " : "Все назначения должны быть новыми. ") +
            (move ? "После проверки копий исходные объекты удаляются без Корзины. Пропущенные или изменённые источники сохраняются; пустые папки удаляются последними. " : "Исходники сохраняются. ") +
            "При отмене выполненные изменения сохраняются. Неподтверждённая последняя операция указана в сообщении об ошибке."
        let roots = plan.roots.map { "ИСТОЧНИК: " + $0.source + " → " + $0.destination }
        let copies = plan.copies.map { (plan.replacementSources.contains($0.source) ? "ЗАМЕНИТЬ: " : "КОПИРОВАТЬ: ") + $0.source + " → " + $0.destination }
        let skipped = plan.skipped.map { "ПРОПУСТИТЬ: " + $0.source + " → " + $0.destination }
        previewPaths(roots + copies + skipped, in: alert)
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: move ? L10n.text("Перенести") : L10n.text("Копировать"))
        alert.buttons[1].isEnabled = move ? plan.hasMoveCandidates : !plan.copies.isEmpty
        return alert
    }
    static func runDirectoryTransferUISmokeChecks() throws -> [String] {
        let provider = ProviderUISmokeFixture(), token = TransferCancellation()
        let destination = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("farmac-directory-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("existing".utf8).write(to: destination.appendingPathComponent("docs/alpha.txt"))
        guard let entry = try provider.stat(path: "/docs", cancellation: token) else { throw NetworkError.io("Missing directory preview fixture") }
        let plan = try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: [entry], into: destination, policy: .mergeSkippingExisting)
        let alert = directoryTransferPreview(plan)
        guard plan.copies.count == 1, plan.skipped.count == 1,
              alert.buttons.map(\.title) == ["Отмена", "Копировать"],
              alert.informativeText.contains("пропущено конфликтов: 1"),
              let scroll = alert.accessoryView as? NSScrollView, let text = scroll.documentView as? NSTextView,
              text.string.contains("ПРОПУСТИТЬ: /docs/alpha.txt"), text.string.contains("КОПИРОВАТЬ: /docs/beta.txt"),
              !text.isEditable, provider.downloads == 0 else { throw NetworkError.io("Directory preview must show immutable copies and explicit skipped conflicts before any download") }
        return ["Directory copy preview separates confirmed source mappings, new subtrees and skipped conflicts with Cancel first"]
    }

    static func runDirectoryMoveUISmokeChecks() async throws -> [String] {
        let provider = ProviderUISmokeFixture(), token = TransferCancellation()
        provider.allowsRemoval = true
        let destination = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("farmac-move-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("keep".utf8).write(to: destination.appendingPathComponent("docs/alpha.txt"))
        guard let entry = try provider.stat(path: "/docs", cancellation: token) else { throw NetworkError.io("Missing move fixture") }
        let plan = try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: [entry], into: destination, policy: .mergeSkippingExisting)
        let preview = directoryTransferPreview(plan, move: true)
        guard preview.buttons.map(\.title) == ["Отмена", "Перенести"], preview.informativeText.contains("без Корзины") else { throw NetworkError.io("Move confirmation must disclose deletion") }
        let controller = NetworkOperationController()
        let report: RemoteDirectoryTransferReport = try await withCheckedThrowingContinuation { continuation in
            controller.run(title: "Move UI fixture", work: { token, progress in
                try RemoteDirectoryTransfer.move(provider: provider, plan: plan, cancellation: token, progress: progress)
            }) { continuation.resume(with: $0) }
        }
        guard report.moving, !controller.isWorking,
              try provider.stat(path: "/docs/beta.txt", cancellation: token) == nil,
              try provider.stat(path: "/docs/alpha.txt", cancellation: token) != nil,
              try provider.stat(path: "/docs", cancellation: token) != nil,
              try Data(contentsOf: destination.appendingPathComponent("docs/beta.txt")) == Data("second".utf8),
              try Data(contentsOf: destination.appendingPathComponent("docs/alpha.txt")) == Data("keep".utf8) else { throw NetworkError.io("UI worker failed partial move preservation") }
        let result = directoryTransferResult(report)
        guard let scroll = result.accessoryView as? NSScrollView, let text = scroll.documentView as? NSTextView,
              text.string.contains("/docs/alpha.txt"), !text.isEditable else { throw NetworkError.io("Retained move sources missing from UI report") }
        let coordinator = NetworkCoordinator()
        let cancelled: Result<Void, Error> = await withCheckedContinuation { continuation in
            coordinator.operations.run(title: "Disconnect UI fixture", work: { token, _ in
                DispatchQueue.main.async { coordinator.disconnected(provider) }
                let deadline = Date().addingTimeInterval(2)
                while !token.isCancelled && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                if token.isCancelled { throw NetworkError.cancelled }
            }) { continuation.resume(returning: $0) }
        }
        guard case .failure(NetworkError.cancelled) = cancelled else { throw NetworkError.io("Disconnect must cancel the whole transfer between requests") }
        return ["Network MOVE confirmation discloses deletion; actual progress worker preserves skipped source", "Partial MOVE result lists retained source paths without changing files", "Panel disconnect cancels the logical transfer even between provider requests"]
    }

    func remove(_ panel: PanelView) {
        guard available(), let browser = panel.remotePanel, !browser.selectedEntries.isEmpty else { return }
        let entries = browser.selectedEntries, generation = panel.locationGeneration
        operations.run(title: "Предварительный просмотр удаления", work: { token, progress in
            try RemoteTreeOperations.prepareDelete(provider: browser.provider, entries: entries, cancellation: token, progress: progress)
        }) { [weak self, weak panel] result in
            guard let self, let panel, panel.remotePanel === browser, panel.locationGeneration == generation else { return }
            switch result {
            case .failure(let error): self.onError(error)
            case .success(let plan):
                let alert = Self.deletionPreview(plan)
                guard alert.runModal() == .alertSecondButtonReturn, self.available() else { return }
                self.operations.run(title: "Пообъектное удаление с сервера", work: { token, progress in
                    _ = try RemoteTreeOperations.delete(provider: browser.provider, plan: plan, cancellation: token, progress: progress)
                }) { [weak self] result in self?.finished(result) }
            }
        }
    }
    /// Constructed separately so UI smoke can inspect the actual confirmation
    /// without invoking its destructive button or replacing the operation worker.
    static func deletionPreview(_ plan: RemoteTreePlan) -> NSAlert {
        let alert = NSAlert(); alert.alertStyle = .critical; alert.messageText = "Удалить дерево с сервера без Корзины?"
        alert.informativeText = "Файлов/ссылок: \(plan.fileCount), папок: \(plan.directoryCount). Удаление необратимо. Перед началом снимок проверяется заново. При изменении или отмене работа останавливается; уже удалённое не восстанавливается."
        previewPaths(plan.entries.map(\.path), in: alert)
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Удалить с сервера")
        return alert
    }
    static func movePreview(_ plan: RemoteMovePlan) -> NSAlert {
        let alert = NSAlert(); alert.messageText = "Перенести на том же сервере?"
        alert.informativeText = "Объектов в деревьях: \(plan.tree.entries.count), файлов/ссылок: \(plan.tree.fileCount), папок: \(plan.tree.directoryCount). Используется серверное переименование без замены и слияния. При конфликте или отмене завершённые перемещения сохраняются."
        previewPaths(plan.moves.map { $0.source.path + " → " + $0.destination }, in: alert)
        alert.addButton(withTitle: "Отмена"); alert.addButton(withTitle: "Перенести")
        return alert
    }
    private static func previewPaths(_ paths: [String], in alert: NSAlert) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = paths.prefix(1000).joined(separator: "\n") + (paths.count > 1000 ? "\n… Показаны первые 1000 из \(paths.count) объектов." : "")
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; scroll.documentView = text
        text.setAccessibilityLabel("План сетевой операции"); alert.accessoryView = scroll
    }
    static func runProviderOperationUISmokeChecks() throws -> [String] {
        let provider = ProviderUISmokeFixture(), token = TransferCancellation()
        guard let root = try provider.stat(path: "/docs", cancellation: token) else { throw NetworkError.io("Missing preview fixture") }
        let deletion = try RemoteTreeOperations.prepareDelete(provider: provider, entries: [root])
        let deleteAlert = deletionPreview(deletion)
        guard deletion.fileCount == 2, deletion.directoryCount == 1,
              deleteAlert.buttons.map(\.title) == ["Отмена", "Удалить с сервера"],
              deleteAlert.informativeText.contains("Файлов/ссылок: 2, папок: 1"),
              let deleteScroll = deleteAlert.accessoryView as? NSScrollView,
              let deleteText = deleteScroll.documentView as? NSTextView,
              deleteText.isEditable == false, deleteText.isSelectable,
              deleteText.string.contains("/docs/alpha.txt"), deleteText.string.contains("/docs/beta.txt") else {
            throw NetworkError.io("Delete preview must present counts, paths and cancel-first confirmation")
        }
        let move = try RemoteTreeOperations.prepareMove(provider: provider, entries: [root], to: "/target", intoDirectory: true)
        let moveAlert = movePreview(move)
        guard moveAlert.buttons.map(\.title) == ["Отмена", "Перенести"],
              moveAlert.informativeText.contains("без замены и слияния"),
              let moveScroll = moveAlert.accessoryView as? NSScrollView,
              let moveText = moveScroll.documentView as? NSTextView,
              moveText.string == "/docs → /target/docs", provider.downloads == 0,
              try provider.stat(path: "/docs/alpha.txt", cancellation: token) != nil else {
            throw NetworkError.io("Move preview must identify source and destination without changing or downloading the source")
        }
        return ["Recursive delete preview presents immutable selection counts and paths with Cancel first", "Same-server move preview presents exact mapping without replacement, transfer or mutation"]
    }
    func rename(_ panel: PanelView) {
        guard available(), let browser = panel.remotePanel, let entry = browser.cursor,
              let name = prompt("Новое имя на сервере", value: entry.name) else { return }
        do { prepareRemoteMove(browser, entries: [entry], destination: try RemotePath.child(name, of: RemotePath.parent(entry.path)), intoDirectory: false, panel: panel) }
        catch { onError(error) }
    }
    private func moveRemote(from active: PanelView, to passive: PanelView, cursorOnly: Bool) {
        guard let source = active.remotePanel, let target = passive.remotePanel else { return }
        guard source.provider.connection == target.provider.connection else {
            onError(NetworkError.unsupported("Перенос между сетевыми панелями требует одного и того же сохранённого подключения. Передача между разными серверами пока недоступна.")); return
        }
        let entries = cursorOnly ? source.cursor.map { [$0] } ?? [] : source.selectedEntries
        guard !entries.isEmpty, let destination = prompt("Папка назначения на том же сервере", value: target.currentPath) else { return }
        do { prepareRemoteMove(source, entries: entries, destination: try RemotePath.validate(destination), intoDirectory: true, panel: active) }
        catch { onError(error) }
    }
    private func prepareRemoteMove(_ browser: RemotePanelView, entries: [RemoteEntry], destination: String, intoDirectory: Bool, panel: PanelView) {
        let generation = panel.locationGeneration
        operations.run(title: "Предварительный просмотр переноса", work: { token, progress in
            try RemoteTreeOperations.prepareMove(provider: browser.provider, entries: entries, to: destination, intoDirectory: intoDirectory, cancellation: token, progress: progress)
        }) { [weak self, weak panel] result in
            guard let self, let panel, panel.remotePanel === browser, panel.locationGeneration == generation else { return }
            switch result {
            case .failure(let error): self.onError(error)
            case .success(let plan):
                guard Self.movePreview(plan).runModal() == .alertSecondButtonReturn, self.available() else { return }
                self.operations.run(title: "Серверное перемещение", work: { token, progress in
                    _ = try RemoteTreeOperations.move(provider: browser.provider, plan: plan, cancellation: token, progress: progress)
                }) { [weak self] result in self?.finished(result) }
            }
        }
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
        for editor in editors where editor.window?.isVisible == true || editor.retainedRemoteWorkspace != nil {
            if !editor.confirmClose() { return false }
        }
        for session in edits where session.window?.isVisible == true { if !session.confirmClose() { return false } }
        return true
    }
    func finalizeTermination() {
        sshAuthentication.cancelAll()
        sshConnections.forEach { $0.provider?.closeConnection() }; sshConnections.removeAll()
        pendingDownload?.cleanup(); pendingDownload = nil
        editors.forEach { $0.finalizeClose(); $0.retainedRemoteWorkspace?.cleanup() }
        edits.forEach { $0.finalizeClose(); $0.cleanupForTermination() }
        viewers.forEach { $0.cancelBackgroundWork(); $0.retainedRemoteWorkspace?.cleanup() }
        editors.removeAll(); edits.removeAll(); viewers.removeAll()
    }
}

extension ProviderUISmokeFixture: RemoteBoundedDownloadProvider {
    func boundedDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        try searchDownload(path: path, to: to, maximumBytes: maximumBytes, cancellation: cancellation, progress: progress)
    }
}
