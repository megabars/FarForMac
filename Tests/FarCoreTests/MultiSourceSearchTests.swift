import Foundation
import Testing
@testable import FarCore

@Suite final class MultiSourceSearchTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FarMultiSearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func request(_ query: String? = nil) -> SearchRequest {
        var options = SearchOptions(roots: [])
        options.kinds = [.file]
        if let query { options.contentMode = .literal; options.contentQuery = query }
        return SearchRequest(options: options)
    }
    func collect(_ locations: [SearchLocation], request: SearchRequest? = nil,
                 archiveLimits: ArchiveSearchLimits = .default, remoteLimits: ProviderSearchLimits = .default,
                 cancellation: ProviderSearchCancellation = ProviderSearchCancellation()) -> (SearchSummary, [SearchMatch], [SearchIssue]) {
        var matches: [SearchMatch] = [], issues: [SearchIssue] = []
        let summary = MultiSourceSearchEngine.run(locations: locations, request: request ?? self.request(),
            archiveLimits: archiveLimits, remoteLimits: remoteLimits, cancellation: cancellation) {
            switch $0 { case .match(let value): matches.append(value); case .issue(let value): issues.append(value); case .progress: break }
        }
        return (summary, matches, issues)
    }
    @Test func mixedSourcesKeepTypedOriginsAndDeduplicateOverlappingRoots() throws {
        let file = root.appendingPathComponent("local.txt"); try Data("needle".utf8).write(to: file)
        let fixture = try ProviderSearchTests()
        let archive = try fixture.archive([("member.txt", Data("needle".utf8))])
        let provider = MultiSearchRemote(); provider.add("/scope/remote.txt", "needle")
        let result = collect([.local(root), .local(file), .archive(archive, prefix: ""),
                              .remote(provider, root: "/scope/remote.txt"), .remote(provider, root: "/scope")])
        #expect(result.0.errors == 0); #expect(result.0.matches == 3)
        #expect(Set(result.1.map(\.name)) == ["local.txt", "member.txt", "remote.txt"])
        #expect(provider.listed == ["/scope"])
        #expect(result.1.allSatisfy { !$0.displayPath.contains("FarRemote-") })
        for value in result.1 { try value.verifyCurrent() }
    }
    @Test func mixedContentSearchKeepsLocalByteLimitAndClampsRemoteLimit() throws {
        let file = root.appendingPathComponent("local.txt")
        try Data("needle local".utf8).write(to: file)
        let provider = MultiSearchRemote(); provider.add("/scope/remote.txt", "needle remote")
        var options = request("needle").options; options.maximumContentBytes = 96 * 1024 * 1024
        let result = collect([.local(root), .remote(provider, root: "/scope")], request: SearchRequest(options: options))
        #expect(result.0.errors == 0); #expect(result.0.matches == 2)
        #expect(Set(result.1.map(\.name)) == ["local.txt", "remote.txt"])
        #expect(provider.downloadCount == 1)
        #expect(options.maximumContentBytes == 96 * 1024 * 1024)
    }
    @Test func ordinarySourceFailureDoesNotPreventOtherSourcesAndProgressIsGlobal() throws {
        let bad = MultiSearchRemote(), good = MultiSearchRemote(); good.add("/scope/found", "yes")
        var progress: [Int] = [], matches: [SearchMatch] = []
        let summary = MultiSourceSearchEngine.run(locations: [.remote(bad, root: "/missing"), .remote(good, root: "/scope")],
            request: request(), cancellation: ProviderSearchCancellation()) {
            switch $0 { case .progress(let value): progress.append(value.scanned)
            case .match(let value): matches.append(value); case .issue: break }
        }
        #expect(summary.errors == 1); #expect(summary.matches == 1)
        #expect(matches.first?.name == "found"); #expect(progress == progress.sorted())
    }
    @Test func inaccessibleBroadScopeDoesNotSuppressAnExplicitReadableChild() throws {
        for childFirst in [false, true] {
            let provider = MultiSearchRemote(); provider.add("/scope/readable.txt", "needle")
            provider.deniedListings = ["/scope"]
            let parent = SearchLocation.remote(provider, root: "/scope")
            let child = SearchLocation.remote(provider, root: "/scope/readable.txt")
            let result = collect(childFirst ? [child, parent] : [parent, child], request: request("needle"))
            #expect(result.0.errors == 1); #expect(result.1.map(\.name) == ["readable.txt"])
            #expect(provider.downloadCount == 1)
        }
    }
    @Test func resultCapAndCancellationAreGlobalAcrossSources() throws {
        let first = MultiSearchRemote(), second = MultiSearchRemote()
        first.add("/scope/a", "needle"); second.add("/scope/b", "needle")
        var options = request().options; options.maximumResults = 1
        let capped = collect([.remote(first, root: "/scope"), .remote(second, root: "/scope")], request: SearchRequest(options: options))
        #expect(capped.0.limitReached); #expect(capped.1.count == 1); #expect(second.statCount == 0)
        let token = ProviderSearchCancellation(); first.onDownload = { token.cancel() }
        let cancelled = collect([.remote(first, root: "/scope"), .remote(second, root: "/scope")], request: request("needle"), cancellation: token)
        #expect(cancelled.0.cancelled); #expect(cancelled.0.errors == 0); #expect(cancelled.1.isEmpty)
        #expect(first.copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(second.statCount == 0)
    }
    @Test func remoteBytesAndPendingEntriesShareBudgetsAcrossDifferentProviders() throws {
        let first = MultiSearchRemote(), second = MultiSearchRemote()
        first.add("/scope/a", "needle"); second.add("/scope/b", "needle")
        let bytes = collect([.remote(first, root: "/scope"), .remote(second, root: "/scope")], request: request("needle"),
                            remoteLimits: ProviderSearchLimits(maximumTotalContentBytes: 6))
        #expect(bytes.0.limitReached); #expect(bytes.0.errors == 1); #expect(bytes.1.count == 1)
        #expect(first.downloadCount == 1); #expect(second.downloadCount == 0)
        let entries = collect([.remote(first, root: "/scope"), .remote(second, root: "/scope")],
                              remoteLimits: ProviderSearchLimits(maximumEntries: 3))
        #expect(entries.0.limitReached); #expect(entries.0.errors == 1); #expect(entries.1.count == 1)
    }
    @Test func archiveBudgetIncludesAutomaticExplicitAndNestedSearches() throws {
        let fixture = try ProviderSearchTests()
        let first = try fixture.archive([("one.txt", Data("one".utf8))])
        let second = try fixture.archive([("two.txt", Data("two".utf8))])
        var options = request().options; options.searchArchives = true; options.namePattern = "*.txt"
        let result = collect([.local(first.sourceURL), .archive(second, prefix: "")], request: SearchRequest(options: options),
                             archiveLimits: ArchiveSearchLimits(maximumArchives: 1))
        #expect(result.0.limitReached); #expect(result.0.errors == 1); #expect(result.1.map(\.name) == ["one.txt"])
        let overlap = collect([.local(first.sourceURL), .archive(first, prefix: "")], request: SearchRequest(options: options))
        #expect(overlap.0.errors == 0); #expect(overlap.1.count == 1)
    }
    @Test func nestedSnapshotResultsOutliveWorkersAndKeepLogicalIdentity() throws {
        let fixture = try ProviderSearchTests()
        let child = try fixture.archive([("found.txt", Data("needle".utf8))])
        let parent = try fixture.archive([("child.zip", try Data(contentsOf: child.sourceURL))])
        var options = request("needle").options; options.searchNestedArchives = true
        let result = collect([.archive(parent, prefix: "")], request: SearchRequest(options: options))
        let match = try #require(result.1.first { $0.name == "found.txt" })
        #expect(match.displayPath == parent.sourceURL.path + " !/child.zip !/found.txt")
        #expect(!match.id.contains("FarArchive-")); #expect(!match.canEdit)
        try match.verifyCurrent()
        let repeated = collect([.archive(parent, prefix: "")], request: SearchRequest(options: options))
        #expect(repeated.1.first { $0.name == "found.txt" }?.id == match.id)
        try Data("replaced".utf8).write(to: parent.sourceURL)
        #expect(throws: ArchiveError.changedArchive) { try match.verifyCurrent() }
    }
    @Test func nestedArchivesConsumeTheSameArchiveCountBudget() throws {
        let fixture = try ProviderSearchTests()
        let child = try fixture.archive([("found.txt", Data("needle".utf8))])
        let parent = try fixture.archive([("child.zip", try Data(contentsOf: child.sourceURL))])
        var options = request().options; options.searchNestedArchives = true; options.namePattern = "*.txt"
        let result = collect([.archive(parent, prefix: "")], request: SearchRequest(options: options),
                             archiveLimits: ArchiveSearchLimits(maximumArchives: 1))
        #expect(result.0.limitReached); #expect(result.1.isEmpty); #expect(result.0.errors >= 1)
    }
    @Test func explicitEncryptedSourceUsesOnlyRuntimePasswordAndCanRetryAfterAutomaticScan() throws {
        let fixture = try ProviderSearchTests()
        let snapshot = try fixture.archive([("secret.txt", Data("needle".utf8))], password: "memory-only")
        var options = request("needle").options; options.searchArchives = true; options.namePattern = "*.txt"
        var matches: [SearchMatch] = []
        let summary = MultiSourceSearchEngine.run(locations: [.local(snapshot.sourceURL), .archive(snapshot, prefix: "")],
            request: SearchRequest(options: options), archivePasswords: [snapshot.sourceURL: "memory-only"],
            cancellation: ProviderSearchCancellation()) {
            if case .match(let value) = $0 { matches.append(value) }
        }
        #expect(summary.matches == 1); #expect(matches.first?.name == "secret.txt")
        try matches.first?.verifyCurrent()
    }
    @Test func capturedConfigurationsDistinguishReusedUUIDAndRejectProviderMutation() throws {
        let first = MultiSearchRemote(), second = MultiSearchRemote()
        first.add("/scope/same", "yes"); second.add("/scope/same", "yes")
        second.connection.id = first.connection.id; second.connection.host = "second.test"
        let result = collect([.remote(first, root: "/scope"), .remote(second, root: "/scope")])
        #expect(result.1.count == 2); #expect(Set(result.1.map(\.id)).count == 2)
        let match = try #require(result.1.first)
        let originalDisplay = match.displayPath
        first.connection.host = "mutated.test"
        #expect(match.displayPath == originalDisplay)
        #expect(throws: NetworkError.changedSource) { try match.verifyCurrent() }
    }
    @Test func staleArchiveCannotBeRecapturedByTheCombinedEngine() throws {
        let fixture = try ProviderSearchTests()
        let snapshot = try fixture.archive([("old", Data())])
        try Data("different".utf8).write(to: snapshot.sourceURL)
        let good = MultiSearchRemote(); good.add("/scope/new", "yes")
        let result = collect([.archive(snapshot, prefix: ""), .remote(good, root: "/scope")])
        #expect(result.0.errors == 1); #expect(result.1.map(\.name) == ["new"])
    }
    @Test func sessionCollectionPreservesFirstStampsAndBoundedDeduplicatedOrder() throws {
        let file = root.appendingPathComponent("file"); try Data("old".utf8).write(to: file)
        let old = SearchMatch.local(try SearchResult.capture(file))
        var collection = TemporarySearchCollection([old, old])
        #expect(collection.items.count == 1)
        try Data("replacement".utf8).write(to: file)
        let new = SearchMatch.local(try SearchResult.capture(file))
        collection.append([new]); collection.replace([new])
        #expect(collection.items.count == 1)
        #expect(throws: (any Error).self) { try collection.items[0].verifyCurrent() }
        let provider = MultiSearchRemote()
        let values = (0...TemporarySearchCollection.maximumCount).map { index in
            SearchMatch.remote(ProviderSearchResult(archiveEntry: nil,
                remoteEntry: RemoteEntry(path: "/scope/\(index)", isDirectory: false, size: 0), archiveURL: nil,
                connectionID: provider.connection.id, snippet: nil, lineNumber: nil, byteOffset: nil,
                archiveSnapshot: nil, capturedConnection: provider.connection), provider)
        }
        collection.replace(values)
        #expect(collection.items.count == 10_000)
        #expect(collection.items.last?.name == "9999")
        collection.remove(ids: [values[0].id]); #expect(collection.items.first?.name == "1")
        collection.removeAll(); #expect(collection.items.isEmpty)
    }
    @Test func sourceCapRejectsBeforeAnyIO() throws {
        let provider = MultiSearchRemote()
        let result = collect(Array(repeating: .remote(provider, root: "/scope"), count: 33))
        #expect(result.0.errors == 1); #expect(provider.statCount == 0)
    }
}

private final class MultiSearchRemote: RemoteSearchDownloadProvider {
    var connection = NetworkConnection(kind: .sftp, host: "example.test", username: "tester")
    var entries: [String: RemoteEntry] = ["/scope": RemoteEntry(path: "/scope", isDirectory: true, size: 0)]
    var files: [String: Data] = [:]
    var listed: [String] = [], copies: [URL] = []
    var statCount = 0, downloadCount = 0
    var onDownload: (() -> Void)?
    var deniedListings = Set<String>()
    func add(_ path: String, _ text: String) {
        let data = Data(text.utf8); files[path] = data
        entries[path] = RemoteEntry(path: path, isDirectory: false, size: Int64(data.count), version: UUID().uuidString)
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        listed.append(path)
        if deniedListings.contains(path) { throw NetworkError.connectionFailed("Fixture permission denied") }
        return entries.values.filter { $0.path != path && RemotePath.parent($0.path) == path }.sorted { $0.path < $1.path }
    }
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? { statCount += 1; return entries[path] }
    func searchDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        downloadCount += 1; copies.append(to)
        let data = files[path] ?? Data()
        guard data.count <= maximumBytes else { throw NetworkError.limitExceeded("fixture bound") }
        try data.write(to: to); onDownload?()
        if cancellation.isCancelled { throw NetworkError.cancelled }
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("Unbounded download") }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("No mutation") }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No mutation") }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No mutation") }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No mutation") }
}
