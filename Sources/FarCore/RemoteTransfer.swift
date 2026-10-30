import Foundation
import CryptoKit
import Darwin

public enum RemoteTransferLimits {
    public static let maximumDepth = 128
    public static let maximumEntries = 100_000
    public static let maximumBytes: Int64 = 1_099_511_627_776 // 1 TiB per selected tree
}

public enum RemoteTransferError: Error, LocalizedError, Equatable {
    case cancelled, conflict(String), invalidPath, unsupported(String), verification(String), local(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Сетевая операция отменена."
        case .conflict(let path): return "Объект изменился или уже существует: «\(path)». Обновите панель и повторите действие."
        case .invalidPath: return "Недопустимый сетевой путь или имя."
        case .unsupported(let message), .verification(let message), .local(let message): return message
        }
    }
}

/// A provider which conditions every received byte on a strong server ETag.
/// Implementations must validate status, range and representation before writing.
public protocol RemoteConditionalDownloadProvider: RemoteProvider {
    func conditionalDownload(path: String, to: URL, resumeOffset: Int64, expectedVersion: String,
                             cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws
}

/// One in-app file download. A failed run retains only this task's private partial.
/// Never construct this task from an arbitrary partial file. Retry is explicit;
/// strong-ETag WebDAV can resume, all other providers restart from byte zero.
public final class RemoteDownloadTask: @unchecked Sendable {
    public let path: String
    public let destination: URL
    private let provider: RemoteProvider
    private let connection: NetworkConnection
    private let replace: Bool
    private let expectedDestination: LocalRemoteStamp?
    private let workspace: RemoteWorkspace
    let partialURL: URL
    private let partialIdentity: LocalRemoteStamp
    private let runLock = NSLock()
    private let stateLock = NSLock()
    private var snapshot: RemoteEntry?
    private var proof: ResumeProof?
    private var disposed = false
    private var completed = false
    private var blocked = false
    private var activeCancellation: TransferCancellation?
    private var reportedBytes: Int64 = 0
    private var resumable = false

    public init(provider: RemoteProvider, path: String, destination: URL, replace: Bool = false) throws {
        _ = try RemotePath.validate(path)
        guard path != "/" else { throw RemoteTransferError.invalidPath }
        let target = try LocalRemoteStamp.optional(destination)
        guard target?.directory != true, target?.link != true else {
            throw RemoteTransferError.unsupported("Для сетевого файла укажите имя обычного локального файла.")
        }
        if target != nil && !replace { throw RemoteTransferError.conflict(destination.path) }
        self.provider = provider; self.path = path; self.destination = destination
        self.connection = provider.connection; self.replace = replace; expectedDestination = target
        workspace = try RemoteWorkspace()
        partialURL = workspace.nextURL(URL(fileURLWithPath: path).lastPathComponent)
        let fd = open(partialURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
        partialIdentity = try LocalRemoteStamp(partialURL)
    }
    /// A candidate resume is checked again on the worker before sending Range.
    public var canResume: Bool { stateLock.lock(); defer { stateLock.unlock() }; return resumable && !disposed && !completed && !blocked }
    public var partialBytes: Int64 { stateLock.lock(); defer { stateLock.unlock() }; return reportedBytes }

    public func run(cancellation: TransferCancellation = TransferCancellation(),
                    progress: @escaping (NetworkProgress) -> Void = { _ in }) throws {
        guard runLock.try() else { throw RemoteTransferError.unsupported("Эта загрузка уже выполняется.") }
        defer { runLock.unlock() }
        stateLock.lock()
        let unavailable = disposed || completed || blocked
        activeCancellation = cancellation
        stateLock.unlock()
        defer { stateLock.lock(); activeCancellation = nil; stateLock.unlock() }
        guard !unavailable else { throw RemoteTransferError.unsupported("Загрузка завершена или её доказательство устарело; создайте новую операцию.") }
        try RemoteTransferEngine.check(cancellation)
        guard provider.connection == connection else { invalidate(); throw RemoteTransferError.conflict(path) }
        guard try LocalRemoteStamp.optional(destination) == expectedDestination else {
            throw RemoteTransferError.conflict(destination.path)
        }
        let current = try RemoteTransferEngine.required(provider, path, cancellation)
        try RemoteTransferEngine.regular(current)
        guard current.size <= RemoteTransferLimits.maximumBytes else { throw RemoteTransferError.unsupported("Файл превышает предел сетевой операции (1 ТиБ).") }
        if let snapshot, snapshot != current { invalidate(); throw RemoteTransferError.conflict(path) }
        snapshot = current
        let conditional = provider as? RemoteConditionalDownloadProvider
        let version = Self.strongVersion(current.version)
        let guarded = conditional != nil && version != nil && [.webdav, .webdavs].contains(connection.kind)
        var offset: Int64 = 0
        if let proof {
            guard let actual = try? LocalRemoteStamp(partialURL), actual == proof.stamp, actual.sameObject(partialIdentity) else {
                invalidate(); throw RemoteTransferError.verification("Приватная частичная копия изменилась; возобновление запрещено. Начните новую загрузку.")
            }
            let hash = try RemoteDigest.hash(partialURL, cancellation: cancellation)
            guard hash == proof.hash else {
                invalidate(); throw RemoteTransferError.verification("Байты частичной копии изменились; возобновление запрещено. Начните новую загрузку.")
            }
            if guarded { offset = proof.stamp.size }
        }
        var attemptedRead = false
        do {
            let owned = try LocalRemoteStamp(partialURL)
            guard owned.sameObject(partialIdentity), !owned.directory, !owned.link else {
                invalidate(); throw RemoteTransferError.verification("Приватный файл загрузки заменён; начните новую операцию.")
            }
            if offset < current.size || current.size == 0 {
                attemptedRead = true
                if guarded, let conditional, let version {
                    try conditional.conditionalDownload(path: path, to: partialURL, resumeOffset: offset,
                                                        expectedVersion: version, cancellation: cancellation, progress: progress)
                } else {
                    try provider.download(path: path, to: partialURL, resumeOffset: 0, cancellation: cancellation, progress: progress)
                }
            }
            let ready = try LocalRemoteStamp(partialURL)
            guard ready.sameObject(partialIdentity), !ready.link, ready.size == current.size,
                  try RemoteTransferEngine.required(provider, path, cancellation) == current else {
                invalidate(); throw RemoteTransferError.verification("Файл изменился или получен не полностью; начните новую загрузку.")
            }
            try publish(cancellation)
            stateLock.lock(); completed = true; resumable = false; reportedBytes = ready.size; stateLock.unlock()
            workspace.cleanup()
        } catch {
            if let networkError = error as? NetworkError, networkError == .changedSource { invalidate() }
            if attemptedRead, guarded, let actual = try? LocalRemoteStamp(partialURL),
               actual.sameObject(partialIdentity), !actual.directory, !actual.link,
               actual.size > 0, actual.size <= current.size, let hash = try? RemoteDigest.hash(partialURL, cancellation: cancellation) {
                proof = ResumeProof(stamp: actual, hash: hash)
                stateLock.lock(); reportedBytes = actual.size; resumable = actual.size < current.size && !blocked; stateLock.unlock()
            } else {
                proof = nil
                stateLock.lock(); reportedBytes = 0; resumable = false; stateLock.unlock()
            }
            throw error
        }
    }

    /// Cancels any active run, waits for it to stop, then removes the owned workspace.
    public func cleanup() {
        stateLock.lock(); disposed = true; resumable = false; let active = activeCancellation; stateLock.unlock()
        active?.cancel()
        runLock.lock(); defer { runLock.unlock() }
        workspace.cleanup()
    }
    deinit { workspace.cleanup() }
    private func invalidate() { stateLock.lock(); blocked = true; resumable = false; stateLock.unlock() }
    private func publish(_ cancellation: TransferCancellation) throws {
        try RemoteTransferEngine.check(cancellation)
        guard try LocalRemoteStamp.optional(destination) == expectedDestination else { throw RemoteTransferError.conflict(destination.path) }
        let result = TransferEngine.run(TransferRequest(sources: [partialURL], destination: destination, move: false),
            cancellation: cancellation, onProgress: { _ in }, onConflict: { conflict in
                guard self.replace, !conflict.isDirectoryMerge,
                      (try? LocalRemoteStamp.optional(conflict.destination)) == self.expectedDestination else { return .cancel }
                return .replace
            }, onError: { _ in .skip })
        guard !result.cancelled else { throw RemoteTransferError.cancelled }
        guard result.failed == 0 && result.skipped == 0 else { throw RemoteTransferError.local(result.issues.joined(separator: "\n")) }
    }
    private static func strongVersion(_ version: String?) -> String? {
        guard let version, version.count >= 2, version.hasPrefix("\""), version.hasSuffix("\""),
              !version.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !version.dropFirst().dropLast().contains("\"") else { return nil }
        return version
    }
    private struct ResumeProof { let stamp: LocalRemoteStamp; let hash: String }
}

/// An edit lease keeps its private workspace alive. A successful commit returns a new
/// lease; callers must adopt it as the base of their next save.
public struct RemoteEditSnapshot: @unchecked Sendable {
    public let localURL: URL
    public let entry: RemoteEntry
    public let contentHash: String
    public let connectionID: UUID
    fileprivate let workspace: RemoteWorkspace
    fileprivate let connection: NetworkConnection
}

/// Private, operation-owned files. Never downloads over a user document in place.
/// Keep this object (or an edit snapshot) alive while a viewer/editor uses localURL.
public final class RemoteWorkspace: @unchecked Sendable {
    public let directory: URL
    private let cleanupLock = NSLock()
    private var cleaned = false
    public init(parent: URL = FileManager.default.temporaryDirectory) throws {
        guard parent.isFileURL else { throw RemoteTransferError.invalidPath }
        directory = parent.appendingPathComponent("farmac-network-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }
    deinit { cleanup() }
    /// Call after cancelling/joining workers at normal application termination.
    public func cleanup() {
        cleanupLock.lock(); defer { cleanupLock.unlock() }
        guard !cleaned else { return }
        cleaned = true
        Self.removeOwned(directory)
    }
    private static func removeOwned(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            _ = chmod(url.path, 0o700)
            for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                removeOwned(child)
            }
            _ = rmdir(url.path)
        } else { _ = unlink(url.path) }
    }
    fileprivate func nextURL(_ name: String = "data") -> URL {
        // Remote names may already occupy all 255 bytes permitted by a local
        // component. Keep only a bounded extension for viewer/editor detection.
        var suffix = (name as NSString).pathExtension
        while suffix.utf8.count > 32 { suffix.removeLast() }
        return directory.appendingPathComponent(UUID().uuidString + (suffix.isEmpty ? "" : "." + suffix))
    }
    public func open(provider: RemoteProvider, path: String,
                     cancellation: TransferCancellation = TransferCancellation(),
                     progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteEditSnapshot {
        let entry = try RemoteTransferEngine.required(provider, path, cancellation)
        try RemoteTransferEngine.regular(entry)
        let local = nextURL(URL(fileURLWithPath: path).lastPathComponent)
        try RemoteTransferEngine.fetch(provider, entry, local, cancellation, progress)
        return RemoteEditSnapshot(localURL: local, entry: entry, contentHash: try RemoteDigest.hash(local),
                                  connectionID: provider.connection.id, workspace: self, connection: provider.connection)
    }
    @discardableResult
    public func commit(_ snapshot: RemoteEditSnapshot, provider: RemoteProvider,
                       cancellation: TransferCancellation = TransferCancellation(),
                       progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteEditSnapshot {
        guard snapshot.workspace === self, snapshot.connection == provider.connection else {
            throw RemoteTransferError.invalidPath
        }
        let capturedHash = try RemoteDigest.hash(snapshot.localURL)
        let frozen = nextURL("edit-upload")
        defer { try? FileManager.default.removeItem(at: frozen) }
        try FileManager.default.copyItem(at: snapshot.localURL, to: frozen)
        guard try RemoteDigest.hash(frozen) == capturedHash, try RemoteDigest.hash(snapshot.localURL) == capturedHash else {
            throw RemoteTransferError.conflict(snapshot.localURL.path)
        }
        try RemoteTransferEngine.publish(provider, frozen, snapshot.entry.path,
                                         expected: snapshot.entry, expectedHash: snapshot.contentHash,
                                         workspace: self, cancellation: cancellation, progress: progress)
        let entry = try RemoteTransferEngine.required(provider, snapshot.entry.path, cancellation)
        let hash = try RemoteDigest.hash(snapshot.localURL)
        guard hash == capturedHash, try RemoteTransferEngine.remoteHash(provider, entry, self, cancellation) == hash else {
            throw RemoteTransferError.verification("Опубликованный файл изменился; локальные правки сохранены.")
        }
        return RemoteEditSnapshot(localURL: snapshot.localURL, entry: entry, contentHash: hash,
                                  connectionID: provider.connection.id, workspace: self, connection: provider.connection)
    }
}

/// Synchronous workers: invoke on the application's transfer queue, never the UI thread.
/// Publication uses a sibling remote stage and checked rename. FTP/SFTP have no compare-
/// and-swap primitive: independent writers can race the final check. No delete-before-
/// rename fallback is permitted. Cancellation retains originals and completed copies.
public enum RemoteTransferEngine {
    public static func download(provider: RemoteProvider, path: String, to destination: URL,
                                replace: Bool = false, move: Bool = false,
                                cancellation: TransferCancellation = TransferCancellation(),
                                progress: @escaping (NetworkProgress) -> Void = { _ in }) throws {
        try check(cancellation); try validPath(path)
        let original = try LocalRemoteStamp.optional(destination)
        let entry = try required(provider, path, cancellation)
        if original?.directory == true { throw RemoteTransferError.unsupported("Укажите новое имя назначения; загрузка поверх локальной папки недоступна.") }
        if original?.link == true { throw RemoteTransferError.unsupported("Символическую ссылку назначения нельзя заменять сетевой копией.") }
        if move && entry.isDirectory { throw RemoteTransferError.unsupported("Перемещение сетевых папок пока недоступно; используйте копирование и явное удаление.") }
        let workspace = try RemoteWorkspace()
        let local = workspace.nextURL("download")
        var budget = RemoteTreeBudget()
        try fetchTree(provider, entry, local, workspace, cancellation, progress, depth: 0, budget: &budget)
        guard try LocalRemoteStamp.optional(destination) == original else { throw RemoteTransferError.conflict(destination.path) }
        if original != nil && !replace { throw RemoteTransferError.conflict(destination.path) }
        let result = TransferEngine.run(TransferRequest(sources: [local], destination: destination, move: false),
            cancellation: cancellation, onProgress: { _ in }, onConflict: { conflict in
                guard replace, (try? LocalRemoteStamp.optional(conflict.destination)) == original else { return .cancel }
                return conflict.isDirectoryMerge ? .cancel : .replace
            }, onError: { _ in .skip })
        guard !result.cancelled else { throw RemoteTransferError.cancelled }
        guard result.failed == 0 && result.skipped == 0 else {
            throw RemoteTransferError.local(result.issues.joined(separator: "\n"))
        }
        if move {
            do {
            // Do not remove the remote original until both copies have been read back.
            try regular(entry)
            let receipt = try LocalRemoteStamp(destination)
            let hash = try RemoteDigest.hash(destination)
            guard hash == (try RemoteDigest.hash(local)), try required(provider, path, cancellation) == entry,
                  try remoteHash(provider, entry, workspace, cancellation) == hash,
                  try LocalRemoteStamp(destination) == receipt else { throw RemoteTransferError.conflict(path) }
            try check(cancellation)
            try provider.remove(path: path, isDirectory: false, cancellation: cancellation)
            } catch {
                throw RemoteTransferError.local("Копия сохранена в «\(destination.path)». Удаление исходника «\(path)» не завершено: \(error.localizedDescription)")
            }
        }
    }

    public static func upload(provider: RemoteProvider, from source: URL, to path: String,
                              replace: Bool = false, move: Bool = false,
                              cancellation: TransferCancellation = TransferCancellation(),
                              progress: @escaping (NetworkProgress) -> Void = { _ in }) throws {
        try check(cancellation); try validPath(path)
        let original = try LocalRemoteStamp(source)
        if move && original.directory { throw RemoteTransferError.unsupported("Перемещение папок на сервер пока недоступно; используйте копирование и явное удаление.") }
        var budget = RemoteTreeBudget()
        try scanLocal(source, cancellation, depth: 0, budget: &budget)
        let workspace = try RemoteWorkspace()
        let expected = try provider.stat(path: path, cancellation: cancellation)
        if expected != nil && !replace { throw RemoteTransferError.conflict(path) }
        if original.directory && expected != nil { throw RemoteTransferError.unsupported("Загрузка папки требует нового имени назначения; замена и слияние сетевых папок недоступны.") }
        let expectedHash = try expected.map { entry -> String in
            try regular(entry); return try remoteHash(provider, entry, workspace, cancellation)
        }
        let local = workspace.nextURL("upload")
        let result = TransferEngine.run(TransferRequest(sources: [source], destination: local, move: false),
            cancellation: cancellation, onProgress: { _ in }, onConflict: { _ in .cancel }, onError: { _ in .skip })
        guard !result.cancelled else { throw RemoteTransferError.cancelled }
        guard result.failed == 0 else { throw RemoteTransferError.local(result.issues.joined(separator: "\n")) }
        var snapshotBudget = RemoteTreeBudget()
        try scanLocal(local, cancellation, depth: 0, budget: &snapshotBudget)
        try publish(provider, local, path, expected: expected, expectedHash: expectedHash,
                    workspace: workspace, cancellation: cancellation, progress: progress)
        if move {
            do {
            let entry = try required(provider, path, cancellation)
            guard try LocalRemoteStamp(source) == original,
                  try RemoteDigest.hash(source) == RemoteDigest.hash(local),
                  try remoteHash(provider, entry, workspace, cancellation) == RemoteDigest.hash(local) else {
                throw RemoteTransferError.conflict(source.path)
            }
            try check(cancellation)
            guard try LocalRemoteStamp(source) == original else { throw RemoteTransferError.conflict(source.path) }
            guard unlink(source.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } catch {
                throw RemoteTransferError.local("Копия сохранена на сервере в «\(path)». Удаление исходника «\(source.path)» не завершено: \(error.localizedDescription)")
            }
        }
    }

    /// Explicit deletion only, with a fresh selection snapshot. Directories must be empty;
    /// recursive server-side deletion is deliberately never used by this worker.
    public static func delete(provider: RemoteProvider, entry: RemoteEntry,
                              cancellation: TransferCancellation = TransferCancellation()) throws {
        try validPath(entry.path); try check(cancellation)
        guard entry.path != "/" else { throw RemoteTransferError.invalidPath }
        guard try required(provider, entry.path, cancellation) == entry else { throw RemoteTransferError.conflict(entry.path) }
        if entry.isDirectory && !entry.isSymbolicLink {
            guard try provider.list(path: entry.path, cancellation: cancellation).isEmpty else {
                throw RemoteTransferError.unsupported("Папка не пуста. Удалите выбранное содержимое отдельно.")
            }
        }
        try check(cancellation)
        try provider.remove(path: entry.path, isDirectory: entry.isDirectory && !entry.isSymbolicLink, cancellation: cancellation)
    }

    fileprivate static func publish(_ provider: RemoteProvider, _ local: URL, _ path: String,
                                    expected: RemoteEntry?, expectedHash: String?, workspace: RemoteWorkspace,
                                    cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        try validPath(path); try check(cancellation)
        guard path != "/" else { throw RemoteTransferError.invalidPath }
        if let web = provider as? WebRemoteProvider, let expected, let expectedHash,
           let version = expected.version, version.hasPrefix("\""), version.hasSuffix("\""),
           !(try LocalRemoteStamp(local)).directory {
            guard try provider.stat(path: path, cancellation: cancellation) == expected,
                  try remoteHash(provider, expected, workspace, cancellation) == expectedHash else {
                throw RemoteTransferError.conflict(path)
            }
            // HTTP If-Match closes the final check/publish race for a strong ETag.
            try check(cancellation)
            try web.conditionalUpload(from: local, to: path, expectedVersion: version,
                                      cancellation: cancellation, progress: progress)
            try verifyTree(provider, local, path, workspace, cancellation, depth: 0)
            return
        }
        let stage = parent(path) + ".farmac-upload-" + UUID().uuidString
        guard try provider.stat(path: stage, cancellation: cancellation) == nil else { throw RemoteTransferError.conflict(stage) }
        do {
        // A failed remote operation may leave a recoverable sibling stage. Do not blindly
        // delete it: FTP has no exclusive creation or ownership token for cleanup.
        try stageTree(provider, local, stage, workspace, cancellation, progress, depth: 0)
        try verifyTree(provider, local, stage, workspace, cancellation, depth: 0)
        guard try provider.stat(path: path, cancellation: cancellation) == expected else { throw RemoteTransferError.conflict(path) }
        if let expected, let expectedHash {
            guard try remoteHash(provider, expected, workspace, cancellation) == expectedHash,
                  try provider.stat(path: path, cancellation: cancellation) == expected else { throw RemoteTransferError.conflict(path) }
        }
        try check(cancellation)
        try provider.rename(from: stage, to: path, replace: expected != nil, cancellation: cancellation)
        try verifyTree(provider, local, path, workspace, cancellation, depth: 0)
        } catch {
            throw RemoteTransferError.local("Ошибка операции «\(path)». Назначение могло уже обновиться, а подготовленная версия могла сохраниться в «\(stage)»; обновите панель перед повтором. \(error.localizedDescription)")
        }
    }

    fileprivate static func fetch(_ provider: RemoteProvider, _ entry: RemoteEntry, _ local: URL,
                                  _ cancellation: TransferCancellation, _ progress: @escaping (NetworkProgress) -> Void) throws {
        try regular(entry); try check(cancellation)
        // An arbitrary .part is not a resume proof. Always restart in a fresh private
        // file rather than append a suffix to unverified bytes or weak FTP metadata.
        try provider.download(path: entry.path, to: local, resumeOffset: 0, cancellation: cancellation, progress: progress)
        let stamp = try LocalRemoteStamp(local)
        guard !stamp.directory && !stamp.link, stamp.size == entry.size,
              try required(provider, entry.path, cancellation) == entry else {
            throw RemoteTransferError.verification("Сетевой файл изменился или получен не полностью: «\(entry.path)».")
        }
        _ = chmod(local.path, 0o600)
    }
    private static func fetchTree(_ provider: RemoteProvider, _ entry: RemoteEntry, _ local: URL,
                                  _ workspace: RemoteWorkspace, _ cancellation: TransferCancellation,
                                  _ progress: @escaping (NetworkProgress) -> Void, depth: Int, budget: inout RemoteTreeBudget) throws {
        try limit(depth); try check(cancellation)
        try budget.admit(size: entry.isDirectory ? 0 : entry.size)
        guard !entry.isSymbolicLink else { throw RemoteTransferError.unsupported("Сетевые символические ссылки не копируются: «\(entry.path)».") }
        if !entry.isDirectory { try fetch(provider, entry, local, cancellation, progress); return }
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let children = try children(provider, entry.path, cancellation)
        for child in children {
            try fetchTree(provider, child, local.appendingPathComponent(name(child.path)), workspace, cancellation, progress, depth: depth + 1, budget: &budget)
        }
        guard try required(provider, entry.path, cancellation) == entry,
              try self.children(provider, entry.path, cancellation) == children else { throw RemoteTransferError.conflict(entry.path) }
    }
    private static func stageTree(_ provider: RemoteProvider, _ local: URL, _ path: String,
                                  _ workspace: RemoteWorkspace, _ cancellation: TransferCancellation,
                                  _ progress: @escaping (NetworkProgress) -> Void, depth: Int) throws {
        try limit(depth); try check(cancellation)
        let stamp = try LocalRemoteStamp(local)
        guard !stamp.link else { throw RemoteTransferError.unsupported("Загрузка символических ссылок не поддерживается.") }
        if stamp.directory {
            try provider.makeDirectory(path: path, cancellation: cancellation)
            for child in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
                try stageTree(provider, child, path + "/" + child.lastPathComponent, workspace, cancellation, progress, depth: depth + 1)
            }
        } else {
            try provider.upload(from: local, to: path, cancellation: cancellation, progress: progress)
        }
        guard try LocalRemoteStamp(local) == stamp else { throw RemoteTransferError.conflict(local.path) }
    }
    private static func verifyTree(_ provider: RemoteProvider, _ local: URL, _ path: String,
                                   _ workspace: RemoteWorkspace, _ cancellation: TransferCancellation, depth: Int) throws {
        try limit(depth); try check(cancellation)
        let stamp = try LocalRemoteStamp(local)
        let remote = try required(provider, path, cancellation)
        guard !remote.isSymbolicLink, stamp.directory == remote.isDirectory else { throw RemoteTransferError.verification("Тип сетевой копии не совпадает: «\(path)».") }
        if stamp.directory {
            let localChildren = try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
            let remoteChildren = try children(provider, path, cancellation)
            guard Set(localChildren.map(\.lastPathComponent)) == Set(remoteChildren.map { name($0.path) }) else {
                throw RemoteTransferError.verification("Содержимое сетевой папки не совпадает: «\(path)».")
            }
            for child in localChildren { try verifyTree(provider, child, path + "/" + child.lastPathComponent, workspace, cancellation, depth: depth + 1) }
        } else {
            guard stamp.size == remote.size,
                  try remoteHash(provider, remote, workspace, cancellation) == RemoteDigest.hash(local) else {
                throw RemoteTransferError.verification("Проверка байтов сетевой копии не пройдена: «\(path)».")
            }
        }
    }
    private static func scanLocal(_ url: URL, _ cancellation: TransferCancellation,
                                  depth: Int, budget: inout RemoteTreeBudget) throws {
        try check(cancellation); try limit(depth)
        let stamp = try LocalRemoteStamp(url)
        guard !stamp.link else { throw RemoteTransferError.unsupported("Загрузка символических ссылок не поддерживается.") }
        try budget.admit(size: stamp.directory ? 0 : stamp.size)
        if stamp.directory {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try scanLocal(child, cancellation, depth: depth + 1, budget: &budget)
            }
        }
        guard try LocalRemoteStamp(url) == stamp else { throw RemoteTransferError.conflict(url.path) }
    }
    fileprivate static func remoteHash(_ provider: RemoteProvider, _ entry: RemoteEntry,
                                       _ workspace: RemoteWorkspace, _ cancellation: TransferCancellation) throws -> String {
        let file = workspace.nextURL("verification")
        defer { try? FileManager.default.removeItem(at: file) }
        try fetch(provider, entry, file, cancellation, { _ in })
        return try RemoteDigest.hash(file)
    }
    fileprivate static func regular(_ entry: RemoteEntry) throws {
        guard !entry.isDirectory && !entry.isSymbolicLink, entry.size >= 0 else {
            throw RemoteTransferError.unsupported("Операция доступна только для обычного сетевого файла: «\(entry.path)».")
        }
    }
    fileprivate static func required(_ provider: RemoteProvider, _ path: String, _ cancellation: TransferCancellation) throws -> RemoteEntry {
        try validPath(path); try check(cancellation)
        guard let entry = try provider.stat(path: path, cancellation: cancellation), entry.path == path else { throw RemoteTransferError.conflict(path) }
        return entry
    }
    private static func children(_ provider: RemoteProvider, _ path: String, _ cancellation: TransferCancellation) throws -> [RemoteEntry] {
        let listing = try provider.list(path: path, cancellation: cancellation)
        guard listing.count <= RemoteTransferLimits.maximumEntries else { throw RemoteTransferError.unsupported("Сетевая папка превышает предел 100000 элементов.") }
        let values = listing.sorted { $0.path < $1.path }
        var names = Set<String>()
        for child in values {
            try validPath(child.path)
            guard parent(child.path) == (path == "/" ? "/" : path + "/"), names.insert(name(child.path)).inserted else {
                throw RemoteTransferError.invalidPath
            }
        }
        return values
    }
    fileprivate static func check(_ cancellation: TransferCancellation) throws {
        if cancellation.isCancelled { throw RemoteTransferError.cancelled }
    }
    private static func limit(_ depth: Int) throws {
        if depth > RemoteTransferLimits.maximumDepth { throw RemoteTransferError.unsupported("Достигнут предел вложенности сетевых папок (128).") }
    }
    private static func validPath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\r"), !path.contains("\n"),
              path == "/" || !path.hasSuffix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw RemoteTransferError.invalidPath
        }
    }
    private static func name(_ path: String) -> String { String(path.split(separator: "/").last ?? "") }
    private static func parent(_ path: String) -> String { String(path.prefix((path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) } ?? 0) + 1)) }
}

private struct LocalRemoteStamp: Equatable {
    let device: dev_t, inode: ino_t, mode: mode_t
    let size: Int64, modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    var directory: Bool { mode & S_IFMT == S_IFDIR }
    var link: Bool { mode & S_IFMT == S_IFLNK }
    init(_ url: URL) throws {
        guard url.isFileURL else { throw RemoteTransferError.invalidPath }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR || value.st_mode & S_IFMT == S_IFLNK else {
            throw RemoteTransferError.unsupported("Специальные файлы не поддерживаются.")
        }
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
    func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    static func optional(_ url: URL) throws -> Self? {
        do { return try Self(url) } catch let error as POSIXError where error.code == .ENOENT { return nil }
    }
}
private enum RemoteDigest {
    static func hash(_ url: URL, cancellation: TransferCancellation? = nil) throws -> String {
        let before = try LocalRemoteStamp(url)
        guard !before.directory && !before.link else { throw RemoteTransferError.invalidPath }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            if let cancellation { try RemoteTransferEngine.check(cancellation) }
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            digest.update(data: data)
        }
        guard try LocalRemoteStamp(url) == before else { throw RemoteTransferError.conflict(url.path) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct RemoteTreeBudget {
    var entries = 0
    var bytes: Int64 = 0
    mutating func admit(size: Int64) throws {
        guard entries < RemoteTransferLimits.maximumEntries, size >= 0,
              size <= RemoteTransferLimits.maximumBytes - bytes else {
            throw RemoteTransferError.unsupported("Превышен предел сетевой операции: 100000 элементов или 1 ТиБ.")
        }
        entries += 1; bytes += size
    }
}
