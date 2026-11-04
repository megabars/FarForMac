import Foundation
import Darwin
import CArchive
import Testing
@testable import FarCore

@Suite final class ProviderSearchTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FarProviderSearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func request(content: String? = nil) -> SearchRequest {
        var options = SearchOptions(roots: []) // provider scope replaces local roots
        if let content { options.contentQuery = content; options.contentMode = .literal }
        return SearchRequest(options: options)
    }
    func archive(_ members: [(String, Data)], format: ArchiveFormat = .zip, password: String? = nil) throws -> ArchiveSnapshot {
        let url = root.appendingPathComponent(UUID().uuidString + "." + format.rawValue)
        let writer = archive_write_new()!
        defer { archive_write_free(writer) }
        func check(_ result: Int32) throws {
            guard result == ARCHIVE_OK else { throw ArchiveError.io(archive_error_string(writer).map(String.init(cString:)) ?? "fixture") }
        }
        try check(format == .zip ? archive_write_set_format_zip(writer) : archive_write_set_format_pax_restricted(writer))
        if let password { try check(archive_write_set_options(writer, "zip:encryption=zipcrypt")); try check(archive_write_set_passphrase(writer, password)) }
        try check(archive_write_open_filename(writer, url.path))
        for (name, data) in members {
            let entry = archive_entry_new()!; defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, name)
            archive_entry_set_filetype(entry, UInt32(name.hasSuffix("/") ? S_IFDIR : S_IFREG))
            archive_entry_set_perm(entry, 0o600); archive_entry_set_size(entry, Int64(data.count))
            archive_entry_set_mtime(entry, 1_700_000_000, 0)
            try check(archive_write_header(writer, entry))
            if !data.isEmpty {
                let written = data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                guard written == data.count else { throw ArchiveError.io("fixture data") }
            }
            try check(archive_write_finish_entry(writer))
        }
        try check(archive_write_close(writer))
        return try ArchiveReader.open(url)
    }
    func collectArchive(_ snapshot: ArchiveSnapshot, prefix: String = "", request: SearchRequest,
                        password: String? = nil, cancellation: ProviderSearchCancellation = ProviderSearchCancellation()) -> (SearchSummary, [ProviderSearchResult], [SearchIssue]) {
        var results: [ProviderSearchResult] = [], issues: [SearchIssue] = []
        let summary = ProviderSearchEngine.runArchive(snapshot, prefix: prefix, request: request, password: password, cancellation: cancellation) {
            switch $0 { case .result(let r): results.append(r); case .issue(let i): issues.append(i); case .progress: break }
        }
        return (summary, results, issues)
    }
    private func collectRemote(_ provider: SearchRemote, root: String = "/scope", request: SearchRequest,
                       limits: ProviderSearchLimits = .default, cancellation: ProviderSearchCancellation = ProviderSearchCancellation()) -> (SearchSummary, [ProviderSearchResult], [SearchIssue]) {
        var results: [ProviderSearchResult] = [], issues: [SearchIssue] = []
        let summary = ProviderSearchEngine.runRemote(provider: provider, root: root, request: request, limits: limits, cancellation: cancellation) {
            switch $0 { case .result(let r): results.append(r); case .issue(let i): issues.append(i); case .progress: break }
        }
        return (summary, results, issues)
    }
    @Test func archiveScopeMasksMetadataAndHiddenEntriesForZIPAndTAR() throws {
        for format in [ArchiveFormat.zip, .tar] {
            let snapshot = try archive([("folder/", Data()), ("folder/a.txt", Data("abcdef".utf8)),
                ("folder/a.log", Data("abcdef".utf8)), ("folder/.hidden/a.txt", Data("abcdef".utf8)),
                ("folder2/outside.txt", Data("abcdef".utf8))], format: format)
            var options = request().options
            options.namePattern = "<text>|a.log"; options.kinds = [.file]; options.minSize = 6; options.maxSize = 6
            options.modifiedAfter = Date(timeIntervalSince1970: 1_699_999_999)
            options.modifiedBefore = Date(timeIntervalSince1970: 1_700_000_001)
            let (summary, results, _) = collectArchive(snapshot, prefix: "folder", request: SearchRequest(options: options, maskGroups: ["text": "*.txt"]))
            #expect(summary.errors == 0); #expect(results.map(\.path) == ["folder/a.txt"])
            try results[0].verifyArchiveCurrent(snapshot: snapshot)
            #expect(collectArchive(snapshot, prefix: "folder/../folder2", request: request()).0.errors == 1)
        }
    }
    @Test func archiveFindsImplicitDirectoriesAndVerifiesTheirSnapshot() throws {
        let snapshot = try archive([("parent/child/file.txt", Data("text".utf8))])
        var options = request().options; options.kinds = [.directory]
        let result = collectArchive(snapshot, request: SearchRequest(options: options))
        #expect(result.1.map(\.path) == ["parent", "parent/child"])
        for entry in result.1 { try entry.verifyArchiveCurrent(snapshot: snapshot) }
    }
    @Test func archiveContentDecodingSnippetAndPasswordRemainInMemory() throws {
        let snapshot = try archive([("secret.txt", Data("first\r\nПривет 🌍".utf8))], password: "memory secret")
        #expect(collectArchive(snapshot, request: request()).1.count == 1)
        #expect(collectArchive(snapshot, request: request(content: "Привет")).0.errors == 1)
        #expect(collectArchive(snapshot, request: request(content: "Привет"), password: "bad").0.errors == 1)
        let (summary, results, _) = collectArchive(snapshot, request: request(content: "привет"), password: "memory secret")
        #expect(summary.errors == 0); #expect(results.count == 1)
        #expect(results.first?.lineNumber == 2); #expect(results.first?.snippet?.contains("Привет") == true)
    }
    @Test func archiveContentLimitAndStaleSnapshotRejectResults() throws {
        let snapshot = try archive([("a", Data("needle".utf8))])
        var options = request(content: "needle").options; options.maximumContentBytes = 2
        let capped = collectArchive(snapshot, request: SearchRequest(options: options))
        #expect(capped.0.errors == 1); #expect(capped.1.isEmpty)
        let old = try #require(collectArchive(snapshot, request: request()).1.first)
        var bytes = try Data(contentsOf: snapshot.sourceURL); bytes.append(0)
        try bytes.write(to: snapshot.sourceURL)
        #expect(throws: ArchiveError.changedArchive) { try old.verifyArchiveCurrent(snapshot: snapshot) }
        #expect(collectArchive(snapshot, request: request()).0.errors == 1)
    }
    @Test func archiveCancellationAndResultCapStopIncrementally() throws {
        let snapshot = try archive([("a", Data()), ("b", Data())])
        var options = request().options; options.maximumResults = 1
        let capped = collectArchive(snapshot, request: SearchRequest(options: options))
        #expect(capped.0.limitReached); #expect(capped.1.count == 1)
        let token = ProviderSearchCancellation()
        let stopped = ProviderSearchEngine.runArchive(snapshot, request: request(content: "x"), cancellation: token) {
            if case .progress = $0 { token.cancel() }
        }
        #expect(stopped.cancelled); #expect(stopped.matches == 0); #expect(stopped.errors == 0)
    }
    @Test func archiveCancellationInterruptsExtractionBeforeAnyResult() throws {
        let snapshot = try archive([("large.txt", Data(("needle" + String(repeating: "x", count: 131_072)).utf8))])
        let token = ProviderSearchCancellation()
        var progressCount = 0
        let summary = ProviderSearchEngine.runArchive(snapshot, request: request(content: "needle"), cancellation: token) {
            if case .progress = $0 {
                progressCount += 1
                if progressCount == 2 { token.cancel() }
            }
        }
        #expect(progressCount >= 2); #expect(summary.cancelled); #expect(summary.matches == 0); #expect(summary.errors == 0)
    }
    @Test func remoteMetadataRecursesWithoutDownloadingOrFollowingLinks() throws {
        let p = SearchRemote(); p.add("/scope/sub", directory: true)
        p.add("/scope/sub/report.txt", text: "needle"); p.add("/scope/.hidden/report.txt", text: "needle")
        p.add("/scope/.hidden", directory: true)
        p.add("/scope/link", directory: true, link: true)
        p.add("/scope/link/escape.txt", text: "needle")
        var options = request().options; options.namePattern = "*.txt"; options.followSymbolicLinks = true
        let result = collectRemote(p, request: SearchRequest(options: options))
        #expect(result.0.errors == 0); #expect(result.1.map(\.path) == ["/scope/sub/report.txt"])
        #expect(p.downloaded.isEmpty); #expect(!p.listed.contains("/scope/link")); #expect(!p.listed.contains("/scope/.hidden"))
    }
    @Test func remoteRejectsEscapedParentDuplicateAndCycleListings() throws {
        let p = SearchRemote(); p.add("/scope/good", text: "ok")
        p.listOverride = [RemoteEntry(path: "/outside", isDirectory: false, size: 0),
            RemoteEntry(path: "/scope", isDirectory: true, size: 0),
            RemoteEntry(path: "/scope/../escape", isDirectory: true, size: 0),
            RemoteEntry(path: "/scope/good", isDirectory: false, size: 2),
            RemoteEntry(path: "/scope/good", isDirectory: false, size: 2)]
        let result = collectRemote(p, request: request())
        #expect(result.0.errors == 4); #expect(result.1.map(\.path) == ["/scope/good"])
        #expect(p.listed == ["/scope"]); #expect(p.downloaded.isEmpty)
    }
    @Test func remoteContentUsesChosenEncodingAndRemovesEveryPrivateCopy() throws {
        let p = SearchRemote(); p.add("/scope/text", bytes: Data([0xff, 0xfe] + Array("first\r\nПривет 🌍".utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }))
        var options = request(content: "Привет").options; options.contentEncoding = .utf16LE
        let result = collectRemote(p, request: SearchRequest(options: options))
        #expect(result.0.errors == 0); #expect(result.1.count == 1); #expect(result.1.first?.lineNumber == 2)
        #expect(p.downloaded.count == 1); #expect(p.localCopies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try result.1[0].verifyRemoteCurrent(provider: p)
        p.add("/scope/text", text: "changed")
        #expect(throws: NetworkError.changedSource) { try result.1[0].verifyRemoteCurrent(provider: p) }
    }
    @Test func remoteChangedFilesAndInvalidTextNeverEmitEarlyMatches() throws {
        for mutate in [false, true] {
            let p = SearchRemote(); p.add("/scope/text", bytes: mutate ? Data("needle".utf8) : Data("needle".utf8) + Data([0xff]))
            if mutate { p.onDownload = { p.add("/scope/text", text: "changed") } }
            let result = collectRemote(p, request: request(content: "needle"))
            #expect(result.0.errors == 1); #expect(result.1.isEmpty)
            #expect(p.localCopies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }
    @Test func remoteRejectsTooLargeFilesBeforeDownloadAndBoundsTotalBudget() throws {
        let p = SearchRemote(); p.add("/scope/a", text: "needle"); p.add("/scope/b", text: "needle")
        var options = request(content: "needle").options; options.maximumContentBytes = 3
        let small = collectRemote(p, request: SearchRequest(options: options))
        #expect(small.0.errors == 2); #expect(p.downloaded.isEmpty)
        let total = collectRemote(p, request: request(content: "needle"), limits: ProviderSearchLimits(maximumTotalContentBytes: 6))
        #expect(total.1.count == 1); #expect(total.0.errors == 1); #expect(p.downloaded.count == 1)
    }
    @Test func remoteTraversalCapsAndMissingDatesAreExplicit() throws {
        let p = SearchRemote(); p.add("/scope/sub", directory: true); p.add("/scope/sub/item", text: "x")
        let depth = collectRemote(p, request: request(), limits: ProviderSearchLimits(maximumDepth: 1))
        #expect(depth.0.errors == 1); #expect(!p.listed.contains("/scope/sub"))
        let entries = collectRemote(p, request: request(), limits: ProviderSearchLimits(maximumEntries: 1))
        #expect(entries.0.limitReached); #expect(entries.0.errors == 1)
        var options = request().options; options.modifiedAfter = Date(timeIntervalSince1970: 0)
        #expect(collectRemote(p, request: SearchRequest(options: options)).1.isEmpty)
    }
    @Test func remotePendingDirectoryArraysShareOneEntryBudget() throws {
        let p = SearchRemote()
        for name in ["a", "b", "c"] { p.add("/scope/" + name, directory: true) }
        for name in ["x", "y", "z"] { p.add("/scope/a/" + name, text: "needle") }
        var options = request().options; options.kinds = [.file]
        let result = collectRemote(p, request: SearchRequest(options: options), limits: ProviderSearchLimits(maximumEntries: 5))
        #expect(result.0.limitReached); #expect(result.0.errors == 1)
        #expect(result.1.isEmpty); #expect(result.0.scanned == 2)
    }
    @Test func cancellationInterruptsActiveProviderOperationAndCleansWorkspace() throws {
        let p = SearchRemote(); p.add("/scope/text", text: "needle")
        let token = ProviderSearchCancellation(); p.onDownload = { token.cancel() }
        let result = collectRemote(p, request: request(content: "needle"), cancellation: token)
        #expect(result.0.cancelled); #expect(result.0.errors == 0); #expect(result.1.isEmpty); #expect(p.sawTransferCancellation)
        #expect(p.localCopies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    @Test func archiveHexSearchFindsRawBinaryInZIPAndTAR() throws {
        var bytes = Data(repeating: 0x61, count: 65_535); bytes.append(contentsOf: [0, 0xFF, 0xFE, 0x41])
        for format in [ArchiveFormat.zip, .tar] {
            let snapshot = try archive([("nested/binary", bytes)], format: format)
            var options = request().options; options.contentMode = .hex; options.contentQuery = "00 ff FE 41"
            options.contentEncoding = .utf16BE
            let result = collectArchive(snapshot, prefix: "nested", request: SearchRequest(options: options))
            #expect(result.0.errors == 0); #expect(result.1.count == 1)
            #expect(result.1.first?.byteOffset == 65_535); #expect(result.1.first?.lineNumber == nil)
            #expect(result.1.first?.snippet == "0xFFFF: 00 FF FE 41")
            try result.1.first?.verifyArchiveCurrent(snapshot: snapshot)
        }
    }
    @Test func remoteHexSearchPreservesBudgetsCleanupAndSnapshotChecks() throws {
        let p = SearchRemote(); p.add("/scope/a", bytes: Data([0, 0xFF, 0xFE])); p.add("/scope/b", bytes: Data([0, 0xFF, 0xFE]))
        var options = request().options; options.contentMode = .hex; options.contentQuery = "FF FE"
        options.contentEncoding = .utf16BE
        let result = collectRemote(p, request: SearchRequest(options: options), limits: ProviderSearchLimits(maximumTotalContentBytes: 3))
        #expect(result.0.errors == 1); #expect(result.1.count == 1)
        #expect(result.1.first?.byteOffset == 1); #expect(result.1.first?.lineNumber == nil)
        #expect(p.localCopies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        p.onDownload = { p.add("/scope/a", bytes: Data([1, 0xFF, 0xFE])) }
        let changed = collectRemote(p, root: "/scope/a", request: SearchRequest(options: options))
        #expect(changed.0.errors == 1); #expect(changed.1.isEmpty)
    }
    @Test func providerHexRejectsInvalidQueriesAndLimitsBeforeIO() throws {
        let p = SearchRemote(); p.add("/scope/binary", bytes: Data([0, 0xFF]))
        var options = request().options; options.contentMode = .hex; options.contentQuery = "0xFF"
        let invalid = collectRemote(p, request: SearchRequest(options: options))
        #expect(invalid.0.errors == 1); #expect(p.listed.isEmpty); #expect(p.downloaded.isEmpty)
        options.contentQuery = "00 FF"; options.maximumContentBytes = 65 * 1_048_576
        #expect(throws: (any Error).self) { try ProviderSearchEngine.validate(SearchRequest(options: options)) }
        options.maximumContentBytes = 1
        let capped = collectRemote(p, request: SearchRequest(options: options))
        #expect(capped.0.errors == 1); #expect(capped.1.isEmpty); #expect(p.downloaded.isEmpty)
    }
    @Test func remoteHexCancellationRemovesCopyWithoutEmittingMatch() throws {
        let p = SearchRemote(); p.add("/scope/binary", bytes: Data([0, 0xFF]))
        var options = request().options; options.contentMode = .hex; options.contentQuery = "00 FF"
        let token = ProviderSearchCancellation(); p.onDownload = { token.cancel() }
        let result = collectRemote(p, request: SearchRequest(options: options), cancellation: token)
        #expect(result.0.cancelled); #expect(result.0.errors == 0); #expect(result.1.isEmpty)
        #expect(p.localCopies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    @Test func invalidProviderOptionsAreRejectedBeforeIO() throws {
        let p = SearchRemote()
        var options = request(content: "x").options; options.maximumContentBytes = 65 * 1024 * 1024
        #expect(collectRemote(p, request: SearchRequest(options: options)).0.errors == 1)
        #expect(p.listed.isEmpty)
        options.maximumContentBytes = 1024; options.contentMode = .regex; options.contentQuery = "["
        #expect(throws: (any Error).self) { try ProviderSearchEngine.validate(SearchRequest(options: options)) }
    }
}

private final class SearchRemote: RemoteSearchDownloadProvider {
    var connection = NetworkConnection(kind: .sftp, host: "example.test", username: "tester")
    var entries: [String: RemoteEntry] = ["/scope": RemoteEntry(path: "/scope", isDirectory: true, size: 0)]
    var files: [String: Data] = [:]
    var listOverride: [RemoteEntry]?
    var listed: [String] = [], downloaded: [String] = []
    var localCopies: [URL] = []
    var onDownload: (() -> Void)?
    var sawTransferCancellation = false
    func add(_ path: String, text: String = "", directory: Bool = false, link: Bool = false) {
        add(path, bytes: Data(text.utf8), directory: directory, link: link)
    }
    func add(_ path: String, bytes: Data, directory: Bool = false, link: Bool = false) {
        files[path] = bytes
        entries[path] = RemoteEntry(path: path, isDirectory: directory, isSymbolicLink: link, size: Int64(bytes.count), version: UUID().uuidString)
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        listed.append(path)
        return listOverride ?? entries.values.filter { RemotePath.parent($0.path) == path && $0.path != path }.sorted { $0.path < $1.path }
    }
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? { entries[path] }
    func searchDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        downloaded.append(path); localCopies.append(to)
        let bytes = files[path] ?? Data()
        guard bytes.count <= maximumBytes else { throw NetworkError.limitExceeded("fixture cap") }
        try bytes.write(to: to)
        onDownload?()
        sawTransferCancellation = cancellation.isCancelled
        if cancellation.isCancelled { throw NetworkError.cancelled }
        progress(NetworkProgress(path: path, completedBytes: Int64(bytes.count), totalBytes: Int64(bytes.count)))
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("Unbounded search download forbidden") }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { throw NetworkError.unsupported("No mutations") }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No mutations") }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No mutations") }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("No mutations") }
}
