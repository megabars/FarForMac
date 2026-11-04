import Foundation

/// Runtime search scopes. Providers and archive contexts are deliberately not Codable.
public enum SearchLocation: @unchecked Sendable {
    case local(URL)
    case archive(ArchiveSnapshot, prefix: String)
    case remote(any RemoteProvider, root: String)

    public var id: String {
        switch self {
        case .local(let url): return "local:" + Self.localKey(url)
        case .archive(let snapshot, let prefix): return "archive:" + snapshot.searchIdentity + "|" + prefix
        case .remote(let provider, let root): return "remote:" + searchConnectionIdentity(provider.connection) + "|" + root
        }
    }
    public var displayPath: String {
        switch self {
        case .local(let url): return url.path
        case .archive(let snapshot, let prefix):
            return ArchiveNavigationFrame(snapshot: snapshot).displayPath + (prefix.isEmpty ? "" : " !/" + prefix)
        case .remote(let provider, let root): return Self.remoteDisplay(provider.connection, root)
        }
    }
    static func localKey(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }
    static func remoteDisplay(_ connection: NetworkConnection, _ path: String) -> String {
        let user = connection.username.isEmpty ? "" : connection.username + "@"
        return "\(connection.kind.rawValue)://\(user)\(connection.host):\(connection.port)\(path)"
    }
}

/// A typed reference to the original source, never to a disposable search working copy.
public enum SearchMatch: Identifiable, @unchecked Sendable {
    case local(SearchResult)
    case saved(SavedSearchReference)
    case archive(ProviderSearchResult)
    case remote(ProviderSearchResult, any RemoteProvider)

    public var id: String {
        switch self {
        case .saved(let value): return value.id
        case .local(let value): return "local:" + value.searchIdentityPath
        case .archive(let value), .remote(let value, _): return value.id
        }
    }
    public var name: String {
        switch self { case .saved(let value): return value.name
        case .local(let value): return value.name
        case .archive(let value), .remote(let value, _): return value.name }
    }
    public var displayPath: String {
        switch self {
        case .saved(let value): return value.displayPath
        case .local(let value): return value.url.path
        case .archive(let value): return (value.archiveDisplayPath ?? value.archiveURL?.path ?? "") + " !/" + value.path
        case .remote(let value, let provider):
            return SearchLocation.remoteDisplay(value.capturedConnection ?? provider.connection, value.path)
        }
    }
    public var isDirectory: Bool {
        switch self { case .saved(let value): return value.isDirectory
        case .local(let value): return value.isDirectory
        case .archive(let value), .remote(let value, _): return value.isDirectory }
    }
    public var isSymbolicLink: Bool {
        switch self { case .saved(let value): return value.isSymbolicLink
        case .local(let value): return value.isSymbolicLink
        case .archive(let value), .remote(let value, _): return value.isSymbolicLink }
    }
    public var size: Int64 {
        switch self { case .saved(let value): return value.size
        case .local(let value): return value.size
        case .archive(let value), .remote(let value, _): return value.size }
    }
    public var modified: Date? {
        switch self { case .saved(let value): return value.modified
        case .local(let value): return value.modified
        case .archive(let value), .remote(let value, _): return value.modified }
    }
    public var snippet: String? {
        switch self { case .saved(let value): return value.snippet
        case .local(let value): return value.snippet
        case .archive(let value), .remote(let value, _): return value.snippet }
    }
    public var lineNumber: Int? {
        switch self { case .saved(let value): return value.lineNumber
        case .local(let value): return value.lineNumber
        case .archive(let value), .remote(let value, _): return value.lineNumber }
    }
    public var byteOffset: Int64? {
        switch self { case .saved(let value): return value.byteOffset
        case .local(let value): return value.byteOffset
        case .archive(let value), .remote(let value, _): return value.byteOffset }
    }
    public var canEdit: Bool {
        guard !isDirectory, !isSymbolicLink else { return false }
        if case .saved(let reference) = self { return reference.canEdit }
        if case .archive(let value) = self { return value.capturedArchiveSnapshot.map { !$0.isReadOnly } ?? false }
        return true
    }
    public func verifyCurrent(cancellation: ProviderSearchCancellation = ProviderSearchCancellation()) throws {
        guard !cancellation.isCancelled else { throw ViewerError.cancelled }
        switch self {
        case .saved: throw PanelSessionError("Сохранённый результат требует восстановления исходного источника.")
        case .local(let value): try value.verifyCurrent()
        case .archive(let value):
            guard let snapshot = value.capturedArchiveSnapshot else { throw ArchiveError.changedArchive }
            try value.verifyArchiveCurrent(snapshot: snapshot)
        case .remote(let value, let provider):
            try cancellation.transfer { try value.verifyRemoteCurrent(provider: provider, cancellation: $0) }
        }
        guard !cancellation.isCancelled else { throw ViewerError.cancelled }
    }
}

/// Session-only temporary results. Duplicate updates retain the first captured stamp.
public struct TemporarySearchCollection: @unchecked Sendable {
    public static let maximumCount = 10_000
    public private(set) var items: [SearchMatch] = []
    public init(_ items: [SearchMatch] = []) { append(items) }
    public mutating func replace(_ values: [SearchMatch]) {
        let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items.removeAll(keepingCapacity: true)
        append(values.map { previous[$0.id] ?? $0 })
    }
    public mutating func append(_ values: [SearchMatch]) {
        var existing = Set(items.map(\.id))
        for value in values {
            guard items.count < Self.maximumCount else { break }
            if existing.insert(value.id).inserted { items.append(value) }
        }
    }
    public mutating func remove(ids: Set<String>) { items.removeAll { ids.contains($0.id) } }
    public mutating func removeAll() { items.removeAll() }
}

public enum MultiSourceSearchEvent: Sendable {
    case match(SearchMatch)
    case issue(SearchIssue)
    case progress(SearchProgress)
}

/// One synchronous streamed search, with shared result, archive and remote budgets.
public enum MultiSourceSearchEngine {
    public static func run(locations: [SearchLocation], request: SearchRequest,
                           archivePasswords: [URL: String] = [:],
                           archiveLimits: ArchiveSearchLimits = .default,
                           remoteLimits: ProviderSearchLimits = .default,
                           cancellation: ProviderSearchCancellation,
                           onEvent: @escaping (MultiSourceSearchEvent) -> Void) -> SearchSummary {
        let state = MultiSearchState(request.options.maximumResults, cancellation, onEvent)
        do {
            guard (1...32).contains(locations.count) else {
                throw ProviderSearchFailure("Выберите от 1 до 32 источников поиска.")
            }
            var validation = request.options; validation.roots = [URL(fileURLWithPath: "/")]
            try SearchEngine.validate(SearchRequest(options: validation, maskGroups: request.maskGroups))
            let archiveBudget = try ArchiveSearchBudget(archiveLimits)
            let remoteBudget = try RemoteSearchBudget(remoteLimits)
            let stop = { state.stopped || archiveBudget.limitReached || remoteBudget.limitReached }
            // Local roots run together, preserving descriptor-based traversal and overlap deduplication.
            var didLocal = false
            let localRoots = locations.compactMap { location -> URL? in
                if case .local(let url) = location { return url }; return nil
            }
            var remoteScopes: [(connection: NetworkConnection, root: String)] = []
            for location in locations {
                if stop() { break }
                let baseline = state.scanned
                switch location {
                case .local:
                    guard !didLocal else { continue }; didLocal = true
                    var options = request.options; options.roots = localRoots
                    _ = SearchEngine.runShared(SearchRequest(options: options, maskGroups: request.maskGroups),
                        archiveLimits: archiveLimits, archiveBudget: archiveBudget,
                        cancellation: cancellation.contentCancellation, providerCancellation: cancellation, shouldStop: stop) { event in
                        switch event {
                        case .result(let value): state.emit(.local(value))
                        case .archiveResult(let value): state.emit(.archive(value))
                        case .issue(let issue): state.issue(issue)
                        case .progress(let progress): state.update(progress, baseline: baseline)
                        }
                    }
                case .archive(let snapshot, let prefix):
                    let worker = try ArchiveSearchWorker(request: request, limits: archiveLimits,
                        cancellation: cancellation, shouldStop: stop,
                        visit: { state.scanned += 1; state.currentPath = $0; state.progress() },
                        result: { state.emit(.archive($0)) },
                        issue: { state.issue(SearchIssue(path: $0, message: $1.localizedDescription)) },
                        progress: { state.progress() }, sharedBudget: archiveBudget)
                    worker.search(snapshot, prefix: prefix, password: archivePasswords[snapshot.sourceURL])
                case .remote(let provider, let root):
                    let connection = provider.connection
                    if let clean = try? RemotePath.validate(root) {
                        // Only a completed containing scope covers another selection. A denied
                        // parent must not hide an explicitly selected readable child.
                        if remoteScopes.contains(where: { $0.connection == connection &&
                            ($0.root == clean || $0.root == "/" || clean.hasPrefix($0.root + "/")) }) { continue }
                    }
                    var remoteOptions = request.options
                    remoteOptions.maximumContentBytes = min(remoteOptions.maximumContentBytes, 64 * 1024 * 1024)
                    let remoteRequest = SearchRequest(options: remoteOptions, maskGroups: request.maskGroups)
                    let summary = ProviderSearchEngine.runRemoteShared(provider: provider, root: root, request: remoteRequest,
                        limits: remoteLimits, cancellation: cancellation, budget: remoteBudget, shouldStop: stop) { event in
                        switch event {
                        case .result(let value): state.emit(.remote(value, provider))
                        case .issue(let issue):
                            state.issue(SearchIssue(path: SearchLocation.remoteDisplay(connection, issue.path), message: issue.message))
                        case .progress(let progress):
                            state.update(SearchProgress(scanned: progress.scanned, matches: progress.matches, errors: progress.errors,
                                currentPath: SearchLocation.remoteDisplay(connection, progress.currentPath)), baseline: baseline)
                        }
                    }
                    if summary.errors == 0, !summary.cancelled, !summary.limitReached,
                       let clean = try? RemotePath.validate(root) { remoteScopes.append((connection, clean)) }
                }
            }
            state.limitReached = state.limitReached || archiveBudget.limitReached || remoteBudget.limitReached
        } catch {
            if !cancellation.isCancelled { state.issue(SearchIssue(path: "", message: error.localizedDescription)) }
        }
        state.progress()
        return SearchSummary(scanned: state.scanned, matches: state.ids.count, errors: state.errors,
                             cancelled: cancellation.isCancelled, limitReached: state.limitReached)
    }
}

private final class MultiSearchState {
    let maximum: Int
    let cancellation: ProviderSearchCancellation
    let onEvent: (MultiSourceSearchEvent) -> Void
    var scanned = 0, errors = 0
    var ids = Set<String>()
    var currentPath = ""
    var limitReached = false
    var stopped: Bool { cancellation.isCancelled || limitReached }
    init(_ maximum: Int, _ cancellation: ProviderSearchCancellation, _ onEvent: @escaping (MultiSourceSearchEvent) -> Void) {
        self.maximum = maximum; self.cancellation = cancellation; self.onEvent = onEvent
    }
    func emit(_ value: SearchMatch) {
        guard !stopped, ids.insert(value.id).inserted else { return }
        onEvent(.match(value))
        if ids.count >= maximum { limitReached = true }
    }
    func issue(_ issue: SearchIssue) { errors += 1; onEvent(.issue(issue)) }
    func update(_ value: SearchProgress, baseline: Int) {
        scanned = baseline + value.scanned; currentPath = value.currentPath; progress()
    }
    func progress() { onEvent(.progress(SearchProgress(scanned: scanned, matches: ids.count, errors: errors, currentPath: currentPath))) }
}
