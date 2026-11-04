import Foundation
import Darwin

/// Enforces the byte ceiling in the transport, before writing excess bytes.
public protocol RemoteBoundedDownloadProvider: RemoteProvider {
    func boundedDownload(path: String, to: URL, maximumBytes: Int64,
                         cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws
}

public enum RemoteDirectoryConflictPolicy: Sendable {
    case requireNew
    /// Existing directories are traversed; existing files, links and type
    /// conflicts are skipped with their entire source subtree. Never replaces.
    case mergeSkippingExisting
}

public enum RemoteDirectoryConflictDecision: Equatable, Sendable {
    case skip
    case replace
    /// A single new destination name, never a path. The existing object remains.
    case rename(String)
}

public struct RemoteDirectoryConflict: Equatable, Sendable {
    public let mapping: RemoteDirectoryMapping
    public let sourceIsDirectory: Bool
    public let destinationIsDirectory: Bool
    public let destinationIsSymbolicLink: Bool
    public let destinationSize: Int64
    public var canReplace: Bool { !sourceIsDirectory && !destinationIsDirectory && !destinationIsSymbolicLink }
    fileprivate let local: LocalRemoteStamp?
    fileprivate let remote: RemoteEntry?
}

public struct RemoteDirectorySourceRetention: Equatable, Sendable {
    public let source: String
    public let reason: String
    /// The server may have accepted an unlink whose response was lost.
    public let outcomeUnknown: Bool
}

public struct RemoteDirectoryMapping: Equatable, Sendable {
    public let source: String
    public let destination: String
}

/// The preview is read-only and tied to one provider instance and connection.
/// copies contains maximal missing subtrees and explicitly approved ordinary
/// file replacements. Destination objects in skipped are never modified.
public struct RemoteDirectoryTransferPlan: Sendable {
    public let download: Bool
    public let policy: RemoteDirectoryConflictPolicy
    public let roots: [RemoteDirectoryMapping]
    public let copies: [RemoteDirectoryMapping]
    public let skipped: [RemoteDirectoryMapping]
    public let conflicts: [RemoteDirectoryConflict]
    fileprivate let replacements: [String: DirectoryTransferReplacement]
    public var replacementSources: Set<String> { Set(replacements.keys) }
    /// An empty source directory merged into a reviewed existing destination
    /// needs no copy, but MOVE can still remove that verified empty source.
    public var hasMoveCandidates: Bool {
        if !copies.isEmpty { return true }
        let targets = Dictionary(uniqueKeysWithValues: roots.map { ($0.source, $0.destination) })
        for node in nodes where node.directory && node.children.isEmpty {
            var ancestor = node.source
            while ancestor != "/" && !ancestor.isEmpty {
                if let root = targets[ancestor] {
                    let target = root + node.source.dropFirst(ancestor.count)
                    if download ? localParents[target] != nil : remoteParents[target] != nil { return true }
                    break
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
        }
        return false
    }
    public let fileCount: Int
    public let directoryCount: Int
    public let totalBytes: Int64
    public let transferBytes: Int64
    fileprivate let providerID: ObjectIdentifier
    fileprivate let connection: NetworkConnection
    fileprivate let nodes: [DirectoryTransferNode]
    fileprivate let remoteParents: [String: RemoteEntry]
    fileprivate let localParents: [String: LocalRemoteStamp]
}

public struct RemoteDirectoryTransferReport: Equatable, Sendable {
    /// A completed mapping represents its entire verified subtree.
    public let completed: [RemoteDirectoryMapping]
    public let skipped: [RemoteDirectoryMapping]
    public let moving: Bool
    public let removedSources: [String]
    /// Original plan nodes not acknowledged removed after skips or failures.
    /// New, unplanned children are preserved by nonrecursive directory removal.
    public let retainedSources: [String]
    public let failedSourceRemovals: [RemoteDirectorySourceRetention]
}

fileprivate struct DirectoryTransferReplacement: Sendable {
    let local: LocalRemoteStamp?
    let remote: RemoteEntry?
    let hash: String
}

public struct RemoteDirectoryTransferFailure: Error, LocalizedError {
    public let report: RemoteDirectoryTransferReport
    public let current: RemoteDirectoryMapping?
    /// A failed remote publication or failed post-publication check may already
    /// have created this destination. No automatic rollback deletes user data.
    public let outcomeUnknown: Bool
    public let cause: Error
    public var errorDescription: String? {
        let paths = report.completed.prefix(20).map { $0.source + " → " + $0.destination }.joined(separator: "\n")
        func details(_ title: String, _ values: [String]) -> String {
            guard !values.isEmpty else { return "" }
            return "\n" + title + " (\(values.count)):\n" + values.prefix(20).joined(separator: "\n") +
                (values.count > 20 ? "\n… Показаны первые 20 объектов." : "")
        }
        return "Скопировано поддеревьев: \(report.completed.count); пропущено конфликтов: \(report.skipped.count). " +
            (report.moving ? "Удалено исходников: \(report.removedSources.count); сохранено исходников: \(report.retainedSources.count). " : "Исходники сохранены. ") +
            (current.map { "Остановка: «\($0.source) → \($0.destination)». " } ?? "") +
            (outcomeUnknown ? "Последнее назначение могло появиться; обновите обе панели перед повтором. " : "") +
            cause.localizedDescription + (paths.isEmpty ? "" : "\nПодтверждённые копии:\n" + paths) +
            details("Подтверждённо удалённые исходники", report.removedSources) +
            details("Сохранённые исходники плана", report.retainedSources) +
            details("Причины сохранения", report.failedSourceRemovals.map { $0.source + ": " + $0.reason })
    }
}

fileprivate struct DirectoryTransferNode: Sendable {
    let source: String
    let directory: Bool
    let size: Int64
    let local: LocalRemoteStamp?
    let remote: RemoteEntry?
    let hash: String?
    let children: [String]
}

public enum RemoteDirectoryTransfer {
    public static func prepareDownload(provider: RemoteProvider, entries: [RemoteEntry], into destination: URL,
                                       policy: RemoteDirectoryConflictPolicy,
                                       cancellation: TransferCancellation = TransferCancellation(),
                                       progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteDirectoryTransferPlan {
        guard provider is RemoteBoundedDownloadProvider else { throw RemoteTransferError.unsupported("Провайдер не поддерживает ограничение размера загрузки дерева.") }
        let destination = systemAliases(destination.standardizedFileURL)
        var localParents: [String: LocalRemoteStamp] = [:], remoteParents: [String: RemoteEntry] = [:]
        try localAncestors(destination, includeSelf: true, into: &localParents)
        let sources = entries.map(\.path)
        try selection(sources, remote: true)
        let connection = provider.connection
        var nodes: [DirectoryTransferNode] = [], budget = Budget()
        func scan(_ entry: RemoteEntry, depth: Int) throws {
            try check(cancellation); try budget.admit(directory: entry.isDirectory, size: entry.size, depth: depth)
            try remotePath(entry.path)
            guard !entry.isSymbolicLink else { throw RemoteTransferError.unsupported("Сетевые ссылки не копируются: «\(entry.path)».") }
            guard try provider.stat(path: entry.path, cancellation: cancellation) == entry else { throw RemoteTransferError.conflict(entry.path) }
            let children = entry.isDirectory ? try listing(provider, entry.path, cancellation) : []
            try budget.discover(children.count)
            nodes.append(DirectoryTransferNode(source: entry.path, directory: entry.isDirectory, size: entry.isDirectory ? 0 : entry.size,
                                               local: nil, remote: entry, hash: nil, children: children.map(\.path)))
            progress(NetworkProgress(path: "Предпросмотр \(nodes.count): " + entry.path, completedBytes: 0, totalBytes: 0))
            for child in children { try scan(child, depth: depth + 1) }
            guard try provider.stat(path: entry.path, cancellation: cancellation) == entry,
                  try (!entry.isDirectory || listing(provider, entry.path, cancellation) == children) else { throw RemoteTransferError.conflict(entry.path) }
        }
        try budget.discover(entries.count)
        for entry in entries { try remoteAncestors(provider, entry.path, into: &remoteParents, cancellation); try scan(entry, depth: 0) }
        let roots = entries.map { RemoteDirectoryMapping(source: $0.path, destination: destination.appendingPathComponent($0.name).path) }
        var copies: [RemoteDirectoryMapping] = [], skipped: [RemoteDirectoryMapping] = [], conflicts: [RemoteDirectoryConflict] = []
        let byPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.source, $0) })
        func decide(_ source: String, _ target: URL) throws {
            try check(cancellation)
            guard let node = byPath[source] else { throw RemoteTransferError.invalidPath }
            let mapping = RemoteDirectoryMapping(source: source, destination: target.path)
            guard let existing = try LocalRemoteStamp.optional(target) else {
                try newTarget(provider, download: true, target.path, cancellation)
                copies.append(mapping); return
            }
            guard policy == .mergeSkippingExisting else { throw RemoteTransferError.conflict(target.path) }
            if node.directory && existing.directory && !existing.link {
                localParents[target.path] = existing
                for child in node.children { try decide(child, target.appendingPathComponent((child as NSString).lastPathComponent)) }
            } else {
                skipped.append(mapping)
                conflicts.append(RemoteDirectoryConflict(mapping: mapping, sourceIsDirectory: node.directory,
                    destinationIsDirectory: existing.directory, destinationIsSymbolicLink: existing.link,
                    destinationSize: existing.size, local: existing, remote: nil))
            }
        }
        for root in roots { try decide(root.source, URL(fileURLWithPath: root.destination)) }
        guard provider.connection == connection else { throw RemoteTransferError.conflict("Подключение изменилось") }
        return plan(true, policy, roots, copies, skipped, conflicts, nodes, provider, connection, remoteParents, localParents, budget)
    }

    public static func prepareUpload(provider: RemoteProvider, sources: [URL], into destination: String,
                                     policy: RemoteDirectoryConflictPolicy,
                                     cancellation: TransferCancellation = TransferCancellation(),
                                     progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteDirectoryTransferPlan {
        guard provider is RemoteNoReplaceRenameProvider, provider is RemoteBoundedDownloadProvider else { throw RemoteTransferError.unsupported("Слияние и копирование дерева на сервер требуют атомарного запрета замены (SFTP/WebDAV). FTP/FTPS RNTO такой гарантии не даёт.") }
        try remotePath(destination)
        let sources = sources.map { systemAliases($0.standardizedFileURL) }
        try selection(sources.map(\.path), remote: false)
        var localParents: [String: LocalRemoteStamp] = [:], remoteParents: [String: RemoteEntry] = [:]
        try remoteAncestors(provider, destination + (destination == "/" ? "" : "/") + ".farmac-preview", into: &remoteParents, cancellation)
        let connection = provider.connection
        var nodes: [DirectoryTransferNode] = [], budget = Budget()
        func scan(_ url: URL, depth: Int) throws {
            try check(cancellation)
            let stamp = try LocalRemoteStamp(url)
            guard !stamp.link else { throw RemoteTransferError.unsupported("Локальные ссылки не копируются: «\(url.path)».") }
            _ = try RemotePath.child(url.lastPathComponent, of: "/")
            try budget.admit(directory: stamp.directory, size: stamp.size, depth: depth)
            let children = stamp.directory ? try localListing(url) : []
            try budget.discover(children.count)
            let hash = stamp.directory ? nil : try RemoteDigest.hash(url, cancellation: cancellation)
            nodes.append(DirectoryTransferNode(source: url.path, directory: stamp.directory, size: stamp.directory ? 0 : stamp.size,
                                               local: stamp, remote: nil, hash: hash, children: children.map(\.path)))
            progress(NetworkProgress(path: "Предпросмотр \(nodes.count): " + url.path, completedBytes: 0, totalBytes: 0))
            for child in children { try scan(child, depth: depth + 1) }
            guard try LocalRemoteStamp(url) == stamp,
                  try (!stamp.directory || localListing(url).map(\.path) == children.map(\.path)) else { throw RemoteTransferError.conflict(url.path) }
        }
        try budget.discover(sources.count)
        for source in sources { try localAncestors(source, includeSelf: false, into: &localParents); try scan(source, depth: 0) }
        let roots = try sources.map { RemoteDirectoryMapping(source: $0.path, destination: try RemotePath.child($0.lastPathComponent, of: destination)) }
        var copies: [RemoteDirectoryMapping] = [], skipped: [RemoteDirectoryMapping] = [], conflicts: [RemoteDirectoryConflict] = []
        let byPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.source, $0) })
        func decide(_ source: String, _ target: String) throws {
            try check(cancellation)
            guard let node = byPath[source] else { throw RemoteTransferError.invalidPath }
            let mapping = RemoteDirectoryMapping(source: source, destination: target)
            guard let existing = try provider.stat(path: target, cancellation: cancellation) else {
                try newTarget(provider, download: false, target, cancellation)
                copies.append(mapping); return
            }
            guard existing.path == target else { throw RemoteTransferError.invalidPath }
            guard policy == .mergeSkippingExisting else { throw RemoteTransferError.conflict(target) }
            if node.directory && existing.isDirectory && !existing.isSymbolicLink {
                remoteParents[target] = existing
                for child in node.children { try decide(child, RemotePath.child((child as NSString).lastPathComponent, of: target)) }
            } else {
                skipped.append(mapping)
                conflicts.append(RemoteDirectoryConflict(mapping: mapping, sourceIsDirectory: node.directory,
                    destinationIsDirectory: existing.isDirectory, destinationIsSymbolicLink: existing.isSymbolicLink,
                    destinationSize: existing.size, local: nil, remote: existing))
            }
        }
        for root in roots { try decide(root.source, root.destination) }
        guard provider.connection == connection else { throw RemoteTransferError.conflict("Подключение изменилось") }
        return plan(false, policy, roots, copies, skipped, conflicts, nodes, provider, connection, remoteParents, localParents, budget)
    }

    @discardableResult public static func copy(provider: RemoteProvider, plan: RemoteDirectoryTransferPlan,
                                              move: Bool = false,
                                              cancellation: TransferCancellation = TransferCancellation(),
                                              progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteDirectoryTransferReport {
        var completed: [RemoteDirectoryMapping] = [], current: RemoteDirectoryMapping?, uncertain = false
        var removed: [String] = [], retained: [RemoteDirectorySourceRetention] = []
        func report() -> RemoteDirectoryTransferReport {
            let removedSet = Set(removed)
            return RemoteDirectoryTransferReport(completed: completed, skipped: plan.skipped, moving: move,
                removedSources: removed, retainedSources: move ? plan.nodes.map(\.source).filter { !removedSet.contains($0) } : [],
                failedSourceRemovals: retained)
        }
        do {
            if move && plan.download && !(provider is RemoteNonRecursiveDirectoryRemoval) {
                throw RemoteTransferError.unsupported("Безопасный перенос с удалением исходных папок доступен для SFTP/FTP; WebDAV DELETE рекурсивен. Используйте копирование.")
            }
            try verify(provider, plan, cancellation)
            // Freeze every selected root before the first destination mutation.
            // A cancellation during this phase leaves no destination copies.
            let workspace = try RemoteWorkspace()
            var frozen: [String: URL] = [:]
            let byPath = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.source, $0) })
            var bytes: Int64 = 0
            func freeze(_ source: String, _ target: URL) throws {
                try check(cancellation)
                guard let node = byPath[source] else { throw RemoteTransferError.invalidPath }
                frozen[source] = target
                if node.directory {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    for child in node.children { try freeze(child, target.appendingPathComponent((child as NSString).lastPathComponent)) }
                    let actual = try localListing(target).map(\.lastPathComponent)
                    guard actual == node.children.map({ ($0 as NSString).lastPathComponent }).sorted() else { throw RemoteTransferError.conflict(source) }
                } else if plan.download {
                    guard try provider.stat(path: source, cancellation: cancellation) == node.remote else { throw RemoteTransferError.conflict(source) }
                    guard let bounded = provider as? RemoteBoundedDownloadProvider else { throw RemoteTransferError.unsupported("Провайдер не ограничивает размер скачивания.") }
                    let exclusive = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
                    guard exclusive >= 0 else { throw RemoteTransferError.conflict(target.path) }
                    close(exclusive)
                    let identity = try LocalRemoteStamp(target)
                    try bounded.boundedDownload(path: source, to: target, maximumBytes: node.size, cancellation: cancellation) { update in
                        progress(NetworkProgress(path: update.path, completedBytes: bytes + min(node.size, max(0, update.completedBytes)), totalBytes: plan.transferBytes))
                    }
                    let stamp = try LocalRemoteStamp(target)
                    guard !stamp.directory, !stamp.link, stamp.sameObject(identity), stamp.size == node.size,
                          try provider.stat(path: source, cancellation: cancellation) == node.remote else { throw RemoteTransferError.conflict(source) }
                    _ = chmod(target.path, 0o600)
                } else {
                    let original = URL(fileURLWithPath: source)
                    guard try LocalRemoteStamp(original) == node.local else { throw RemoteTransferError.conflict(source) }
                    try clone(original, to: target, cancellation)
                    guard try RemoteDigest.hash(target, cancellation: cancellation) == node.hash,
                          try LocalRemoteStamp(original) == node.local,
                          try RemoteDigest.hash(original, cancellation: cancellation) == node.hash else { throw RemoteTransferError.conflict(source) }
                    _ = chmod(target.path, 0o600)
                }
                if !node.directory { bytes += node.size }
                progress(NetworkProgress(path: "Подготовлено: " + source, completedBytes: bytes, totalBytes: plan.transferBytes))
            }
            for root in plan.copies { try freeze(root.source, workspace.directory.appendingPathComponent(UUID().uuidString)) }
            try verify(provider, plan, cancellation)
            for mapping in plan.copies {
                current = mapping
                try check(cancellation); try destinationParents(provider, plan, cancellation)
                guard let local = frozen[mapping.source] else { throw RemoteTransferError.invalidPath }
                if plan.download {
                    try verifyTarget(provider, plan, mapping, cancellation)
                    try publishLocal(local, to: URL(fileURLWithPath: mapping.destination), parents: plan.localParents,
                                     replacement: plan.replacements[mapping.source], cancellation)
                } else {
                    try verifyTarget(provider, plan, mapping, cancellation)
                    // Existing transfer worker stages, verifies bytes, and uses
                    // server-enforced replace:false for the final publication.
                    uncertain = true
                    let publishingProgress: (NetworkProgress) -> Void = { update in
                        progress(NetworkProgress(path: "Публикация: " + mapping.destination + " — " + update.path,
                                                 completedBytes: update.completedBytes, totalBytes: update.totalBytes))
                    }
                    if let replacement = plan.replacements[mapping.source], let expected = replacement.remote {
                        try RemoteTransferEngine.uploadReviewedFile(provider: provider, from: local, to: mapping.destination,
                            expected: expected, expectedHash: replacement.hash, cancellation: cancellation, progress: publishingProgress)
                    } else {
                        try RemoteTransferEngine.upload(provider: provider, from: local, to: mapping.destination,
                            cancellation: cancellation, progress: publishingProgress)
                    }
                }
                uncertain = true
                try verifyPublished(provider, plan.download, local, mapping.destination, cancellation)
                completed.append(mapping); uncertain = false; current = nil
                progress(NetworkProgress(path: "Скопировано поддеревьев \(completed.count)/\(plan.copies.count): " + mapping.destination,
                                         completedBytes: bytes, totalBytes: plan.transferBytes))
            }
            if move {
                try removeSources(provider, plan, completed, frozen, cancellation, progress, removed: &removed, retained: &retained)
            }
            return report()
        } catch {
            throw RemoteDirectoryTransferFailure(report: report(),
                                                 current: current, outcomeUnknown: uncertain, cause: error)
        }
    }

    /// Resolve reviewed conflicts without changing either endpoint. Omitted
    /// decisions keep the default skip. Every rename must select a new sibling.
    public static func resolve(provider: RemoteProvider, plan: RemoteDirectoryTransferPlan,
                               decisions: [String: RemoteDirectoryConflictDecision],
                               cancellation: TransferCancellation = TransferCancellation(),
                               progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteDirectoryTransferPlan {
        try verify(provider, plan, cancellation)
        let known = Set(plan.conflicts.map { $0.mapping.source })
        guard Set(decisions.keys).isSubset(of: known) else { throw RemoteTransferError.invalidPath }
        var copies = plan.copies.filter { !known.contains($0.source) }
        var skipped = plan.conflicts.map(\.mapping), replacements: [String: DirectoryTransferReplacement] = [:]
        let workspace = try RemoteWorkspace()
        var reviewedBytes: Int64 = 0
        for conflict in plan.conflicts {
            try check(cancellation)
            let mapping = conflict.mapping
            // The decision is tied to the exact object shown in the preview.
            if plan.download {
                guard try LocalRemoteStamp.optional(URL(fileURLWithPath: mapping.destination)) == conflict.local else { throw RemoteTransferError.conflict(mapping.destination) }
            } else {
                guard try provider.stat(path: mapping.destination, cancellation: cancellation) == conflict.remote else { throw RemoteTransferError.conflict(mapping.destination) }
            }
            switch decisions[mapping.source] ?? .skip {
            case .skip: break
            case .replace:
                guard conflict.canReplace else { throw RemoteTransferError.unsupported("Заменять можно только обычный файл обычным файлом. Для конфликта типов выберите пропуск или новое имя.") }
                guard conflict.destinationSize >= 0, conflict.destinationSize <= RemoteTransferLimits.maximumBytes - reviewedBytes else {
                    throw RemoteTransferError.unsupported("Суммарный объём заменяемых файлов превышает предел проверки 1 ТиБ.")
                }
                reviewedBytes += conflict.destinationSize
                let hash: String
                if plan.download {
                    hash = try RemoteDigest.hash(URL(fileURLWithPath: mapping.destination), cancellation: cancellation)
                    guard try LocalRemoteStamp(URL(fileURLWithPath: mapping.destination)) == conflict.local else { throw RemoteTransferError.conflict(mapping.destination) }
                } else {
                    guard let entry = conflict.remote else { throw RemoteTransferError.invalidPath }
                    hash = try remoteHash(provider, entry, workspace, cancellation)
                }
                replacements[mapping.source] = DirectoryTransferReplacement(local: conflict.local, remote: conflict.remote, hash: hash)
                skipped.removeAll { $0.source == mapping.source }; copies.append(mapping)
            case .rename(let name):
                _ = try RemotePath.child(name, of: "/")
                let parent = (mapping.destination as NSString).deletingLastPathComponent
                let target = plan.download ? URL(fileURLWithPath: parent).appendingPathComponent(name).path : try RemotePath.child(name, of: parent)
                try newTarget(provider, download: plan.download, target, cancellation)
                skipped.removeAll { $0.source == mapping.source }
                copies.append(RemoteDirectoryMapping(source: mapping.source, destination: target))
            }
            progress(NetworkProgress(path: "Решение конфликта: " + mapping.destination, completedBytes: 0, totalBytes: 0))
        }
        // Reject aliasing between two renamed targets even on a case-sensitive
        // server, keeping plans portable to case-insensitive local destinations.
        var targets = Set<String>()
        for mapping in copies {
            try check(cancellation)
            guard targets.insert(alias(mapping.destination)).inserted else { throw RemoteTransferError.conflict(mapping.destination) }
        }
        return RemoteDirectoryTransferPlan(download: plan.download, policy: plan.policy, roots: plan.roots,
            copies: copies, skipped: skipped, conflicts: plan.conflicts, replacements: replacements,
            fileCount: plan.fileCount, directoryCount: plan.directoryCount, totalBytes: plan.totalBytes,
            transferBytes: bytesForCopies(plan.nodes, copies), providerID: plan.providerID, connection: plan.connection,
            nodes: plan.nodes, remoteParents: plan.remoteParents, localParents: plan.localParents)
    }

    @discardableResult public static func move(provider: RemoteProvider, plan: RemoteDirectoryTransferPlan,
                                              cancellation: TransferCancellation = TransferCancellation(),
                                              progress: @escaping (NetworkProgress) -> Void = { _ in }) throws -> RemoteDirectoryTransferReport {
        try copy(provider: provider, plan: plan, move: true, cancellation: cancellation, progress: progress)
    }

    private static func alias(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func newTarget(_ provider: RemoteProvider, download: Bool, _ path: String, _ token: TransferCancellation) throws {
        try check(token)
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        let names: [String]
        if download {
            guard try LocalRemoteStamp.optional(URL(fileURLWithPath: path)) == nil else { throw RemoteTransferError.conflict(path) }
            names = try localListing(URL(fileURLWithPath: parent)).map(\.lastPathComponent)
        } else {
            guard try provider.stat(path: path, cancellation: token) == nil else { throw RemoteTransferError.conflict(path) }
            names = try listing(provider, parent, token).map(\.name)
        }
        guard !names.contains(where: { alias($0) == alias(name) }) else { throw RemoteTransferError.conflict(path) }
    }

    private static func verifyTarget(_ provider: RemoteProvider, _ plan: RemoteDirectoryTransferPlan,
                                     _ mapping: RemoteDirectoryMapping, _ token: TransferCancellation) throws {
        try check(token)
        if let replacement = plan.replacements[mapping.source] {
            if plan.download {
                let target = URL(fileURLWithPath: mapping.destination)
                guard try LocalRemoteStamp.optional(target) == replacement.local,
                      try RemoteDigest.hash(target, cancellation: token) == replacement.hash else { throw RemoteTransferError.conflict(mapping.destination) }
            } else {
                guard let expected = replacement.remote,
                      try provider.stat(path: mapping.destination, cancellation: token) == expected else { throw RemoteTransferError.conflict(mapping.destination) }
                let workspace = try RemoteWorkspace()
                guard try remoteHash(provider, expected, workspace, token) == replacement.hash else { throw RemoteTransferError.conflict(mapping.destination) }
            }
        } else { try newTarget(provider, download: plan.download, mapping.destination, token) }
    }

    /// Every readback is bounded and checked on both sides; metadata alone is
    /// never proof of identical bytes (FTP timestamps can be coarse or absent).
    private static func remoteHash(_ provider: RemoteProvider, _ entry: RemoteEntry,
                                   _ workspace: RemoteWorkspace, _ token: TransferCancellation) throws -> String {
        guard !entry.isDirectory, !entry.isSymbolicLink, entry.size >= 0,
              entry.size <= RemoteTransferLimits.maximumBytes,
              let bounded = provider as? RemoteBoundedDownloadProvider else { throw RemoteTransferError.invalidPath }
        guard try provider.stat(path: entry.path, cancellation: token) == entry else { throw RemoteTransferError.conflict(entry.path) }
        let file = workspace.directory.appendingPathComponent("readback-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
        let identity = try LocalRemoteStamp(file)
        try bounded.boundedDownload(path: entry.path, to: file, maximumBytes: entry.size, cancellation: token, progress: { _ in })
        let actual = try LocalRemoteStamp(file)
        guard actual.sameObject(identity), !actual.directory, !actual.link, actual.size == entry.size,
              try provider.stat(path: entry.path, cancellation: token) == entry else { throw RemoteTransferError.conflict(entry.path) }
        return try RemoteDigest.hash(file, cancellation: token)
    }

    private static func verifyPublished(_ provider: RemoteProvider, _ download: Bool, _ frozen: URL,
                                        _ destination: String, _ token: TransferCancellation) throws {
        try check(token)
        let source = try LocalRemoteStamp(frozen)
        if download {
            let target = URL(fileURLWithPath: destination)
            var parents: [String: LocalRemoteStamp] = [:]
            try localAncestors(target, includeSelf: false, into: &parents)
            let actual = try LocalRemoteStamp(target)
            guard !actual.link, actual.directory == source.directory else { throw RemoteTransferError.conflict(destination) }
            if source.directory {
                let children = try localListing(frozen)
                guard try localListing(target).map(\.lastPathComponent) == children.map(\.lastPathComponent) else { throw RemoteTransferError.conflict(destination) }
                for child in children { try verifyPublished(provider, download, child, target.appendingPathComponent(child.lastPathComponent).path, token) }
            } else {
                guard actual.size == source.size,
                      try RemoteDigest.hash(target, cancellation: token) == RemoteDigest.hash(frozen, cancellation: token) else { throw RemoteTransferError.conflict(destination) }
            }
        } else {
            var parents: [String: RemoteEntry] = [:]
            try remoteAncestors(provider, destination, into: &parents, token)
            guard let actual = try provider.stat(path: destination, cancellation: token), !actual.isSymbolicLink,
                  actual.isDirectory == source.directory else { throw RemoteTransferError.conflict(destination) }
            if source.directory {
                let children = try localListing(frozen)
                guard try listing(provider, destination, token).map(\.name) == children.map(\.lastPathComponent) else { throw RemoteTransferError.conflict(destination) }
                for child in children { try verifyPublished(provider, download, child, RemotePath.child(child.lastPathComponent, of: destination), token) }
            } else {
                let workspace = try RemoteWorkspace()
                guard actual.size == source.size,
                      try remoteHash(provider, actual, workspace, token) == RemoteDigest.hash(frozen, cancellation: token) else { throw RemoteTransferError.conflict(destination) }
            }
        }
    }

    private static func removeSources(_ provider: RemoteProvider, _ plan: RemoteDirectoryTransferPlan,
                                      _ completed: [RemoteDirectoryMapping], _ frozen: [String: URL],
                                      _ token: TransferCancellation, _ progress: @escaping (NetworkProgress) -> Void,
                                      removed: inout [String], retained: inout [RemoteDirectorySourceRetention]) throws {
        let destinations = Dictionary(uniqueKeysWithValues: completed.map { ($0.source, $0.destination) })
        let nodeByPath = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.source, $0) })
        var removedSet = Set(removed)
        func destination(for source: String) -> String? {
            var ancestor = source
            while ancestor != "/" && !ancestor.isEmpty {
                if let target = destinations[ancestor] { return target + source.dropFirst(ancestor.count) }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return nil
        }
        let rootTargets = Dictionary(uniqueKeysWithValues: plan.roots.map { ($0.source, $0.destination) })
        func isReviewedMergedDirectory(_ source: String) -> Bool {
            var ancestor = source
            while ancestor != "/" && !ancestor.isEmpty {
                if let root = rootTargets[ancestor] {
                    let target = root + source.dropFirst(ancestor.count)
                    if plan.download { return plan.localParents[target] != nil }
                    return plan.remoteParents[target] != nil
                }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return false
        }
        // Children first. A directory is removed only if all original children
        // were acknowledged removed and it is still empty; never recurse here.
        for node in plan.nodes.reversed() {
            try check(token)
            if node.directory {
                guard node.children.allSatisfy({ removedSet.contains($0) }),
                      destination(for: node.source) != nil || isReviewedMergedDirectory(node.source) else { continue }
            } else if destination(for: node.source) == nil { continue }
            progress(NetworkProgress(path: "Удаление источника: " + node.source, completedBytes: 0, totalBytes: 0))
            try check(token)
            var removalAttempted = false
            do {
                guard provider.connection == plan.connection else { throw RemoteTransferError.conflict("Подключение изменилось") }
                try destinationParents(provider, plan, token, sourceMutation: true)
                if node.directory, let snapshot = frozen[node.source], let target = destination(for: node.source) {
                    try verifyPublished(provider, plan.download, snapshot, target, token)
                }
                if plan.download {
                    var parents: [String: RemoteEntry] = [:]
                    try remoteAncestors(provider, node.source, into: &parents, token)
                    if node.directory {
                        guard provider is RemoteNonRecursiveDirectoryRemoval,
                              let current = try provider.stat(path: node.source, cancellation: token), current.isDirectory, !current.isSymbolicLink,
                              try listing(provider, node.source, token).isEmpty else { throw RemoteTransferError.conflict(node.source) }
                    } else {
                        guard let expected = node.remote, let snapshot = frozen[node.source], let target = destination(for: node.source),
                              try provider.stat(path: node.source, cancellation: token) == expected else { throw RemoteTransferError.conflict(node.source) }
                        try verifyPublished(provider, true, snapshot, target, token)
                        let workspace = try RemoteWorkspace()
                        guard try remoteHash(provider, expected, workspace, token) == RemoteDigest.hash(snapshot, cancellation: token),
                              try provider.stat(path: node.source, cancellation: token) == expected else { throw RemoteTransferError.conflict(node.source) }
                        // Source readback may take a long time: make the final
                        // destination check after that network operation.
                        try verifyPublished(provider, true, snapshot, target, token)
                    }
                    try check(token)
                    removalAttempted = true
                    try provider.remove(path: node.source, isDirectory: node.directory, cancellation: token)
                } else {
                    let source = URL(fileURLWithPath: node.source)
                    var parents: [String: LocalRemoteStamp] = [:]
                    try localAncestors(source, includeSelf: false, into: &parents)
                    for (path, current) in parents {
                        let expected = nodeByPath[path]?.local ?? plan.localParents[path]
                        if let expected { guard current.sameObject(expected), current.directory, !current.link else { throw RemoteTransferError.conflict(path) } }
                    }
                    guard let original = node.local else { throw RemoteTransferError.invalidPath }
                    let actual = try LocalRemoteStamp(source)
                    if node.directory {
                        guard actual.sameObject(original), actual.directory, !actual.link,
                              try localListing(source).isEmpty else { throw RemoteTransferError.conflict(node.source) }
                    } else {
                        guard actual == original, let snapshot = frozen[node.source], let target = destination(for: node.source),
                              try RemoteDigest.hash(source, cancellation: token) == node.hash else { throw RemoteTransferError.conflict(node.source) }
                        try verifyPublished(provider, false, snapshot, target, token)
                        guard try LocalRemoteStamp(source) == original else { throw RemoteTransferError.conflict(node.source) }
                    }
                    try check(token)
                    // Descriptor-relative unlink cannot follow a substituted
                    // source parent or turn an empty-folder removal recursive.
                    let parent = source.deletingLastPathComponent()
                    guard let expectedParent = parents[parent.path] else { throw RemoteTransferError.invalidPath }
                    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    defer { close(fd) }
                    var info = stat()
                    guard fstat(fd, &info) == 0, info.st_dev == expectedParent.device, info.st_ino == expectedParent.inode,
                          try LocalRemoteStamp(source) == actual else { throw RemoteTransferError.conflict(node.source) }
                    guard unlinkat(fd, source.lastPathComponent, node.directory ? AT_REMOVEDIR : 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                }
                removed.append(node.source); removedSet.insert(node.source)
                progress(NetworkProgress(path: "Удалено источников \(removed.count): " + node.source, completedBytes: 0, totalBytes: 0))
            } catch {
                let unknown = plan.download && removalAttempted
                retained.append(RemoteDirectorySourceRetention(source: node.source, reason: error.localizedDescription +
                    (unknown ? " Ответ на удаление мог быть потерян; исходник мог уже исчезнуть. Обновите панели перед повтором." : ""),
                    outcomeUnknown: unknown))
                if token.isCancelled { throw RemoteTransferError.cancelled }
            }
        }
    }

    private static func verify(_ provider: RemoteProvider, _ plan: RemoteDirectoryTransferPlan, _ token: TransferCancellation) throws {
        try check(token)
        guard plan.providerID == ObjectIdentifier(provider), plan.connection == provider.connection else { throw RemoteTransferError.conflict("Подключение изменилось") }
        try destinationParents(provider, plan, token)
        for node in plan.nodes {
            try check(token)
            if plan.download {
                guard try provider.stat(path: node.source, cancellation: token) == node.remote,
                      try (!node.directory || listing(provider, node.source, token).map(\.path) == node.children) else { throw RemoteTransferError.conflict(node.source) }
            } else {
                let source = URL(fileURLWithPath: node.source)
                guard try LocalRemoteStamp(source) == node.local,
                      node.directory ? (try localListing(source)).map(\.path) == node.children : (try RemoteDigest.hash(source, cancellation: token)) == node.hash else { throw RemoteTransferError.conflict(node.source) }
            }
        }
        for mapping in plan.copies { try verifyTarget(provider, plan, mapping, token) }
    }

    private static func destinationParents(_ provider: RemoteProvider, _ plan: RemoteDirectoryTransferPlan, _ token: TransferCancellation,
                                           sourceMutation: Bool = false) throws {
        try check(token)
        for (path, expected) in plan.localParents {
            let current = try LocalRemoteStamp(URL(fileURLWithPath: path))
            // Publishing children changes timestamps; the parent identity and
            // directory type must remain the same throughout a merge.
            guard current.directory, !current.link, current.sameObject(expected) else { throw RemoteTransferError.conflict(path) }
        }
        for (path, expected) in plan.remoteParents {
            guard let current = try provider.stat(path: path, cancellation: token), current.path == path,
                  current.isDirectory, !current.isSymbolicLink else { throw RemoteTransferError.conflict(path) }
            // Remote protocols expose no portable directory identity token.
            // Source-directory snapshots are checked separately and completely.
            if plan.download && !sourceMutation { guard current == expected else { throw RemoteTransferError.conflict(path) } }
        }
    }

    private static func publishLocal(_ source: URL, to destination: URL, parents: [String: LocalRemoteStamp],
                                     replacement: DirectoryTransferReplacement?, _ token: TransferCancellation) throws {
        let parent = destination.deletingLastPathComponent()
        guard let expected = parents[parent.path] else { throw RemoteTransferError.invalidPath }
        let workspace = try RemoteWorkspace(parent: parent)
        let stage = workspace.directory.appendingPathComponent("copy")
        // A same-volume private stage makes the final rename atomic and exclusive.
        // FileManager copy is bounded by the already frozen, validated snapshot.
        try clone(source, to: stage, token)
        try check(token)
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == expected.device, info.st_ino == expected.inode,
              try LocalRemoteStamp(parent).sameObject(expected) else { throw RemoteTransferError.conflict(parent.path) }
        try check(token)
        let stageFD = open(workspace.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(stageFD) }
        if let replacement {
            guard try LocalRemoteStamp.optional(destination) == replacement.local,
                  try RemoteDigest.hash(destination, cancellation: token) == replacement.hash else { throw RemoteTransferError.conflict(destination.path) }
        }
        let flags: UInt32 = replacement == nil ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(stageFD, "copy", fd, destination.lastPathComponent, flags) == 0 else {
            if errno == EEXIST || errno == ENOTEMPTY { throw RemoteTransferError.conflict(destination.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Chunked private copies remain cancellable for large files and never
    /// follow a substituted source symlink. Verify every file before publishing.
    private static func clone(_ source: URL, to target: URL, _ token: TransferCancellation) throws {
        try check(token)
        let before = try LocalRemoteStamp(source)
        guard !before.link else { throw RemoteTransferError.conflict(source.path) }
        if before.directory {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let children = try localListing(source)
            for child in children { try clone(child, to: target.appendingPathComponent(child.lastPathComponent), token) }
            guard try localListing(source) == children else { throw RemoteTransferError.conflict(source.path) }
        } else {
            let input = try before.openForReading(source)
            let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
            defer { try? reader.close() }
            let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
            defer { try? writer.close() }
            while true {
                try check(token)
                guard let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
                try writer.write(contentsOf: data)
            }
            try writer.synchronize()
            guard try RemoteDigest.hash(source, cancellation: token) == RemoteDigest.hash(target, cancellation: token) else {
                throw RemoteTransferError.verification("Проверка локальной копии не пройдена: «\(source.path)».")
            }
        }
        guard try LocalRemoteStamp(source) == before else { throw RemoteTransferError.conflict(source.path) }
    }

    private static func selection(_ sources: [String], remote: Bool) throws {
        guard !sources.isEmpty, sources.count <= RemoteTransferLimits.maximumEntries else { throw RemoteTransferError.invalidPath }
        var seen = Set<String>(), names = Set<String>()
        for source in sources {
            if remote { try remotePath(source) }
            guard source != "/", seen.insert(source).inserted,
                  names.insert((source as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted else { throw RemoteTransferError.invalidPath }
        }
        for source in sources {
            var parent = (source as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                guard !seen.contains(parent) else { throw RemoteTransferError.invalidPath }
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }
    private static func remotePath(_ path: String) throws {
        guard try RemotePath.validate(path) == path else { throw RemoteTransferError.invalidPath }
    }
    private static func listing(_ provider: RemoteProvider, _ path: String, _ token: TransferCancellation) throws -> [RemoteEntry] {
        try check(token)
        let values = try provider.list(path: path, cancellation: token)
        guard values.count <= RemoteTransferLimits.maximumEntries else { throw RemoteTransferError.unsupported("Превышен предел дерева 100000 объектов.") }
        var seen = Set<String>(), aliases = Set<String>()
        for entry in values {
            try remotePath(entry.path)
            guard entry.path != path, RemotePath.parent(entry.path) == path,
                  seen.insert(entry.path).inserted else { throw RemoteTransferError.invalidPath }
            let alias = entry.name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard aliases.insert(alias).inserted else { throw RemoteTransferError.unsupported("Имена сетевой папки совпадают без учёта регистра или формы Unicode; дерево не копируется: «\(path)».") }
        }
        return values.sorted { $0.path < $1.path }
    }
    private static func localListing(_ url: URL) throws -> [URL] {
        let values = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        guard values.count <= RemoteTransferLimits.maximumEntries else { throw RemoteTransferError.unsupported("Превышен предел дерева 100000 объектов.") }
        var names = Set<String>()
        for value in values {
            _ = try RemotePath.child(value.lastPathComponent, of: "/")
            guard names.insert(alias(value.lastPathComponent)).inserted else { throw RemoteTransferError.conflict(url.path) }
        }
        return values.sorted { $0.path < $1.path }
    }
    /// macOS exposes these two system aliases in temporary-directory URLs.
    /// Normalize only those fixed aliases; user-selected links remain refused.
    private static func systemAliases(_ url: URL) -> URL {
        for alias in ["/var", "/tmp"] where url.path == alias || url.path.hasPrefix(alias + "/") {
            let root = URL(fileURLWithPath: alias)
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: root.path),
               link == "private" + alias || link == "/private" + alias {
                return URL(fileURLWithPath: "/private" + url.path)
            }
        }
        return url
    }
    private static func localAncestors(_ url: URL, includeSelf: Bool, into values: inout [String: LocalRemoteStamp]) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw RemoteTransferError.invalidPath }
        var current = includeSelf ? url : url.deletingLastPathComponent()
        while true {
            let stamp = try LocalRemoteStamp(current)
            guard stamp.directory, !stamp.link else { throw RemoteTransferError.conflict(current.path) }
            values[current.path] = stamp
            if current.path == "/" { return }; current.deleteLastPathComponent()
        }
    }
    private static func remoteAncestors(_ provider: RemoteProvider, _ path: String, into values: inout [String: RemoteEntry], _ token: TransferCancellation) throws {
        var current = RemotePath.parent(path)
        while true {
            try check(token)
            guard let entry = try provider.stat(path: current, cancellation: token), entry.path == current,
                  entry.isDirectory, !entry.isSymbolicLink else { throw RemoteTransferError.conflict(current) }
            values[current] = entry
            if current == "/" { return }; current = RemotePath.parent(current)
        }
    }
    private static func plan(_ download: Bool, _ policy: RemoteDirectoryConflictPolicy, _ roots: [RemoteDirectoryMapping],
                             _ copies: [RemoteDirectoryMapping], _ skipped: [RemoteDirectoryMapping], _ conflicts: [RemoteDirectoryConflict], _ nodes: [DirectoryTransferNode],
                             _ provider: RemoteProvider, _ connection: NetworkConnection, _ remote: [String: RemoteEntry],
                             _ local: [String: LocalRemoteStamp], _ budget: Budget) -> RemoteDirectoryTransferPlan {
        RemoteDirectoryTransferPlan(download: download, policy: policy, roots: roots, copies: copies, skipped: skipped,
                                    conflicts: conflicts, replacements: [:], fileCount: nodes.filter { !$0.directory }.count, directoryCount: nodes.filter(\.directory).count,
                                    totalBytes: budget.bytes, transferBytes: bytesForCopies(nodes, copies), providerID: ObjectIdentifier(provider), connection: connection,
                                    nodes: nodes, remoteParents: remote, localParents: local)
    }
    private static func bytesForCopies(_ nodes: [DirectoryTransferNode], _ copies: [RemoteDirectoryMapping]) -> Int64 {
        let roots = Set(copies.map(\.source))
        var bytes: Int64 = 0
        for node in nodes where !node.directory {
            var path = node.source
            while path != "/" && !path.isEmpty {
                if roots.contains(path) { bytes += node.size; break }
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return bytes
    }
    private struct Budget {
        var count = 0, discovered = 0
        var bytes: Int64 = 0
        mutating func discover(_ size: Int) throws {
            guard size <= RemoteTransferLimits.maximumEntries - discovered else { throw RemoteTransferError.unsupported("Превышен предел дерева 100000 объектов.") }
            discovered += size
        }
        mutating func admit(directory: Bool, size: Int64, depth: Int) throws {
            guard depth <= RemoteTransferLimits.maximumDepth, count < RemoteTransferLimits.maximumEntries,
                  size >= 0, directory || size <= RemoteTransferLimits.maximumBytes - bytes else { throw RemoteTransferError.unsupported("Предел дерева: 128 уровней, 100000 объектов, 1 ТиБ.") }
            count += 1; if !directory { bytes += size }
        }
    }
    private static func check(_ token: TransferCancellation) throws { if token.isCancelled { throw RemoteTransferError.cancelled } }
}
