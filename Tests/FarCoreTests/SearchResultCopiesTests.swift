import Foundation
import Testing
@testable import FarCore

@Suite struct SearchResultCopiesTests {
    private func remoteMatch(_ provider: CopySearchRemote, path: String) throws -> SearchMatch {
        let entry = try #require(try provider.stat(path: path, cancellation: TransferCancellation()))
        return .remote(ProviderSearchResult(archiveEntry: nil, remoteEntry: entry, archiveURL: nil,
            connectionID: provider.connection.id, snippet: nil, lineNumber: nil, byteOffset: nil,
            archiveSnapshot: nil, capturedConnection: provider.connection), provider)
    }
    func archiveMatch(_ snapshot: ArchiveSnapshot, path: String) throws -> SearchMatch {
        let entry = try #require(snapshot.entries.first { $0.path == path })
        return .archive(ProviderSearchResult(archiveEntry: entry, remoteEntry: nil, archiveURL: snapshot.sourceURL,
            connectionID: nil, snippet: nil, lineNumber: nil, byteOffset: nil, archiveSnapshot: snapshot, capturedConnection: nil))
    }
    @Test func offlineResultsRequireExplicitRestoreBeforeCopy() throws {
        let fixture = try ProviderSearchTests()
        let file = fixture.root.appendingPathComponent("offline.txt")
        try Data("original".utf8).write(to: file)
        let reference = try SavedSearchReference(capturing: .local(SearchResult.capture(file)))
        #expect(throws: PanelSessionError.self) { try SearchResultCopies.prepare([.saved(reference)]) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        let resolver = SavedSearchResolver(providerFactory: { _ in throw NetworkError.changedSource })
        let restored = try resolver.resolve(reference)
        let copies = try SearchResultCopies.prepare([restored])
        #expect(copies.count == 1 && copies[0].source == file)
    }
    @Test func mixedCopiesRetainWorkspacesAndKeepSameNamesDistinct() throws {
        let fixture = try ProviderSearchTests()
        let local = fixture.root.appendingPathComponent("same.txt"); try Data("local".utf8).write(to: local)
        let archive = try fixture.archive([("same.txt", Data("archive".utf8))])
        let remote = CopySearchRemote(); remote.files["/same.txt"] = Data("remote".utf8)
        let values: [SearchMatch] = [.local(try SearchResult.capture(local)), try archiveMatch(archive, path: "same.txt"), try remoteMatch(remote, path: "/same.txt")]
        var copies: [SearchResultCopy]? = try SearchResultCopies.prepare(values)
        let urls = try #require(copies).map(\.source)
        #expect(Set(urls).count == 3)
        #expect(try urls.map { try String(contentsOf: $0, encoding: .utf8) } == ["local", "archive", "remote"])
        #expect(urls.allSatisfy { $0.lastPathComponent == "same.txt" })
        copies = nil
        #expect(FileManager.default.fileExists(atPath: local.path))
        #expect(!FileManager.default.fileExists(atPath: urls[1].path))
        #expect(!FileManager.default.fileExists(atPath: urls[2].path))
        #expect(remote.files["/same.txt"] == Data("remote".utf8))
    }
    @Test func implicitArchiveDirectoryStagesItsContents() throws {
        let fixture = try ProviderSearchTests()
        let snapshot = try fixture.archive([("folder/file.txt", Data("inside".utf8))])
        var options = SearchOptions(roots: []); options.kinds = [.directory]
        var match: SearchMatch?
        _ = MultiSourceSearchEngine.run(locations: [.archive(snapshot, prefix: "")], request: SearchRequest(options: options),
            cancellation: ProviderSearchCancellation()) { if case .match(let value) = $0, value.name == "folder" { match = value } }
        let copies = try SearchResultCopies.prepare([try #require(match)])
        #expect(try String(contentsOf: #require(copies.first).source.appendingPathComponent("file.txt"), encoding: .utf8) == "inside")
        try snapshot.verifyCurrent()
    }
    @Test func remoteDirectoryCopiesChildrenAndEmptyFolders() throws {
        let remote = CopySearchRemote(); remote.directories = ["/", "/tree", "/tree/empty"]
        remote.files["/tree/a"] = Data("data".utf8)
        let copies = try SearchResultCopies.prepare([try remoteMatch(remote, path: "/tree")])
        let root = try #require(copies.first).source
        #expect(try String(contentsOf: root.appendingPathComponent("a"), encoding: .utf8) == "data")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty").path))
    }
    @Test func changedLocalAndRemoteIdentityRejectPreparation() throws {
        let fixture = try ProviderSearchTests(); let local = fixture.root.appendingPathComponent("local")
        try Data("old".utf8).write(to: local); let old = SearchMatch.local(try SearchResult.capture(local))
        try Data("changed".utf8).write(to: local)
        #expect(throws: (any Error).self) { try SearchResultCopies.prepare([old]) }
        let remote = CopySearchRemote(); remote.files["/file"] = Data("one".utf8)
        let match = try remoteMatch(remote, path: "/file"); remote.connection.host = "replacement.test"
        #expect(throws: NetworkError.changedSource) { try SearchResultCopies.prepare([match]) }
        #expect(remote.downloads == 0)
    }
    @Test func cancellationAndAggregateLimitPreventDownload() throws {
        let remote = CopySearchRemote(); remote.files["/large"] = Data("x".utf8)
        remote.reportedSize = SearchResultCopies.maximumBytes + 1
        let match = try remoteMatch(remote, path: "/large")
        #expect(throws: (any Error).self) { try SearchResultCopies.prepare([match]) }
        #expect(remote.downloads == 0)
        let token = TransferCancellation(); token.cancel()
        #expect(throws: (any Error).self) { try SearchResultCopies.prepare([match], cancellation: token) }
        #expect(remote.downloads == 0)
    }
    @Test func encryptedArchiveNeedsExplicitPasswordAndNeverChangesSource() throws {
        let fixture = try ProviderSearchTests()
        let snapshot = try fixture.archive([("secret.txt", Data("secret".utf8))], password: "test pass")
        let match = try archiveMatch(snapshot, path: "secret.txt")
        #expect(throws: (any Error).self) { try SearchResultCopies.prepare([match]) }
        let copies = try SearchResultCopies.prepare([match], archivePasswords: [snapshot.sourceURL: "test pass"])
        #expect(try String(contentsOf: #require(copies.first).source, encoding: .utf8) == "secret")
        try snapshot.verifyCurrent()
    }
}

private final class CopySearchRemote: RemoteBoundedDownloadProvider {
    var connection = NetworkConnection(kind: .sftp, host: "copy.test", username: "tester")
    var files: [String: Data] = [:]
    var directories: Set<String> = ["/"]
    var reportedSize: Int64?
    var downloads = 0
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        if directories.contains(path) { return RemoteEntry(path: path, isDirectory: true, size: 0) }
        guard let bytes = files[path] else { return nil }
        return RemoteEntry(path: path, isDirectory: false, size: reportedSize ?? Int64(bytes.count), version: "original")
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        try (Array(directories) + Array(files.keys)).filter { $0 != path && RemotePath.parent($0) == path }
            .sorted().compactMap { try stat(path: $0, cancellation: cancellation) }
    }
    func boundedDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation,
                         progress: @escaping (NetworkProgress) -> Void) throws {
        guard !cancellation.isCancelled else { throw NetworkError.cancelled }
        let data = files[path] ?? Data(); guard data.count <= maximumBytes else { throw NetworkError.limitExceeded("fixture") }
        downloads += 1; try data.write(to: to)
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("Unbounded") }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("No writes") }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No writes") }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No writes") }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No writes") }
}
