import Foundation
import Darwin

/// One budget is shared by every root and archive in a search. Processed bytes
/// include bounded recognition, decompression, working copies and archive content scans. Local content retains its own limit.
public struct ArchiveSearchLimits: Sendable {
    public var maximumArchives: Int
    public var maximumEntries: Int
    public var maximumNestedDepth: Int
    public var maximumTotalContentBytes: Int64
    public init(maximumArchives: Int = 256, maximumEntries: Int = 100_000,
                maximumNestedDepth: Int = 4, maximumTotalContentBytes: Int64 = 256 * 1024 * 1024) {
        self.maximumArchives = maximumArchives; self.maximumEntries = maximumEntries
        self.maximumNestedDepth = maximumNestedDepth; self.maximumTotalContentBytes = maximumTotalContentBytes
    }
    public static let `default` = ArchiveSearchLimits()
}

private struct ArchiveSearchStopped: Error {}
final class ArchiveSearchBudget {
    let limits: ArchiveSearchLimits
    var archives = 0, headers = 0
    var bytes: Int64 = 0
    var limitReached = false
    var searchedLocal = Set<String>()
    var scopes: [(identity: String, prefix: String)] = []
    init(_ limits: ArchiveSearchLimits) throws {
        guard (1...256).contains(limits.maximumArchives), (1...100_000).contains(limits.maximumEntries),
              (0...4).contains(limits.maximumNestedDepth),
              (1...Int64(256 * 1024 * 1024)).contains(limits.maximumTotalContentBytes) else {
            throw ProviderSearchFailure("Недопустимые пределы поиска в архивах.")
        }
        self.limits = limits
    }
    func stop(_ detail: String) throws -> Never {
        limitReached = true
        throw ProviderSearchFailure("Поиск выполнен частично: достигнут общий предел \(detail).")
    }
    func archive() throws {
        guard archives < limits.maximumArchives else { try stop("числа архивов") }
        archives += 1
    }
    func header() throws {
        guard headers < limits.maximumEntries else { try stop("просмотренных заголовков архивов") }
        headers += 1
    }
    func read(_ count: Int64) throws {
        guard count >= 0, count <= limits.maximumTotalContentBytes - bytes else { try stop("обработанных байтов поиска") }
        bytes += count
    }
}

/// Retained by the existing filesystem traversal, so archives are discovered even
/// when their container does not pass the member name, kind, size or content filters.
final class ArchiveSearchWorker {
    private let plan: ProviderSearchPlan
    private let budget: ArchiveSearchBudget
    private let cancellation: ProviderSearchCancellation
    private let shouldStop: () -> Bool
    private let visit: (String) -> Void
    private let result: (ProviderSearchResult) -> Void
    private let issue: (String, Error) -> Void
    private let progress: () -> Void
    private var currentPath = ""
    private var failures = 0
    var limitReached: Bool { budget.limitReached }
    private var stopped: Bool { cancellation.isCancelled || budget.limitReached || shouldStop() }
    private var observation: ArchiveReadObservation {
        ArchiveReadObservation(header: { [self] in
            try checkStopped(); try budget.header(); progress(); try checkStopped()
        }, bytes: { [self] count in
            try checkStopped(); try budget.read(count); progress(); try checkStopped()
        })
    }
    init(request: SearchRequest, limits: ArchiveSearchLimits, cancellation: ProviderSearchCancellation,
         shouldStop: @escaping () -> Bool, visit: @escaping (String) -> Void,
         result: @escaping (ProviderSearchResult) -> Void, issue: @escaping (String, Error) -> Void,
         progress: @escaping () -> Void, sharedBudget: ArchiveSearchBudget? = nil) throws {
        var options = request.options
        options.maximumContentBytes = min(options.maximumContentBytes, 64 * 1024 * 1024)
        plan = try ProviderSearchPlan(SearchRequest(options: options, maskGroups: request.maskGroups))
        budget = try sharedBudget ?? ArchiveSearchBudget(limits)
        self.cancellation = cancellation; self.shouldStop = shouldStop; self.visit = visit
        self.result = result; self.issue = issue; self.progress = progress
    }
    private func checkStopped() throws { if stopped { throw ArchiveSearchStopped() } }
    private func report(_ path: String, _ error: Error) {
        if !cancellation.isCancelled, !(error is ArchiveSearchStopped) { failures += 1; issue(path, error) }
    }
    func searchLocal(_ url: URL, expectedSource: stat, verifySource: @escaping () throws -> Void) {
        guard !stopped else { return }
        let key = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard !budget.searchedLocal.contains(key) else { return }
        do {
            try verifySource()
            // The bounded signature probe never follows a final symbolic link.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ArchiveError.io("Не удалось проверить формат архива.") }
            defer { Darwin.close(descriptor) }
            var value = stat()
            guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.changedArchive }
            var prefix = [UInt8](repeating: 0, count: Int(min(512, max(0, value.st_size))))
            let count = prefix.isEmpty ? 0 : pread(descriptor, &prefix, prefix.count, 0)
            guard count == prefix.count else { throw ArchiveError.io("Не удалось проверить формат архива.") }
            try verifySource()
            guard Self.recognized(url.lastPathComponent, Data(prefix)) else { return }
            try budget.read(Int64(count)); try budget.archive(); budget.searchedLocal.insert(key)
            currentPath = url.path
            let snapshot = try cancellation.transfer { token in
                try ArchiveReader.open(url, limits: readLimits(), cancellation: token,
                    onProgress: { _ in progress() }, observation: observation)
            }
            try snapshot.verifyDiscoveredSource(expectedSource)
            try verifySource()
            search(snapshot, prefix: "", password: nil, counted: true, verifySource: verifySource)
        } catch { report(url.path, error) }
    }
    private func readLimits() -> ArchiveLimits {
        // Header reads and decompression are additionally accounted by observation.
        ArchiveLimits(maximumEntries: min(10_000, budget.limits.maximumEntries),
            maximumEntryBytes: 256 * 1024 * 1024, maximumTotalBytes: 256 * 1024 * 1024)
    }
    func search(_ snapshot: ArchiveSnapshot, prefix: String = "", password: String? = nil) {
        search(snapshot, prefix: prefix, password: password, counted: false, verifySource: {})
    }
    private func search(_ snapshot: ArchiveSnapshot, prefix: String, password: String?, counted: Bool,
                        verifySource: @escaping () throws -> Void) {
        guard !stopped else { return }
        let frame = ArchiveNavigationFrame(snapshot: snapshot)
        let display = frame.displayPath
        let failuresBefore = failures
        do {
            try snapshot.verifyCurrent(); try verifySource()
            guard prefix.isEmpty || (!prefix.hasPrefix("/") && !prefix.hasSuffix("/") &&
                !prefix.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) &&
                snapshot.entries.contains(where: { ($0.path == prefix && $0.isDirectory) || $0.path.hasPrefix(prefix + "/") })) else {
                throw ArchiveError.invalidPath(prefix)
            }
            let identity = snapshot.searchIdentity
            guard !budget.scopes.contains(where: { $0.identity == identity &&
                ($0.prefix.isEmpty || $0.prefix == prefix || prefix.hasPrefix($0.prefix + "/")) }) else { return }
            if !counted { try budget.archive() }
            func visible(_ entry: ArchiveEntry) -> Bool {
                guard prefix.isEmpty || entry.path.hasPrefix(prefix + "/") else { return false }
                let relative = prefix.isEmpty ? entry.path : String(entry.path.dropFirst(prefix.count + 1))
                return plan.options.includeHidden || !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") })
            }
            func emit(_ entry: ArchiveEntry, _ match: SearchContentMatch? = nil) throws {
                try checkStopped(); try snapshot.verifyCurrent(); try verifySource()
                result(ProviderSearchResult(archiveEntry: entry, remoteEntry: nil, archiveURL: snapshot.sourceURL,
                    connectionID: nil, snippet: match?.snippet, lineNumber: match?.line, byteOffset: match?.byteOffset,
                    archiveSnapshot: snapshot, capturedConnection: nil))
            }
            // Missing directory headers are real metadata candidates, under the
            // same bounded accounting as explicit entries.
            let explicit = Set(snapshot.entries.map(\.path))
            var implicit = Set<String>()
            if !plan.hasContent, plan.options.kinds.contains(.directory) {
                for entry in snapshot.entries {
                    let parts = entry.path.split(separator: "/")
                    if parts.count < 2 { continue }
                    for count in 1..<parts.count {
                        try checkStopped()
                        let path = parts.prefix(count).joined(separator: "/")
                        guard !explicit.contains(path), implicit.insert(path).inserted else { continue }
                        try budget.header()
                        let directory = ArchiveEntry(path: path, isDirectory: true, size: 0, modificationDate: nil, isEncrypted: false)
                        guard visible(directory) else { continue }
                        currentPath = display + " !/" + path; visit(currentPath)
                        if try plan.matches(name: directory.name, kind: .directory, size: 0, modified: nil) { try emit(directory) }
                    }
                }
            }
            var wantsContent = false, wantsNested = false, nestedCandidate = false
            try cancellation.transfer { token in
                try ArchiveReader.searchMembers(snapshot, password: password, cancellation: token, observation: observation,
                    inspect: { entry in
                        wantsContent = false; wantsNested = false; nestedCandidate = false
                        guard !stopped, visible(entry) else { return false }
                        currentPath = display + " !/" + entry.path; visit(currentPath)
                        guard !stopped else { return false }
                        do {
                            let matches = try plan.matches(name: entry.name, kind: entry.isDirectory ? .directory : .file,
                                                           size: entry.size, modified: entry.modificationDate)
                            if matches && !plan.hasContent { try emit(entry) }
                            guard !entry.isDirectory, !stopped else { return false }
                            if matches && plan.hasContent {
                                do { try plan.checkContentSize(entry.size); wantsContent = true }
                                catch { report(currentPath, error) }
                            }
                            wantsNested = plan.options.searchNestedArchives == true
                            if entry.isEncrypted && password == nil && (wantsContent || wantsNested) {
                                report(currentPath, ArchiveError.passwordRequired); wantsContent = false; wantsNested = false
                            }
                            return wantsContent || wantsNested
                        } catch { report(currentPath, error); return false }
                    }, materialize: { entry, prefixBytes in
                        guard !stopped else { return false }
                        nestedCandidate = wantsNested && Self.recognized(entry.name, prefixBytes)
                        if nestedCandidate {
                            if frame.depth >= budget.limits.maximumNestedDepth {
                                report(currentPath, ProviderSearchFailure("Вложенный архив пропущен: достигнут предел глубины.")); nestedCandidate = false
                            } else {
                                do { try budget.archive() } catch { report(currentPath, error); nestedCandidate = false }
                            }
                        }
                        return !stopped && (wantsContent || nestedCandidate)
                    }, consume: { entry, workspace in
                        if stopped { return }
                        if wantsContent {
                            do {
                                try budget.read(entry.size) // scanner reservation, including early matches
                                let match = try plan.scan(try workspace.url(for: entry.path), cancellation)
                                if let match { try emit(entry, match) }
                            } catch { report(currentPath, error) }
                        }
                        guard nestedCandidate, !stopped else { return }
                        do {
                            let child = try frame.openNested(workspace: workspace, path: entry.path,
                                cancellation: token, onProgress: { _ in progress() }, observation: observation)
                            // Passwords of the selected archive never leak into a child.
                            search(child.snapshot, prefix: "", password: nil, counted: true, verifySource: verifySource)
                        } catch { report(display + " !/" + entry.path, error) }
                    })
            }
            try snapshot.verifyCurrent(); try verifySource()
            if failures == failuresBefore { budget.scopes.append((identity, prefix)) }
        } catch { report(currentPath.isEmpty ? display : currentPath, error) }
    }
    private static func recognized(_ name: String, _ data: Data) -> Bool {
        if ArchiveFormat.suggested(by: URL(fileURLWithPath: name)) != nil { return true }
        let p = [UInt8](data)
        if p.starts(with: [0x50, 0x4b, 0x03, 0x04]) || p.starts(with: [0x50, 0x4b, 0x05, 0x06]) ||
            p.starts(with: [0x1f, 0x8b]) || p.starts(with: [0x42, 0x5a, 0x68]) ||
            p.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]) { return true }
        // Recognized unsupported formats produce a visible issue instead of a
        // misleading complete search; they are never delegated to an external tool.
        if p.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) || p.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) { return true }
        if p.count >= 262, Array(p[257..<262]) == Array("ustar".utf8) { return true }
        // Traditional TAR has no magic: require its complete header checksum.
        guard p.count == 512, p.contains(where: { $0 != 0 }),
              let checksum = String(bytes: p[148..<156], encoding: .ascii)?.trimmingCharacters(in: CharacterSet(charactersIn: " \0")),
              let expected = Int(checksum, radix: 8) else { return false }
        return p.enumerated().reduce(0) { $0 + ((148..<156).contains($1.offset) ? 32 : Int($1.element)) } == expected
    }
}
