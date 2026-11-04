import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite final class RemoteDirectoryTransferTests {
    @Test func previewAndNewTreeDownloadIncludeEmptyDirectoriesWithoutMutation() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }
        f.provider.tree()
        let plan = try f.download(.requireNew)
        #expect(plan.fileCount == 2 && plan.directoryCount == 3 && plan.totalBytes == 7)
        #expect(plan.copies.map(\.source) == ["/tree"] && plan.skipped.isEmpty)
        #expect(f.provider.downloads == 0 && f.provider.mutations == 0)
        let report = try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan)
        #expect(report.completed == plan.copies)
        #expect(try Data(contentsOf: f.local.appendingPathComponent("tree/sub/b")) == Data("four".utf8))
        #expect(FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree/empty").path))
        #expect(f.provider.files["/tree/sub/b"] == Data("four".utf8) && f.provider.mutations == 0)
    }

    @Test func mergeDownloadSkipsFilesAndTypeConflictsAndPreservesDestinationOnlyChildren() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        try f.directory("tree/sub"); try f.write("tree/a", "keep"); try f.write("tree/sub/local-only", "local")
        try f.write("tree/empty", "conflicting file")
        let plan = try f.download(.mergeSkippingExisting)
        #expect(Set(plan.copies.map(\.source)) == ["/tree/sub/b"])
        #expect(Set(plan.skipped.map(\.source)) == ["/tree/a", "/tree/empty"])
        _ = try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan)
        #expect(try f.read("tree/a") == "keep" && f.read("tree/empty") == "conflicting file")
        #expect(try f.read("tree/sub/b") == "four" && f.read("tree/sub/local-only") == "local")
        #expect(throws: (any Error).self) { try f.download(.requireNew) }
    }

    @Test func uploadNewTreeAndMergeSkipHaveVerifiedBytesAndRetainLocalSource() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }
        try f.directory("tree/sub"); try f.directory("tree/empty"); try f.write("tree/a", "one"); try f.write("tree/sub/b", "four")
        let plan = try f.upload(.requireNew)
        #expect(f.provider.mutations == 0)
        _ = try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan)
        #expect(f.provider.files["/tree/a"] == Data("one".utf8) && f.provider.directories.contains("/tree/empty"))
        try f.write("tree/a", "new local version"); try f.write("tree/sub/c", "added")
        f.provider.file("/tree/server-only", "keep")
        let merge = try f.upload(.mergeSkippingExisting)
        #expect(Set(merge.skipped.map(\.destination)) == ["/tree/a", "/tree/sub/b"])
        #expect(merge.copies.count == 1 && merge.copies.first?.destination == "/tree/sub/c")
        _ = try RemoteDirectoryTransfer.copy(provider: f.provider, plan: merge)
        #expect(f.provider.files["/tree/a"] == Data("one".utf8) && f.provider.files["/tree/sub/c"] == Data("added".utf8))
        #expect(f.provider.files["/tree/server-only"] == Data("keep".utf8))
        #expect(try f.read("tree/a") == "new local version")
    }

    @Test func sourceChangeAfterPreviewStopsBeforeAllDestinationWrites() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        let plan = try f.download(.requireNew)
        f.provider.file("/tree/new", "new child")
        let error = try failure { try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan) }
        #expect(error.report.completed.isEmpty && !error.outcomeUnknown && f.provider.downloads == 0)
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree").path))
        try f.directory("tree"); try f.write("tree/a", "before")
        let upload = try f.upload(.mergeSkippingExisting)
        try f.write("tree/a", "after!")
        let localError = try failure { try RemoteDirectoryTransfer.copy(provider: f.provider, plan: upload) }
        #expect(localError.report.completed.isEmpty && f.provider.mutations == 0)
    }

    @Test func sourceChangeDuringFreezeStopsBeforePublication() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        let plan = try f.download(.requireNew)
        f.provider.afterDownload = { f.provider.file("/tree/new", "late") }
        let error = try failure { try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan) }
        #expect(error.report.completed.isEmpty && !FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree").path))
    }

    @Test func cancellationDuringFreezePublishesNothing() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        let plan = try f.download(.requireNew), token = TransferCancellation()
        f.provider.afterDownload = { token.cancel() }
        let error = try failure { try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan, cancellation: token) }
        #expect(error.report.completed.isEmpty && !error.outcomeUnknown)
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree").path))
    }

    @Test func cancellationAfterFirstPublicationReportsExactRetainedPartialResult() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree(); try f.directory("tree")
        let plan = try f.download(.mergeSkippingExisting), token = TransferCancellation()
        let error = try failure {
            try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan, cancellation: token) { update in
                if update.path.hasPrefix("Скопировано поддеревьев 1/") { token.cancel() }
            }
        }
        #expect(error.report.completed.count == 1 && !error.outcomeUnknown)
        #expect(FileManager.default.fileExists(atPath: error.report.completed[0].destination))
        #expect(f.provider.files["/tree/a"] != nil && f.provider.mutations == 0)
    }

    @Test func newDestinationAfterPreviewAndBetweenPublicationsIsNeverReplaced() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree(); try f.directory("tree")
        let plan = try f.download(.mergeSkippingExisting)
        let second = try #require(plan.copies.dropFirst().first)
        let error = try failure {
            try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan) { update in
                if update.path.hasPrefix("Скопировано поддеревьев 1/") { try? Data("racer".utf8).write(to: URL(fileURLWithPath: second.destination)) }
            }
        }
        #expect(error.report.completed.count == 1 && !error.outcomeUnknown)
        #expect(try Data(contentsOf: URL(fileURLWithPath: second.destination)) == Data("racer".utf8))
    }

    @Test func serverNoReplaceAndLostRenameResponsePreserveOriginalAndReportUncertainty() throws {
        for loseResponse in [false, true] {
            let f = try DirectoryTransferFixture(); defer { f.cleanup() }
            try f.directory("tree"); try f.write("tree/a", "copy")
            let plan = try f.upload(.requireNew)
            if loseResponse { f.provider.loseRenameResponse = true }
            else { f.provider.beforeRename = { f.provider.file("/tree", "racer") } }
            let error = try failure { try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan) }
            #expect(error.report.completed.isEmpty && error.outcomeUnknown)
            #expect(try f.read("tree/a") == "copy")
            if loseResponse { #expect(f.provider.files["/tree/a"] == Data("copy".utf8)) }
            else { #expect(f.provider.files["/tree"] == Data("racer".utf8)) }
        }
    }

    @Test func uploadReadbackFailureDoesNotPublishCorruptTree() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }
        try f.directory("tree"); try f.write("tree/a", "data")
        let plan = try f.upload(.requireNew); f.provider.corruptUpload = true
        _ = try failure { try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan) }
        #expect(f.provider.files["/tree/a"] == nil && !f.provider.directories.contains("/tree"))
        #expect(try f.read("tree/a") == "data")
    }

    @Test func linksUnsafeListingsAndForeignProvidersAreRefused() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        f.provider.links.insert("/tree/a")
        #expect(throws: (any Error).self) { try f.download(.requireNew) }
        f.provider.links.removeAll()
        f.provider.overrideListing = [RemoteEntry(path: "/outside", isDirectory: false, size: 0)]
        #expect(throws: (any Error).self) { try f.download(.requireNew) }
        f.provider.overrideListing = nil
        let plan = try f.download(.requireNew)
        let other = DirectoryTransferRemote(connection: f.provider.connection)
        #expect(throws: RemoteDirectoryTransferFailure.self) { try RemoteDirectoryTransfer.copy(provider: other, plan: plan) }
        try f.directory("tree"); try FileManager.default.createSymbolicLink(atPath: f.local.appendingPathComponent("tree/link").path, withDestinationPath: "/etc/hosts")
        #expect(throws: (any Error).self) { try f.upload(.mergeSkippingExisting) }
        #expect(f.provider.mutations == 0)
    }

    @Test func depthByteAndCancellationBoundsRejectReadOnlyPreview() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        let token = TransferCancellation(); token.cancel()
        #expect(throws: (any Error).self) { try RemoteDirectoryTransfer.prepareDownload(provider: f.provider, entries: [f.provider.entry("/tree")], into: f.local, policy: .requireNew, cancellation: token) }
        f.provider.overrideListing = [RemoteEntry(path: "/tree/huge", isDirectory: false, size: RemoteTransferLimits.maximumBytes + 1)]
        f.provider.overrides["/tree/huge"] = f.provider.overrideListing?[0]
        #expect(throws: (any Error).self) { try f.download(.requireNew) }
        f.provider.overrideListing = nil
        var path = "/deep"; f.provider.directories.insert(path)
        for _ in 0...RemoteTransferLimits.maximumDepth { path += "/d"; f.provider.directories.insert(path) }
        #expect(throws: (any Error).self) { try RemoteDirectoryTransfer.prepareDownload(provider: f.provider, entries: [f.provider.entry("/deep")], into: f.local, policy: .requireNew) }
        #expect(f.provider.mutations == 0 && f.provider.downloads == 0)
    }

    @Test func localDestinationSymlinkAndUnsupportedFTPServerNeverReceiveTreeWrites() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        try f.directory("outside")
        try FileManager.default.createSymbolicLink(at: f.local.appendingPathComponent("tree"), withDestinationURL: f.local.appendingPathComponent("outside"))
        let plan = try f.download(.mergeSkippingExisting)
        #expect(plan.copies.isEmpty && plan.skipped.map(\.source) == ["/tree"])
        _ = try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.local.appendingPathComponent("outside").path).isEmpty)
        let ftp = FTPRemoteProvider(connection: NetworkConnection(kind: .ftp, host: "unused.invalid"), password: nil)
        #expect(throws: (any Error).self) { try RemoteDirectoryTransfer.prepareUpload(provider: ftp, sources: [f.local.appendingPathComponent("outside")], into: "/", policy: .requireNew) }
    }

    @Test func skippedTreesAreNotDownloadedAndTransferBytesExcludeConflicts() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        try f.directory("tree/sub"); try f.directory("tree/empty"); try f.write("tree/a", "keep"); try f.write("tree/sub/b", "keep too")
        let plan = try f.download(.mergeSkippingExisting)
        #expect(plan.copies.isEmpty && plan.skipped.count == 2 && plan.transferBytes == 0 && plan.totalBytes == 7)
        _ = try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan)
        #expect(f.provider.downloads == 0)
    }

    @Test func namesCollidingByCaseOrUnicodeNeverReachDownloadOrPublication() throws {
        for names in [["A", "a"], ["é", "e\u{301}"]] {
            let f = try DirectoryTransferFixture(); defer { f.cleanup() }
            f.provider.directories.insert("/tree")
            // Explicit listing keeps both spellings even when Swift Dictionary
            // treats canonically equivalent Unicode keys as the same key.
            f.provider.overrideListing = names.map { RemoteEntry(path: "/tree/" + $0, isDirectory: false, size: 4) }
            for name in names { f.provider.file("/tree/" + name, "data") }
            #expect(throws: (any Error).self) { try f.download(.requireNew) }
            #expect(f.provider.downloads == 0 && !FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree").path))
        }
    }

    @Test func providerSizeLieIsBoundedAndCannotPublishExcessData() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }; f.provider.tree()
        f.provider.overrides["/tree/a"] = RemoteEntry(path: "/tree/a", isDirectory: false, size: 1)
        let plan = try f.download(.requireNew)
        let error = try failure { try RemoteDirectoryTransfer.copy(provider: f.provider, plan: plan) }
        #expect(error.report.completed.isEmpty && !error.outcomeUnknown && f.provider.downloads == 0)
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree").path))
    }

    @Test func replacedFIFOAtReviewedOpenBoundaryCannotBlockOrReadDifferentInode() throws {
        let f = try DirectoryTransferFixture(); defer { f.cleanup() }
        let url = f.local.appendingPathComponent("regular")
        try Data("reviewed".utf8).write(to: url)
        let stamp = try LocalRemoteStamp(url)
        try FileManager.default.removeItem(at: url)
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try stamp.openForReading(url) }
        try FileManager.default.removeItem(at: url)
        try Data("different inode".utf8).write(to: url)
        #expect(throws: (any Error).self) { try stamp.openForReading(url) }
    }

    private func failure(_ work: () throws -> RemoteDirectoryTransferReport) throws -> RemoteDirectoryTransferFailure {
        do { _ = try work(); throw NetworkError.io("Expected a directory transfer failure") }
        catch let error as RemoteDirectoryTransferFailure { return error }
    }
}

private final class DirectoryTransferFixture {
    let provider = DirectoryTransferRemote()
    let local: URL
    init() throws {
        local = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("farmac-directory-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: local) }
    func directory(_ path: String) throws { try FileManager.default.createDirectory(at: local.appendingPathComponent(path), withIntermediateDirectories: true) }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: local.appendingPathComponent(path)) }
    func read(_ path: String) throws -> String { try String(contentsOf: local.appendingPathComponent(path), encoding: .utf8) }
    func download(_ policy: RemoteDirectoryConflictPolicy) throws -> RemoteDirectoryTransferPlan {
        try RemoteDirectoryTransfer.prepareDownload(provider: provider, entries: [provider.entry("/tree")], into: local, policy: policy)
    }
    func upload(_ policy: RemoteDirectoryConflictPolicy) throws -> RemoteDirectoryTransferPlan {
        try RemoteDirectoryTransfer.prepareUpload(provider: provider, sources: [local.appendingPathComponent("tree")], into: "/", policy: policy)
    }
}

private final class DirectoryTransferRemote: RemoteNoReplaceRenameProvider, RemoteBoundedDownloadProvider {
    let connection: NetworkConnection
    var files: [String: Data] = [:], directories: Set<String> = ["/"], links = Set<String>()
    var overrides: [String: RemoteEntry] = [:], overrideListing: [RemoteEntry]?
    var versions: [String: Int] = [:]
    var downloads = 0, mutations = 0
    var corruptUpload = false, loseRenameResponse = false
    var afterDownload: (() -> Void)?, beforeRename: (() -> Void)?
    init(connection: NetworkConnection = NetworkConnection(kind: .webdav, host: "example.test")) { self.connection = connection }
    func file(_ path: String, _ value: String) { files[path] = Data(value.utf8); versions[path, default: 0] += 1 }
    func tree() { directories.formUnion(["/tree", "/tree/sub", "/tree/empty"]); file("/tree/a", "one"); file("/tree/sub/b", "four") }
    func entry(_ path: String) -> RemoteEntry { try! stat(path: path, cancellation: TransferCancellation())! }
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        if let value = overrides[path] { return value }
        guard files[path] != nil || directories.contains(path) else { return nil }
        return RemoteEntry(path: path, isDirectory: directories.contains(path), isSymbolicLink: links.contains(path), size: Int64(files[path]?.count ?? 0), version: files[path] == nil ? nil : "\"\(versions[path, default: 0])\"")
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        if let overrideListing { return overrideListing }
        return try (Array(files.keys) + Array(directories)).filter { $0 != path && RemotePath.parent($0) == path }.map { try stat(path: $0, cancellation: cancellation)! }
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        downloads += 1
        guard let data = files[path] else { throw NetworkError.notFound(path) }
        try data.write(to: to); progress(NetworkProgress(path: path, completedBytes: Int64(data.count), totalBytes: Int64(data.count))); afterDownload?()
    }
    func boundedDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        guard Int64(files[path]?.count ?? 0) <= maximumBytes else { throw NetworkError.limitExceeded("bounded download") }
        try download(path: path, to: to, resumeOffset: 0, cancellation: cancellation, progress: progress)
    }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        mutations += 1
        var data = try Data(contentsOf: from); if corruptUpload && !data.isEmpty { data[0] ^= 1 }
        files[to] = data
    }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        beforeRename?()
        guard replace || (!directories.contains(to) && files[to] == nil) else { throw NetworkError.conflict(to) }
        mutations += 1
        if let value = files.removeValue(forKey: from) { files[to] = value }
        else if directories.remove(from) != nil {
            directories.insert(to)
            for path in Array(files.keys) where path.hasPrefix(from + "/") { files[to + path.dropFirst(from.count)] = files.removeValue(forKey: path) }
            for path in Array(directories) where path.hasPrefix(from + "/") { directories.insert(to + path.dropFirst(from.count)); directories.remove(path) }
        } else { throw NetworkError.notFound(from) }
        if loseRenameResponse { throw NetworkError.connectionFailed("lost rename response") }
    }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { mutations += 1; guard !directories.contains(path) && files[path] == nil else { throw NetworkError.conflict(path) }; directories.insert(path) }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws { throw NetworkError.unsupported("Source deletion forbidden in copy worker") }
}
