import AppKit
import FarCore

struct SavedPanelRestoreFailure: Sendable {
    let reference: SavedSearchReference
    let message: String
}

struct SavedPanelRestoreOutcome: Sendable {
    /// Same order and count as the requested references. Failures remain offline.
    let matches: [SearchMatch]
    let failures: [SavedPanelRestoreFailure]
    let restoredIDs: Set<String>
    let cancelled: Bool
}

/// App's operation lease prevents concurrent panel operations while this fixed
/// provider set is borrowed by one restoration worker. Concrete network providers
/// also serialize their transports; this does not make arbitrary providers Sendable.
private struct SavedRestoreProviderLease: @unchecked Sendable {
    let providers: [any RemoteProvider]
}

/// Keychain is indexed by UUID, so it may be read only after matching the entire
/// currently saved connection against the original captured metadata.
enum SavedRestoreNetworkCredentials {
    static func password(for connection: NetworkConnection,
                         profiles: () throws -> [NetworkConnection] = { try NetworkProfileStore.load() },
                         credential: (UUID) throws -> String? = { try NetworkCredentials.password(for: $0) },
                         request: (String) throws -> String?) throws -> String? {
        if connection.kind == .sftp, connection.sftpAuthenticationMode != .password { return nil }
        if connection.username.isEmpty && connection.kind != .sftp { return nil }
        let matches = try profiles().contains(connection)
        if matches, let password = try credential(connection.id), !password.isEmpty { return password }
        let user = connection.username.isEmpty ? "" : connection.username + "@"
        let endpoint = "\(connection.kind.rawValue)://\(user)\(connection.host):\(connection.port)"
        let detail = "Исходное подключение сохранённого результата:\n" + endpoint + "\n" +
            (matches ? "Пароль используется только для этого подключения." : "Профиль изменён или удалён. Пароль из Связки ключей не используется. Введите пароль именно исходного сервера.")
        guard let password = try request(detail) else { throw ViewerError.cancelled }
        if connection.kind == .sftp && password.isEmpty { throw NetworkError.invalidConnection("Введите пароль для входа SFTP.") }
        return password
    }
}

/// Uses the same known_hosts store and explicit fingerprint approval as normal
/// connections. Changed keys are never routed through the unknown-key dialog.
enum SavedRestoreNetworkTrust {
    static func recover(_ error: Error, connection: NetworkConnection, cancellation: ProviderSearchCancellation,
                        authenticationHandler: SFTPAuthenticationHandler?,
                        confirm: (SFTPHostKey, String) throws -> Bool) throws -> Bool {
        guard connection.kind == .sftp, !cancellation.isCancelled else { return false }
        let jumpIndex: Int?
        if let jump = error as? SFTPJumpHostError {
            guard jump.error == .unknownHostKey, connection.sftpJumpHosts.indices.contains(jump.index) else { return false }
            jumpIndex = jump.index
        } else {
            guard error as? SFTPError == .unknownHostKey else { return false }
            jumpIndex = nil
        }
        let store = SFTPHostKeyStore()
        var attempts = 0
        let keys: [SFTPHostKey]
        while true {
            do {
                keys = try cancellation.transfer {
                    try store.probe(connection: connection, jumpHostIndex: jumpIndex, cancellation: $0, authenticationHandler: authenticationHandler)
                }
                break
            } catch {
                // A target probe may itself encounter a still unknown preceding
                // gateway. Verify that gateway separately before probing onward.
                guard attempts < connection.sftpJumpHosts.count,
                      let jump = error as? SFTPJumpHostError,
                      jump.index < (jumpIndex ?? connection.sftpJumpHosts.count),
                      try recover(error, connection: connection, cancellation: cancellation,
                                  authenticationHandler: authenticationHandler, confirm: confirm) else { throw error }
                attempts += 1
            }
        }
        guard !cancellation.isCancelled,
              let key = keys.first(where: { $0.keyType == "ssh-ed25519" }) ?? keys.first else { throw ViewerError.cancelled }
        let endpoint: String
        if let index = jumpIndex {
            let jump = connection.sftpJumpHosts[index]
            endpoint = "Промежуточный SSH-сервер" + " \(index + 1): \(jump.username)@\(jump.host):\(jump.port)"
        } else { endpoint = "Целевой SSH-сервер" + ": \(connection.username)@\(connection.host):\(connection.port)" }
        guard try confirm(key, endpoint), !cancellation.isCancelled else { throw ViewerError.cancelled }
        try store.trust(key)
        return true
    }
}

/// A worker can ask the main thread for a dialog without doing I/O on that thread.
/// Polling also lets cancellation release a queued request before its dialog opens.
private final class SavedRestoreReply<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private let ready = DispatchSemaphore(value: 0)
    func finish(_ result: Result<Value, Error>) { lock.lock(); self.result = result; lock.unlock(); ready.signal() }
    func wait(_ token: ProviderSearchCancellation) throws -> Value {
        while ready.wait(timeout: .now() + 0.05) == .timedOut {
            if token.isCancelled { throw ViewerError.cancelled }
        }
        guard !token.isCancelled else { throw ViewerError.cancelled }
        lock.lock(); let result = self.result!; lock.unlock()
        return try result.get()
    }
}

enum SavedRestoreMainPrompt {
    static func perform<Value>(_ token: ProviderSearchCancellation, _ body: @escaping @MainActor () throws -> Value) throws -> Value {
        guard !token.isCancelled else { throw ViewerError.cancelled }
        let reply = SavedRestoreReply<Value>()
        DispatchQueue.main.async {
            guard !token.isCancelled else { reply.finish(.failure(ViewerError.cancelled)); return }
            reply.finish(Result { try body() })
        }
        return try reply.wait(token)
    }
}

@MainActor private final class SavedPanelRestoreProgressWindow: FileToolsWindowController {
    var onCancel: (() -> Void)?
    private let bar = NSProgressIndicator()
    init() {
        super.init(title: L10n.text("Восстановление сохранённых результатов"), width: 640, height: 210)
        bar.style = .bar; bar.isIndeterminate = false
        let cancel = button(L10n.text("Отменить"), #selector(cancelWork)); cancel.keyEquivalent = "\u{1b}"
        content([status, bar, NSTextField(wrappingLabelWithString: L10n.text("Недоступные и отменённые результаты сохраняются в панели. Дождитесь завершения очистки временных файлов.")), NSView(), row([NSView(), cancel])])
        isWorking = true; hasPendingMutation = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ index: Int, total: Int, path: String) {
        status.stringValue = "\(index) / \(total)\n" + path
        bar.maxValue = Double(max(1, total)); bar.doubleValue = Double(index)
    }
    @objc private func cancelWork() { onCancel?(); status.stringValue = L10n.text("Отмена…") }
    override func windowShouldClose(_ sender: NSWindow) -> Bool { cancelWork(); return false }
    func finish() { isWorking = false; hasPendingMutation = false; close() }
}

/// Only an explicit F3/F4/Enter/F5 action starts this controller. Decoding and
/// opening a saved panel never construct a provider, read Keychain or prompt.
@MainActor final class SavedPanelRestoreController {
    typealias ProviderFactory = (NetworkConnection, ProviderSearchCancellation) throws -> any RemoteProvider
    typealias ArchivePasswordRequester = (URL, [String], ProviderSearchCancellation) throws -> String?
    typealias NetworkTrustRecovery = (Error, NetworkConnection, ProviderSearchCancellation) throws -> Bool

    var providerFactory: ProviderFactory = { _, _ in throw NetworkError.unsupported("Восстановление сетевого подключения не настроено.") }
    var archivePasswordRequester: ArchivePasswordRequester?
    var recoverNetworkTrust: NetworkTrustRecovery = { _, _, _ in false }
    var onCancel: () -> Void = {}
    var onProgress: (Int, Int, String) -> Void = { _, _, _ in }
    var showsProgressWindow = true
    private(set) var isWorking = false
    private var token: ProviderSearchCancellation?
    private var progressWindow: SavedPanelRestoreProgressWindow?
    private var promptAlert: NSAlert?

    func cancel() {
        token?.cancel(); onCancel()
        if let alert = promptAlert { NSApp.abortModal(); alert.window.orderOut(nil) }
    }

    nonisolated func requestPassword(title: String, detail: String, cancellation: ProviderSearchCancellation) throws -> String? {
        try SavedRestoreMainPrompt.perform(cancellation) { [weak self] in
            guard let self else { throw ViewerError.cancelled }
            let alert = NSAlert(); alert.messageText = L10n.text(title)
            var localizedDetail = detail
            for text in ["Исходное подключение сохранённого результата:", "Пароль используется только для этого подключения.", "Профиль изменён или удалён. Пароль из Связки ключей не используется. Введите пароль именно исходного сервера."] {
                localizedDetail = localizedDetail.replacingOccurrences(of: text, with: L10n.text(text))
            }
            alert.informativeText = localizedDetail
            let field = NSSecureTextField(string: ""); field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
            alert.accessoryView = field; alert.addButton(withTitle: L10n.text("Продолжить")); alert.addButton(withTitle: L10n.text("Отмена"))
            alert.window.initialFirstResponder = field; self.promptAlert = alert
            defer { field.stringValue = ""; self.promptAlert = nil }
            guard alert.runModal() == .alertFirstButtonReturn else { cancellation.cancel(); return nil }
            return field.stringValue
        }
    }

    nonisolated func confirmHostKey(_ key: SFTPHostKey, endpoint: String, cancellation: ProviderSearchCancellation) throws -> Bool {
        try SavedRestoreMainPrompt.perform(cancellation) { [weak self] in
            guard let self else { throw ViewerError.cancelled }
            let alert = NSAlert(); alert.messageText = L10n.text("Проверьте ключ SSH-сервера")
            let localizedEndpoint = endpoint.replacingOccurrences(of: "Промежуточный SSH-сервер", with: L10n.text("Промежуточный SSH-сервер"))
                .replacingOccurrences(of: "Целевой SSH-сервер", with: L10n.text("Целевой SSH-сервер"))
            alert.informativeText = localizedEndpoint + "\n\(key.host):\(key.port)\n\(key.keyType)\n\(key.fingerprint)\n\n" + L10n.text("Сравните этот отпечаток с полученным от владельца сервера по доверенному каналу. Само получение ключа из сети не подтверждает подлинность сервера.")
            alert.addButton(withTitle: L10n.text("Отмена")); alert.addButton(withTitle: L10n.text("Отпечаток проверен — доверять"))
            self.promptAlert = alert; defer { self.promptAlert = nil }
            let accepted = alert.runModal() == .alertSecondButtonReturn
            if !accepted { cancellation.cancel() }
            return accepted
        }
    }

    func restore(_ references: [SavedSearchReference], availableProviders: [any RemoteProvider] = [],
                 completion: @escaping (SavedPanelRestoreOutcome) -> Void) {
        guard !isWorking else {
            completion(SavedPanelRestoreOutcome(matches: references.map(SearchMatch.saved), failures: references.map {
                SavedPanelRestoreFailure(reference: $0, message: L10n.text("Дождитесь текущего восстановления."))
            }, restoredIDs: [], cancelled: false)); return
        }
        let token = ProviderSearchCancellation(), factory = providerFactory, recover = recoverNetworkTrust
        let passwords: ArchivePasswordRequester = archivePasswordRequester ?? { [weak self] url, chain, token in
            guard let self else { throw ViewerError.cancelled }
            let path = url.path + chain.map { " !/" + $0 }.joined()
            return try self.requestPassword(title: "Пароль архива для восстановления", detail: path, cancellation: token)
        }
        self.token = token; isWorking = true
        if showsProgressWindow {
            let window = SavedPanelRestoreProgressWindow(); progressWindow = window
            window.onCancel = { [weak self] in self?.cancel() }; window.showWindow(nil)
        }
        let providerLease = SavedRestoreProviderLease(providers: availableProviders)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var providers = providerLease.providers
            let resolver = SavedSearchResolver(providerFactory: { connection in
                guard !token.isCancelled else { throw ViewerError.cancelled }
                // UUID alone is insufficient: a profile may now address a different server.
                if let provider = providers.first(where: { $0.connection == connection }) { return provider }
                let provider = try factory(connection, token)
                guard provider.connection == connection else { throw NetworkError.changedSource }
                providers.append(provider)
                return provider
            }, archivePassword: { url, chain in try passwords(url, chain, token) })
            var matches = references.map(SearchMatch.saved), failures: [SavedPanelRestoreFailure] = [], restored: Set<String> = []
            for (index, reference) in references.enumerated() {
                if token.isCancelled { break }
                DispatchQueue.main.async { [weak self] in
                    self?.progressWindow?.update(index + 1, total: references.count, path: reference.displayPath)
                    self?.onProgress(index + 1, references.count, reference.displayPath)
                }
                do {
                    var attempts = 0
                    while true {
                        do {
                            let match = try resolver.resolve(reference, cancellation: token)
                            guard !token.isCancelled else { throw ViewerError.cancelled }
                            matches[index] = match; restored.insert(reference.id); break
                        } catch {
                            guard !token.isCancelled, let connection = reference.capturedConnection,
                                  attempts < connection.sftpJumpHosts.count + 1,
                                  try recover(error, connection, token) else { throw error }
                            attempts += 1
                        }
                    }
                } catch {
                    if token.isCancelled || error as? ViewerError == .cancelled || error as? NetworkError == .cancelled {
                        token.cancel(); break
                    }
                    failures.append(SavedPanelRestoreFailure(reference: reference, message: error.localizedDescription))
                }
            }
            resolver.cleanup()
            // Release unsuccessful newly created transports before surrendering
            // the work lease; successful matches retain their own providers.
            providers.removeAll()
            let outcome = SavedPanelRestoreOutcome(matches: matches, failures: failures, restoredIDs: restored, cancelled: token.isCancelled)
            DispatchQueue.main.async { [self] in
                // Keep the app's work lease until resolver cleanup and I/O have finished.
                progressWindow?.finish(); progressWindow = nil; self.token = nil; isWorking = false
                completion(outcome)
            }
        }
    }
}

/// Real AppKit host checks use controlled providers and prompts. No credential
/// store, network, host-key dialog or user's saved panel library is touched.
extension SavedPanelRestoreController {
    static func runUISmokeChecks() async throws -> [String] {
        guard AppRuntime.isSmoke, let root = AppRuntime.smokeStateDirectory else { throw PanelSessionError("Saved restore smoke requires isolated state") }
        let folder = root.appendingPathComponent("saved-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appendingPathComponent("alpha.txt"), stale = folder.appendingPathComponent("stale.txt")
        try Data("local source".utf8).write(to: local); try Data("before".utf8).write(to: stale)
        let source = ProviderUISmokeFixture()
        func captureReferences() throws -> [SavedSearchReference] {
            let inner = try ArchiveWriter.create(sources: [local], destination: folder.appendingPathComponent("inner.zip"), format: .zip)
            let outer = try ArchiveWriter.create(sources: [inner.sourceURL], destination: folder.appendingPathComponent("outer.zip"), format: .zip)
            let nested = try ArchiveNavigationFrame(snapshot: outer).openNested(path: "inner.zip")
            var options = SearchOptions(roots: [folder]); options.namePattern = "*.txt"
            let request = SearchRequest(options: options)
            var matches: [SearchMatch] = [.local(try SearchResult.capture(local)), .local(try SearchResult.capture(stale))]
            _ = ProviderSearchEngine.runArchive(nested.snapshot, request: request, cancellation: ProviderSearchCancellation()) {
                if case .result(let value) = $0 { matches.append(.archive(value)) }
            }
            _ = ProviderSearchEngine.runRemote(provider: source, root: "/docs", request: request, cancellation: ProviderSearchCancellation()) {
                if case .result(let value) = $0 { matches.append(.remote(value, source)) }
            }
            return try matches.map { try SavedSearchReference(capturing: $0) }
        }
        let references = try JSONDecoder().decode([SavedSearchReference].self, from: JSONEncoder().encode(captureReferences()))
        guard references.count == 5 else { throw PanelSessionError("Missing saved mixed restore fixtures") }
        try Data("changed source with different stamp".utf8).write(to: stale)
        let calls = SavedRestoreSmokeCounter(), passwords = SavedRestoreSmokeCounter()
        let controller = SavedPanelRestoreController(); controller.showsProgressWindow = false
        var edited = source.connection; edited.host = "edited-profile.invalid"
        let wrongProvider = SavedRestoreSmokeProvider(connection: edited)
        controller.providerFactory = { connection, _ in
            guard !Thread.isMainThread, connection == source.connection else { throw PanelSessionError("Restore rebound original connection or performed I/O on main") }
            calls.increment(); return source
        }
        controller.archivePasswordRequester = { _, _, _ in passwords.increment(); throw PanelSessionError("Unencrypted restore requested an archive password") }
        let offline = references.map(SearchMatch.saved)
        guard calls.value == 0, passwords.value == 0, offline.count == references.count,
              !controller.isWorking else { throw PanelSessionError("Offline decode/open started restoration") }
        var acquiredLease = false
        let outcome: SavedPanelRestoreOutcome = await withCheckedContinuation { continuation in
            controller.restore(references, availableProviders: [wrongProvider]) { continuation.resume(returning: $0) }
            acquiredLease = controller.isWorking
        }
        guard acquiredLease, !controller.isWorking, !outcome.cancelled,
              outcome.matches.count == 5, outcome.restoredIDs.count == 4, outcome.failures.count == 1,
              calls.value == 1, passwords.value == 0,
              case .saved(let failed) = outcome.matches[1], failed == references[1] else {
            throw PanelSessionError("Mixed restoration lost failed references, leaked its lease or failed exact provider reuse")
        }
        guard case .archive(let restoredArchive) = outcome.matches[2],
              let snapshot = restoredArchive.capturedArchiveSnapshot,
              FileManager.default.fileExists(atPath: snapshot.sourceURL.path),
              restoredArchive.archiveDisplayPath?.contains("outer.zip !/inner.zip") == true else {
            throw PanelSessionError("Restored nested snapshot lost its workspace during resolver cleanup")
        }
        try outcome.matches[2].verifyCurrent()

        var passwordConnection = source.connection; passwordConnection.sftpAuthenticationMode = .password
        var changedProfile = passwordConnection; changedProfile.host = "changed-server.invalid"
        var credentialReads = 0, requests = 0
        let manual = try SavedRestoreNetworkCredentials.password(for: passwordConnection, profiles: { [changedProfile] }, credential: { _ in
            credentialReads += 1; return "wrong-host-secret"
        }, request: { detail in
            requests += 1
            guard detail.contains(passwordConnection.host), !detail.contains(changedProfile.host) else { throw PanelSessionError("Manual password prompt hid original endpoint") }
            return "manual-fixture"
        })
        guard manual == "manual-fixture", credentialReads == 0, requests == 1 else { throw PanelSessionError("Changed profile reused another server's Keychain password") }
        let stored = try SavedRestoreNetworkCredentials.password(for: passwordConnection, profiles: { [passwordConnection] }, credential: { _ in
            credentialReads += 1; return "matching-fixture"
        }, request: { _ in throw PanelSessionError("Matching credential unexpectedly prompted") })
        guard stored == "matching-fixture", credentialReads == 1 else { throw PanelSessionError("Matching profile did not reuse its credential") }
        var trustPrompts = 0
        let recoveredChangedKey = try SavedRestoreNetworkTrust.recover(SFTPError.changedHostKey, connection: passwordConnection,
            cancellation: ProviderSearchCancellation(), authenticationHandler: nil, confirm: { _, _ in trustPrompts += 1; return true })
        guard !recoveredChangedKey, trustPrompts == 0 else { throw PanelSessionError("Changed host key entered first-use trust flow") }

        guard let remoteReference = references.first(where: { $0.capturedConnection != nil }) else { throw PanelSessionError("Missing saved remote reference") }
        let cancelling = SavedPanelRestoreController(); cancelling.showsProgressWindow = false
        let blocked = SavedRestoreSmokeProvider(connection: source.connection); blocked.waitForCancellation = true
        blocked.onStat = { DispatchQueue.main.async { cancelling.cancel() } }
        cancelling.providerFactory = { _, _ in blocked }
        let cancelled: SavedPanelRestoreOutcome = await withCheckedContinuation { continuation in
            cancelling.restore([remoteReference, references[0]]) { continuation.resume(returning: $0) }
        }
        guard cancelled.cancelled, !cancelling.isWorking, cancelled.restoredIDs.isEmpty,
              cancelled.matches.count == 2, cancelled.matches.allSatisfy({ if case .saved = $0 { return true }; return false }) else {
            throw PanelSessionError("Cancellation discarded offline references or released restoration before cleanup")
        }
        return ["Saved mixed restoration is explicit, asynchronous and retains stale offline results", "Saved restoration reuses exact providers and keeps nested archive workspaces alive", "Edited profile metadata cannot read the original UUID's Keychain credential; changed SSH keys refuse trust recovery", "Cancelled restoration interrupts provider I/O and retains every unresolved offline reference"]
    }
}

private final class SavedRestoreSmokeCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class SavedRestoreSmokeProvider: RemoteProvider {
    let connection: NetworkConnection
    private let source = ProviderUISmokeFixture()
    var waitForCancellation = false
    var onStat: (() -> Void)?
    init(connection: NetworkConnection) { self.connection = connection }
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        if waitForCancellation {
            onStat?()
            while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            throw NetworkError.cancelled
        }
        return try source.stat(path: path, cancellation: cancellation)
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] { try source.list(path: path, cancellation: cancellation) }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        try source.download(path: path, to: to, resumeOffset: resumeOffset, cancellation: cancellation, progress: progress)
    }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("Fixture upload") }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("Fixture rename") }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("Fixture remove") }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("Fixture mkdir") }
}
