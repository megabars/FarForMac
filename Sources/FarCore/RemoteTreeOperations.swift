import Foundation

/// These providers send RMD/RMDIR, whose server contract refuses nonempty folders.
/// WebDAV DELETE is recursive, even if a preceding PROPFIND returned an empty folder.
public protocol RemoteNonRecursiveDirectoryRemoval: RemoteProvider {}
extension FTPRemoteProvider: RemoteNonRecursiveDirectoryRemoval {}
extension SFTPProvider: RemoteNonRecursiveDirectoryRemoval {}

/// replace:false must be enforced by the server (SFTP RENAME / DAV Overwrite:F).
/// FTP RNTO is deliberately excluded: a client-side stat cannot prevent overwrite.
public protocol RemoteNoReplaceRenameProvider: RemoteProvider {}
extension SFTPProvider: RemoteNoReplaceRenameProvider {}
extension WebRemoteProvider: RemoteNoReplaceRenameProvider {}

public struct RemoteTreePlan: Sendable {
    public let roots: [RemoteEntry]
    public let entries: [RemoteEntry]
    public let totalBytes: Int64
    public var fileCount: Int { entries.filter { !$0.isDirectory || $0.isSymbolicLink }.count }
    public var directoryCount: Int { entries.count - fileCount }
    fileprivate let connection: NetworkConnection
    fileprivate let providerID: ObjectIdentifier
    fileprivate let children: [String: [RemoteEntry]]
    fileprivate let snapshots: [String: RemoteEntry]
}
public struct RemoteMoveItem: Sendable {
    public let source: RemoteEntry
    public let destination: String
}
public struct RemoteMovePlan: Sendable {
    public let tree: RemoteTreePlan
    public let moves: [RemoteMoveItem]
    fileprivate let parents: [String: RemoteEntry]
}
public struct RemoteMutationRecord: Equatable, Sendable {
    public let source: String
    public let destination: String?
}
public struct RemoteMutationReport: Equatable, Sendable {
    public let completed: [RemoteMutationRecord]
}
/// A failed request may have reached the server. Only acknowledged operations are
/// in completed; refresh both paths before repeating the uncertain request.
public struct RemoteTreeOperationError: Error, LocalizedError {
    public let report: RemoteMutationReport
    public let path: String
    public let outcomeUnknown: Bool
    public let cause: Error
    public var errorDescription: String? {
        let completedPaths = report.completed.prefix(20).map { $0.source + ($0.destination.map { " → " + $0 } ?? "") }.joined(separator: "\n")
        return "Выполнено объектов: \(report.completed.count). Операция остановлена на «\(path)». " +
            (outcomeUnknown ? "Сервер мог выполнить последнюю команду; обновите обе панели перед повтором. " : "") + cause.localizedDescription +
            (completedPaths.isEmpty ? "" : "\nЗавершено:\n" + completedPaths + (report.completed.count > 20 ? "\n… Показаны первые 20 завершённых объектов." : ""))
    }
}

public enum RemoteTreeOperations {
    /// Read-only preview. The caller must display the full selection/counts and
    /// obtain explicit approval before passing this immutable plan to delete.
    public static func prepareDelete(provider: RemoteProvider, entries: [RemoteEntry],
                                     cancellation: TransferCancellation = TransferCancellation(),
                                     progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteTreePlan {
        let plan = try capture(provider, entries, cancellation, progress)
        if plan.directoryCount > 0 && !(provider is RemoteNonRecursiveDirectoryRemoval) {
            throw RemoteTransferError.unsupported("Этот сервер удаляет папки рекурсивной командой. Безопасное пообъектное удаление папок доступно для SFTP/FTP; WebDAV-папки сохранены.")
        }
        return plan
    }

    @discardableResult public static func delete(provider: RemoteProvider, plan: RemoteTreePlan,
                                               cancellation: TransferCancellation = TransferCancellation(),
                                               progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteMutationReport {
        var completed: [RemoteMutationRecord] = [], path = plan.roots.first?.path ?? "/", attempted = false
        do {
            try verify(provider, plan, cancellation)
            guard plan.directoryCount == 0 || provider is RemoteNonRecursiveDirectoryRemoval else {
                throw RemoteTransferError.unsupported("Сервер не поддерживает нерекурсивное удаление папок.")
            }
            for entry in plan.entries.reversed() {
                path = entry.path; attempted = false
                try check(cancellation); try ancestors(provider, entry.path, cancellation)
                if entry.isDirectory && !entry.isSymbolicLink {
                    guard let current = try provider.stat(path: entry.path, cancellation: cancellation), current.isDirectory, !current.isSymbolicLink,
                          try listing(provider, entry.path, cancellation).isEmpty else { throw RemoteTransferError.conflict(entry.path) }
                } else {
                    guard try provider.stat(path: entry.path, cancellation: cancellation) == entry else { throw RemoteTransferError.conflict(entry.path) }
                }
                try check(cancellation); attempted = true
                try provider.remove(path: entry.path, isDirectory: entry.isDirectory && !entry.isSymbolicLink, cancellation: cancellation)
                completed.append(RemoteMutationRecord(source: entry.path, destination: nil)); attempted = false
                progress(NetworkProgress(path: "Удалено \(completed.count)/\(plan.entries.count): " + entry.path, completedBytes: 0, totalBytes: 0))
            }
            return RemoteMutationReport(completed: completed)
        } catch { throw RemoteTreeOperationError(report: RemoteMutationReport(completed: completed), path: attempted ? path : failurePath(error, fallback: path), outcomeUnknown: attempted, cause: error) }
    }

    /// Same-server rename/move, never copy-and-delete or replace. Multiple sources
    /// are moved into an existing folder; a single source can receive a new name.
    public static func prepareMove(provider: RemoteProvider, entries: [RemoteEntry], to destination: String,
                                   intoDirectory: Bool,
                                   cancellation: TransferCancellation = TransferCancellation(),
                                   progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteMovePlan {
        guard provider is RemoteNoReplaceRenameProvider else {
            throw RemoteTransferError.unsupported("Этот протокол не гарантирует переименование без замены нового назначения. FTP/FTPS RNTO может перезаписать файл другого клиента; перенос и переименование дерева отключены.")
        }
        let destination = try path(destination)
        guard intoDirectory || entries.count == 1 else { throw RemoteTransferError.invalidPath }
        let tree = try capture(provider, entries, cancellation, progress)
        let moves = try tree.roots.map { RemoteMoveItem(source: $0, destination: intoDirectory ? try RemotePath.child($0.name, of: destination) : destination) }
        var parents: [String: RemoteEntry] = [:], names = Set<String>()
        for move in moves {
            guard move.destination != "/", names.insert(move.destination).inserted,
                  tree.snapshots[move.destination] == nil,
                  try provider.stat(path: move.destination, cancellation: cancellation) == nil else { throw RemoteTransferError.conflict(move.destination) }
            var ancestor = RemotePath.parent(move.destination)
            while ancestor != "/" {
                guard tree.snapshots[ancestor] == nil else { throw RemoteTransferError.conflict(move.destination) }
                ancestor = RemotePath.parent(ancestor)
            }
            let parent = RemotePath.parent(move.destination)
            try ancestors(provider, move.destination, cancellation)
            guard let entry = try provider.stat(path: parent, cancellation: cancellation), entry.isDirectory, !entry.isSymbolicLink else { throw RemoteTransferError.conflict(parent) }
            parents[parent] = entry
        }
        return RemoteMovePlan(tree: tree, moves: moves, parents: parents)
    }
    @discardableResult public static func move(provider: RemoteProvider, plan: RemoteMovePlan,
                                             cancellation: TransferCancellation = TransferCancellation(),
                                             progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteMutationReport {
        var completed: [RemoteMutationRecord] = [], current = plan.moves.first?.source.path ?? "/", attempted = false
        do {
            guard provider is RemoteNoReplaceRenameProvider else { throw RemoteTransferError.unsupported("Сервер не гарантирует переименование без замены.") }
            try verify(provider, plan.tree, cancellation)
            for (parent, expected) in plan.parents {
                guard try provider.stat(path: parent, cancellation: cancellation) == expected else { throw RemoteTransferError.conflict(parent) }
            }
            // Check all destinations before the first rename, then again immediately
            // before each server-enforced no-replace rename.
            for move in plan.moves {
                guard try provider.stat(path: move.destination, cancellation: cancellation) == nil else { throw RemoteTransferError.conflict(move.destination) }
            }
            for move in plan.moves {
                current = move.source.path; attempted = false
                try check(cancellation); try ancestors(provider, move.source.path, cancellation); try ancestors(provider, move.destination, cancellation)
                try verifySubtree(provider, plan.tree, root: move.source.path, cancellation)
                guard try provider.stat(path: move.destination, cancellation: cancellation) == nil else { throw RemoteTransferError.conflict(move.destination) }
                try check(cancellation); attempted = true
                try provider.rename(from: move.source.path, to: move.destination, replace: false, cancellation: cancellation)
                completed.append(RemoteMutationRecord(source: move.source.path, destination: move.destination)); attempted = false
                guard try provider.stat(path: move.source.path, cancellation: cancellation) == nil,
                      let target = try provider.stat(path: move.destination, cancellation: cancellation),
                      target.isDirectory == move.source.isDirectory, target.isSymbolicLink == move.source.isSymbolicLink else {
                    throw RemoteTransferError.verification("Переименование подтверждено сервером, но проверка результата не пройдена: «\(move.destination)».")
                }
                progress(NetworkProgress(path: "Перенесено \(completed.count)/\(plan.moves.count): " + move.destination, completedBytes: 0, totalBytes: 0))
            }
            return RemoteMutationReport(completed: completed)
        } catch { throw RemoteTreeOperationError(report: RemoteMutationReport(completed: completed), path: attempted ? current : failurePath(error, fallback: current), outcomeUnknown: attempted, cause: error) }
    }

    private static func capture(_ provider: RemoteProvider, _ entries: [RemoteEntry], _ token: TransferCancellation,
                                _ progress: @escaping (NetworkProgress) -> Void) throws -> RemoteTreePlan {
        guard !entries.isEmpty else { throw RemoteTransferError.invalidPath }
        guard entries.count <= RemoteTransferLimits.maximumEntries else { throw RemoteTransferError.unsupported("Превышен предел дерева 100000 объектов.") }
        var discovered = entries.count
        let connection = provider.connection
        var all: [RemoteEntry] = [], children: [String: [RemoteEntry]] = [:], bytes: Int64 = 0, paths = Set<String>()
        let roots = entries.sorted { $0.path < $1.path }
        for entry in roots {
            _ = try path(entry.path)
            guard entry.path != "/", paths.insert(entry.path).inserted else { throw RemoteTransferError.invalidPath }
        }
        for entry in roots {
            var parent = RemotePath.parent(entry.path)
            while parent != "/" {
                guard !paths.contains(parent) else { throw RemoteTransferError.invalidPath }
                parent = RemotePath.parent(parent)
            }
        }
        func scan(_ entry: RemoteEntry, depth: Int) throws {
            try check(token)
            guard depth <= RemoteTransferLimits.maximumDepth, all.count < RemoteTransferLimits.maximumEntries,
                  entry.size >= 0 else { throw RemoteTransferError.unsupported("Превышен предел дерева: 128 уровней или 100000 объектов; либо сервер вернул неверный размер.") }
            guard try provider.stat(path: entry.path, cancellation: token) == entry else { throw RemoteTransferError.conflict(entry.path) }
            if !entry.isDirectory && !entry.isSymbolicLink {
                guard entry.size <= RemoteTransferLimits.maximumBytes - bytes else { throw RemoteTransferError.unsupported("Превышен предел дерева 1 ТиБ.") }
                bytes += entry.size
            }
            all.append(entry); progress(NetworkProgress(path: "Проверка \(all.count): " + entry.path, completedBytes: 0, totalBytes: 0))
            if entry.isDirectory && !entry.isSymbolicLink {
                let listing = try listing(provider, entry.path, token)
                guard listing.count <= RemoteTransferLimits.maximumEntries - discovered else {
                    throw RemoteTransferError.unsupported("Превышен предел дерева 100000 объектов.")
                }
                discovered += listing.count
                children[entry.path] = listing
                for child in listing { try scan(child, depth: depth + 1) }
                guard try self.listing(provider, entry.path, token) == listing,
                      try provider.stat(path: entry.path, cancellation: token) == entry else { throw RemoteTransferError.conflict(entry.path) }
            }
        }
        for entry in roots { try ancestors(provider, entry.path, token); try scan(entry, depth: 0) }
        guard provider.connection == connection else { throw RemoteTransferError.conflict("Параметры подключения") }
        return RemoteTreePlan(roots: roots, entries: all, totalBytes: bytes, connection: connection, providerID: ObjectIdentifier(provider), children: children, snapshots: Dictionary(uniqueKeysWithValues: all.map { ($0.path, $0) }))
    }
    private static func verify(_ provider: RemoteProvider, _ plan: RemoteTreePlan, _ token: TransferCancellation) throws {
        try check(token)
        guard provider.connection == plan.connection, ObjectIdentifier(provider) == plan.providerID else { throw RemoteTransferError.conflict("Подключение изменилось") }
        for root in plan.roots { try ancestors(provider, root.path, token); try verifySubtree(provider, plan, root: root.path, token) }
    }
    private static func verifySubtree(_ provider: RemoteProvider, _ plan: RemoteTreePlan, root: String, _ token: TransferCancellation) throws {
        guard let entry = plan.snapshots[root] else { throw RemoteTransferError.invalidPath }
        try check(token)
        guard try provider.stat(path: entry.path, cancellation: token) == entry else { throw RemoteTransferError.conflict(entry.path) }
        if let expected = plan.children[root] {
            guard try listing(provider, root, token) == expected else { throw RemoteTransferError.conflict(root) }
            for child in expected { try verifySubtree(provider, plan, root: child.path, token) }
        }
    }
    private static func listing(_ provider: RemoteProvider, _ parent: String, _ token: TransferCancellation) throws -> [RemoteEntry] {
        try check(token)
        let entries = try provider.list(path: parent, cancellation: token)
        guard entries.count <= RemoteTransferLimits.maximumEntries else { throw RemoteTransferError.unsupported("Слишком много объектов в папке.") }
        var seen = Set<String>()
        for entry in entries {
            _ = try path(entry.path)
            guard RemotePath.parent(entry.path) == parent, entry.path != parent, seen.insert(entry.path).inserted else { throw RemoteTransferError.invalidPath }
        }
        return entries.sorted { $0.path < $1.path }
    }
    private static func ancestors(_ provider: RemoteProvider, _ child: String, _ token: TransferCancellation) throws {
        var current = RemotePath.parent(child)
        while true {
            try check(token)
            guard let entry = try provider.stat(path: current, cancellation: token), entry.path == current,
                  entry.isDirectory, !entry.isSymbolicLink else { throw RemoteTransferError.conflict(current) }
            if current == "/" { return }; current = RemotePath.parent(current)
        }
    }
    private static func path(_ value: String) throws -> String {
        let clean = try RemotePath.validate(value)
        guard clean == value else { throw RemoteTransferError.invalidPath }; return clean
    }
    private static func failurePath(_ error: Error, fallback: String) -> String {
        if let error = error as? RemoteTransferError, case .conflict(let path) = error { return path }
        if let error = error as? NetworkError {
            switch error { case .conflict(let path), .notFound(let path), .invalidPath(let path): return path; default: break }
        }
        return fallback
    }
    private static func check(_ token: TransferCancellation) throws { if token.isCancelled { throw RemoteTransferError.cancelled } }
}
