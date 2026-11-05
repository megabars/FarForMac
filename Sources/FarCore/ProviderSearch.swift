import Foundation

/// A provider must enforce this ceiling before writing received bytes. Search never
/// falls back to an unbounded RemoteProvider download, even when stat reports a small file.
public protocol RemoteSearchDownloadProvider: RemoteProvider {
    func searchDownload(path: String, to: URL, maximumBytes: Int64,
                        cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws
}

public struct ProviderSearchLimits: Sendable {
    public var maximumDepth: Int
    public var maximumEntries: Int
    public var maximumTotalContentBytes: Int64
    public init(maximumDepth: Int = 128, maximumEntries: Int = 100_000,
                maximumTotalContentBytes: Int64 = 256 * 1024 * 1024) {
        self.maximumDepth = maximumDepth; self.maximumEntries = maximumEntries
        self.maximumTotalContentBytes = maximumTotalContentBytes
    }
    public static let `default` = ProviderSearchLimits()
}

/// Cancellation also interrupts the current provider operation, including extraction
/// and native network I/O. A cancelled instance must not be reused for a new search.
public final class ProviderSearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let search: SearchCancellation
    private var active: [TransferCancellation] = []
    public init() { search = SearchCancellation() }
    init(search: SearchCancellation) { self.search = search }
    public var isCancelled: Bool { search.isCancelled }
    public func cancel() {
        lock.lock(); search.cancel(); active.forEach { $0.cancel() }; lock.unlock()
    }
    var contentCancellation: SearchCancellation { search }
    public func transfer<T>(_ body: (TransferCancellation) throws -> T) throws -> T {
        let token = TransferCancellation()
        lock.lock(); active.append(token); if isCancelled { token.cancel() }; lock.unlock()
        defer { lock.lock(); active.removeAll { $0 === token }; lock.unlock() }
        if token.isCancelled { throw ViewerError.cancelled }
        return try body(token)
    }
}

public struct ProviderSearchResult: Identifiable, Sendable {
    public let archiveEntry: ArchiveEntry?
    public let remoteEntry: RemoteEntry?
    public let archiveURL: URL?
    public let connectionID: UUID?
    public let snippet: String?
    public let lineNumber: Int?
    public let byteOffset: Int64?
    let archiveSnapshot: ArchiveSnapshot?
    let capturedConnection: NetworkConnection?
    public var capturedArchiveSnapshot: ArchiveSnapshot? { archiveSnapshot }
    /// The outer archive and nested archive chain, without the result member path.
    public var archiveDisplayPath: String? { archiveSnapshot.map { ArchiveNavigationFrame(snapshot: $0).displayPath } }
    public var path: String { archiveEntry?.path ?? remoteEntry!.path }
    public var name: String { archiveEntry?.name ?? remoteEntry!.name }
    public var isDirectory: Bool { archiveEntry?.isDirectory ?? remoteEntry!.isDirectory }
    public var isSymbolicLink: Bool { remoteEntry?.isSymbolicLink ?? false }
    public var size: Int64 { archiveEntry?.size ?? remoteEntry!.size }
    public var modified: Date? { archiveEntry?.modificationDate ?? remoteEntry?.modified }
    public var id: String {
        if let archiveSnapshot { return "archive:" + archiveSnapshot.searchIdentity + "|" + String(path.utf8.count) + ":" + path }
        return "remote:" + (capturedConnection.map(searchConnectionIdentity) ?? connectionID!.uuidString) + "|" + path
    }
    public func verifyArchiveCurrent(snapshot: ArchiveSnapshot) throws {
        guard archiveURL == snapshot.sourceURL, let archiveEntry,
              snapshot.entries.contains(archiveEntry) || (archiveEntry.isDirectory && snapshot.entries.contains(where: { $0.path.hasPrefix(archiveEntry.path + "/") })) else { throw ArchiveError.changedArchive }
        guard let archiveSnapshot else { throw ArchiveError.changedArchive }
        try archiveSnapshot.verifyCurrent()
        try snapshot.verifyCurrent()
    }
    public func verifyRemoteCurrent(provider: RemoteProvider,
                                    cancellation: TransferCancellation = TransferCancellation()) throws {
        guard capturedConnection == provider.connection, let remoteEntry,
              try provider.stat(path: path, cancellation: cancellation) == remoteEntry,
              capturedConnection == provider.connection else { throw NetworkError.changedSource }
    }
}

public enum ProviderSearchEvent: Sendable {
    case result(ProviderSearchResult)
    case issue(SearchIssue)
    case progress(SearchProgress)
}

/// Synchronous incremental workers; call away from the UI thread. SearchOptions.roots
/// is replaced by the explicitly supplied provider scope. Links are never followed.
/// Content is scanned in private, bounded working copies and deleted before returning.
public enum ProviderSearchEngine {
    public static func validate(_ request: SearchRequest) throws { _ = try ProviderSearchPlan(request) }
    public static func runArchive(_ snapshot: ArchiveSnapshot, prefix: String = "", request: SearchRequest,
                                  password: String? = nil, limits: ArchiveSearchLimits = .default,
                                  cancellation: ProviderSearchCancellation,
                                  onEvent: @escaping (ProviderSearchEvent) -> Void) -> SearchSummary {
        let state = ProviderSearchState(cancellation, onEvent)
        do {
            let worker = try ArchiveSearchWorker(request: request, limits: limits, cancellation: cancellation,
                shouldStop: { state.stopped }, visit: { state.visit($0) },
                result: { state.emit($0, maximum: request.options.maximumResults) },
                issue: { state.issue($0, $1) }, progress: { state.progress() })
            worker.search(snapshot, prefix: prefix, password: password)
            state.limitReached = state.limitReached || worker.limitReached
        } catch { if !cancellation.isCancelled { state.issue(snapshot.sourceURL.path, error) } }
        return state.summary()
    }

    public static func runRemote(provider: RemoteProvider, root: String, request: SearchRequest,
                                 limits: ProviderSearchLimits = .default, cancellation: ProviderSearchCancellation,
                                 onEvent: @escaping (ProviderSearchEvent) -> Void) -> SearchSummary {
        runRemoteShared(provider: provider, root: root, request: request, limits: limits,
            cancellation: cancellation, onEvent: onEvent)
    }
    static func runRemoteShared(provider: RemoteProvider, root: String, request: SearchRequest,
                               limits: ProviderSearchLimits, cancellation: ProviderSearchCancellation,
                               budget sharedBudget: RemoteSearchBudget? = nil,
                               shouldStop: @escaping () -> Bool = { false },
                               onEvent: @escaping (ProviderSearchEvent) -> Void) -> SearchSummary {
        let state = ProviderSearchState(cancellation, onEvent, shouldStop: shouldStop)
        do {
            let plan = try ProviderSearchPlan(request)
            let budget = try sharedBudget ?? RemoteSearchBudget(limits)
            let clean = try RemotePath.validate(root)
            let connection = provider.connection
            try connection.validate()
            guard budget.discovered < limits.maximumEntries else {
                state.limit(root, "Достигнут общий предел сетевых элементов."); budget.limitReached = true
                return state.summary()
            }
            budget.discovered += 1
            func required(_ path: String, expected: RemoteEntry? = nil) throws -> RemoteEntry {
                guard provider.connection == connection else { throw NetworkError.changedSource }
                let value = try cancellation.transfer { try provider.stat(path: path, cancellation: $0) }
                guard provider.connection == connection, let value, value.path == path, value.size >= 0, expected == nil || value == expected else { throw NetworkError.changedSource }
                return value
            }
            func visit(_ entry: RemoteEntry, depth: Int, isRoot: Bool = false) {
                if state.stopped { return }
                if !isRoot && !plan.options.includeHidden && entry.name.hasPrefix(".") { return }
                guard budget.scanned < limits.maximumEntries else { state.limit(entry.path, "Достигнут предел числа сетевых элементов."); budget.limitReached = true; return }
                budget.scanned += 1
                state.visit(entry.path)
                if state.stopped { return }
                do {
                    if !(isRoot && entry.isDirectory && !entry.isSymbolicLink), try plan.matches(name: entry.name,
                        kind: entry.isSymbolicLink ? .symbolicLink : (entry.isDirectory ? .directory : .file),
                        size: entry.size, modified: entry.modified) {
                        var match: SearchContentMatch?
                        if plan.hasContent {
                            if !entry.isDirectory && !entry.isSymbolicLink {
                                try plan.checkContentSize(entry.size)
                                guard entry.size <= limits.maximumTotalContentBytes - budget.contentBytes else {
                                    budget.limitReached = true
                                    state.limit(entry.path, "Содержимое пропущено: исчерпан общий предел загрузки поиска."); return
                                }
                                guard let bounded = provider as? RemoteSearchDownloadProvider else {
                                    throw ProviderSearchFailure("Провайдер не поддерживает ограниченную загрузку для поиска содержимого.")
                                }
                                _ = try required(entry.path, expected: entry)
                                let workspace = try RemoteWorkspace()
                                defer { workspace.cleanup() }
                                let local = workspace.directory.appendingPathComponent("content")
                                budget.contentBytes += entry.size // reserve failed downloads too
                                try cancellation.transfer { token in
                                    try bounded.searchDownload(path: entry.path, to: local, maximumBytes: entry.size,
                                        cancellation: token, progress: { _ in state.progress() })
                                }
                                _ = try required(entry.path, expected: entry)
                                let source = try LocalViewerSource(url: local)
                                guard source.size == entry.size else { throw NetworkError.changedSource }
                                match = try plan.scan(source, cancellation)
                                _ = try required(entry.path, expected: entry)
                            }
                        }
                        if !state.stopped && (!plan.hasContent || match != nil) {
                            state.emit(ProviderSearchResult(archiveEntry: nil, remoteEntry: entry, archiveURL: nil,
                                connectionID: connection.id, snippet: match?.snippet, lineNumber: match?.line, byteOffset: match?.byteOffset, archiveSnapshot: nil, capturedConnection: connection), maximum: plan.options.maximumResults)
                        }
                    }
                } catch { if !cancellation.isCancelled { state.issue(entry.path, error) } }
                if state.stopped || !entry.isDirectory || entry.isSymbolicLink { return }
                guard depth < limits.maximumDepth else { state.issue(entry.path, ProviderSearchFailure("Каталог пропущен: достигнут предел глубины.")); return }
                do {
                    _ = try required(entry.path, expected: entry)
                    let children = try cancellation.transfer { try provider.list(path: entry.path, cancellation: $0) }
                    _ = try required(entry.path, expected: entry)
                    guard children.count <= limits.maximumEntries - budget.discovered else {
                        state.limit(entry.path, "Список каталога превышает оставшийся предел элементов."); budget.limitReached = true; return
                    }
                    budget.discovered += children.count
                    var seen = Set<String>()
                    for child in children {
                        if state.stopped { break }
                        do {
                            let safe = try RemotePath.validate(child.path)
                            guard safe == child.path, RemotePath.parent(safe) == entry.path,
                                  safe != entry.path, child.size >= 0, seen.insert(safe).inserted else {
                                throw NetworkError.invalidPath(child.path)
                            }
                            // Parent equality confines traversal to one direct child: escaped,
                            // parent and ancestor entries cannot create cycles or leave root.
                            visit(child, depth: depth + 1)
                        } catch { if !cancellation.isCancelled { state.issue(child.path, error) } }
                    }
                } catch { if !cancellation.isCancelled { state.issue(entry.path, error) } }
            }
            let first = try required(clean)
            visit(first, depth: 0, isRoot: true)
        } catch { if !cancellation.isCancelled { state.issue(root, error) } }
        return state.summary()
    }
}

struct ProviderSearchFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
struct ProviderSearchPlan {
    let options: SearchOptions
    let mask: FileMask
    let expression: NSRegularExpression?
    let bytes: [UInt8]?
    var hasContent: Bool { expression != nil || bytes != nil }
    init(_ request: SearchRequest) throws {
        var options = request.options
        options.roots = [URL(fileURLWithPath: "/")]
        try SearchEngine.validate(SearchRequest(options: options, maskGroups: request.maskGroups))
        guard options.maximumContentBytes <= 64 * 1024 * 1024 else {
            throw ProviderSearchFailure("Поиск в провайдерах: предел содержимого не более 64 МиБ.")
        }
        self.options = options
        mask = try FileMask(options.namePattern, groups: request.maskGroups)
        bytes = options.contentMode == .hex ? try SearchContentScanner.hexBytes(options.contentQuery) : nil
        expression = options.contentMode == .none || options.contentMode == .hex ? nil : try NSRegularExpression(
            pattern: options.contentMode == .literal ? NSRegularExpression.escapedPattern(for: options.contentQuery) : options.contentQuery,
            options: options.caseSensitive ? [] : [.caseInsensitive])
    }
    func matches(name: String, kind: SearchFileKind, size: Int64, modified: Date?) throws -> Bool {
        guard options.kinds.contains(kind), size >= 0,
              options.minSize.map({ size >= $0 }) ?? true, options.maxSize.map({ size <= $0 }) ?? true,
              options.modifiedAfter.map({ bound in modified.map { $0 >= bound } ?? false }) ?? true,
              options.modifiedBefore.map({ bound in modified.map { $0 <= bound } ?? false }) ?? true else { return false }
        return try mask.matchesChecked(name)
    }
    func checkContentSize(_ size: Int64) throws {
        guard size >= 0, size <= Int64(options.maximumContentBytes) else {
            throw ProviderSearchFailure("Содержимое пропущено: превышен предел \(options.maximumContentBytes) байт.")
        }
    }
    func scan(_ url: URL, _ cancellation: ProviderSearchCancellation) throws -> SearchContentMatch? {
        try scan(LocalViewerSource(url: url), cancellation)
    }
    func scan(_ source: LocalViewerSource, _ cancellation: ProviderSearchCancellation) throws -> SearchContentMatch? {
        try checkContentSize(source.size)
        if let bytes {
            return try SearchContentScanner.scanBytes(source: SearchContentScanner.prefix(source, firstBytes: options.firstContentBytes),
                query: bytes, cancellation: cancellation.contentCancellation)
        }
        guard let expression else { return nil }
        return try SearchContentScanner.scan(document: SearchContentScanner.document(source, encoding: options.contentEncoding ?? .utf8,
                firstBytes: options.firstContentBytes),
            expression: expression, literal: options.contentMode == .literal, queryLength: options.contentQuery.utf16.count,
            cancellation: cancellation.contentCancellation)
    }
}
private final class ProviderSearchState {
    let cancellation: ProviderSearchCancellation
    let onEvent: (ProviderSearchEvent) -> Void
    var scanned = 0, matches = 0, errors = 0
    var limitReached = false
    var currentPath = ""
    let shouldStop: () -> Bool
    var stopped: Bool { cancellation.isCancelled || limitReached || shouldStop() }
    init(_ cancellation: ProviderSearchCancellation, _ onEvent: @escaping (ProviderSearchEvent) -> Void,
         shouldStop: @escaping () -> Bool = { false }) {
        self.cancellation = cancellation; self.onEvent = onEvent; self.shouldStop = shouldStop
    }
    func visit(_ path: String) { scanned += 1; currentPath = path; progress() }
    func progress() { onEvent(.progress(SearchProgress(scanned: scanned, matches: matches, errors: errors, currentPath: currentPath))) }
    func issue(_ path: String, _ error: Error) { errors += 1; onEvent(.issue(SearchIssue(path: path, message: error.localizedDescription))) }
    func limit(_ path: String, _ message: String) { limitReached = true; issue(path, ProviderSearchFailure(message)) }
    func emit(_ result: ProviderSearchResult, maximum: Int) {
        matches += 1; onEvent(.result(result)); if matches >= maximum { limitReached = true }
    }
    func summary() -> SearchSummary {
        progress()
        return SearchSummary(scanned: scanned, matches: matches, errors: errors, cancelled: cancellation.isCancelled, limitReached: limitReached)
    }
}

/// Shared reservations include roots, pending directory listings and failed downloads.
final class RemoteSearchBudget {
    var discovered = 0, scanned = 0
    var contentBytes: Int64 = 0
    var limitReached = false
    init(_ limits: ProviderSearchLimits) throws {
        guard (1...128).contains(limits.maximumDepth), (1...100_000).contains(limits.maximumEntries),
              (1...Int64(1024 * 1024 * 1024)).contains(limits.maximumTotalContentBytes) else {
            throw ProviderSearchFailure("Недопустимые пределы сетевого поиска.")
        }
    }
}

/// Complete configuration distinguishes profiles that reuse a UUID at another endpoint.
/// This value is only an in-memory identity; no provider, password or result is persisted.
func searchConnectionIdentity(_ connection: NetworkConnection) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(connection).base64EncodedString()) ?? connection.id.uuidString
}
