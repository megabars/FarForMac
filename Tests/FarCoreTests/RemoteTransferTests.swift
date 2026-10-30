import Foundation
import Testing
@testable import FarCore

@Suite final class RemoteTransferTests {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name); try Data(text.utf8).write(to: url); return url
    }
    @Test func testDownloadNeverOverwritesExistingDestinationWithoutDecision() throws {
        let provider = MemoryRemote(); provider.files["/source"] = Data("new".utf8)
        let destination = try file("dest", "original")
        XCTAssertThrowsError(try RemoteTransferEngine.download(provider: provider, path: "/source", to: destination))
        XCTAssertEqual(try String(contentsOf: destination), "original")
        XCTAssertTrue(provider.removed.isEmpty)
    }
    @Test func testDownloadRestartsRatherThanAppendingUnprovenPartial() throws {
        let provider = MemoryRemote(); provider.files["/source"] = Data("complete".utf8)
        let destination = try file("dest", "partial-from-another-file")
        try RemoteTransferEngine.download(provider: provider, path: "/source", to: destination, replace: true)
        XCTAssertEqual(try String(contentsOf: destination), "complete")
        XCTAssertEqual(provider.offsets, [0])
    }
    @Test func testCorruptUploadStageDoesNotPublishOrDeleteLocalSource() throws {
        let provider = MemoryRemote(); provider.corruptUpload = true
        let source = try file("source", "expected")
        XCTAssertThrowsError(try RemoteTransferEngine.upload(provider: provider, from: source, to: "/target", move: true))
        XCTAssertNil(provider.files["/target"])
        XCTAssertEqual(try String(contentsOf: source), "expected")
        XCTAssertTrue(provider.renamed.isEmpty)
    }
    @Test func testRemoteEditDetectsSameSizeSameMetadataByteChange() throws {
        let provider = MemoryRemote(); provider.files["/edit"] = Data("before".utf8)
        let workspace = try RemoteWorkspace(parent: directory)
        let snapshot = try workspace.open(provider: provider, path: "/edit")
        try Data("myedit".utf8).write(to: snapshot.localURL)
        provider.files["/edit"] = Data("others".utf8)
        XCTAssertThrowsError(try workspace.commit(snapshot, provider: provider))
        XCTAssertEqual(provider.files["/edit"], Data("others".utf8))
        XCTAssertEqual(try String(contentsOf: snapshot.localURL), "myedit")
    }
    @Test func testRemoteEditCommitRefreshesBaseForAnotherSave() throws {
        let provider = MemoryRemote(); provider.files["/edit"] = Data("initial".utf8)
        let workspace = try RemoteWorkspace(parent: directory)
        let snapshot = try workspace.open(provider: provider, path: "/edit")
        try Data("second".utf8).write(to: snapshot.localURL)
        let updated = try workspace.commit(snapshot, provider: provider)
        try Data("third".utf8).write(to: updated.localURL)
        _ = try workspace.commit(updated, provider: provider)
        XCTAssertEqual(provider.files["/edit"], Data("third".utf8))
        XCTAssertTrue(provider.removed.isEmpty)
    }
    @Test func testUploadMovePreservesChangedSourceAfterPublication() throws {
        let provider = MemoryRemote()
        let source = try file("source", "original")
        provider.onRename = { try? Data("modified".utf8).write(to: source) }
        XCTAssertThrowsError(try RemoteTransferEngine.upload(provider: provider, from: source, to: "/target", move: true))
        XCTAssertEqual(provider.files["/target"], Data("original".utf8))
        XCTAssertEqual(try String(contentsOf: source), "modified")
    }
    @Test func testRecursiveCopyAndMaliciousListingRejection() throws {
        let provider = MemoryRemote(); provider.directories.insert("/folder"); provider.files["/folder/file"] = Data("nested".utf8)
        let target = directory.appendingPathComponent("folder")
        try RemoteTransferEngine.download(provider: provider, path: "/folder", to: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("file")), "nested")
        provider.listingOverride = [RemoteEntry(path: "/escape", isDirectory: false, size: 0)]
        XCTAssertThrowsError(try RemoteTransferEngine.download(provider: provider, path: "/folder", to: directory.appendingPathComponent("other")))
    }
    @Test func testCancellationDoesNotRemoveEitherSource() throws {
        let provider = MemoryRemote(); provider.files["/source"] = Data("source".utf8)
        let cancellation = TransferCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try RemoteTransferEngine.download(provider: provider, path: "/source", to: directory.appendingPathComponent("target"), move: true, cancellation: cancellation))
        XCTAssertTrue(provider.removed.isEmpty)
    }
    @Test func testLongRemoteNameKeepsBoundedLocalNameAndExtension() throws {
        let provider = MemoryRemote()
        let path = "/" + String(repeating: "a", count: 250) + ".txt"
        provider.files[path] = Data("text".utf8)
        let workspace = try RemoteWorkspace(parent: directory)
        let snapshot = try workspace.open(provider: provider, path: path)
        XCTAssertTrue(snapshot.localURL.lastPathComponent.utf8.count <= 255)
        XCTAssertEqual(snapshot.localURL.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: snapshot.localURL), "text")
    }
    @Test func testFailedStageReportsRecoverableRemotePath() throws {
        let provider = MemoryRemote(); provider.corruptUpload = true
        let source = try file("source", "expected")
        do {
            try RemoteTransferEngine.upload(provider: provider, from: source, to: "/target")
            Issue.record("Expected corrupt stage rejection")
        } catch {
            let stage = try #require(provider.files.keys.first(where: { $0.hasPrefix("/.farmac-upload-") }))
            #expect(error.localizedDescription.contains(stage))
        }
    }
    @Test func testDeclaredOversizeDownloadStopsBeforeReading() throws {
        let provider = MemoryRemote()
        provider.statOverride["/huge"] = RemoteEntry(path: "/huge", isDirectory: false, size: RemoteTransferLimits.maximumBytes + 1)
        XCTAssertThrowsError(try RemoteTransferEngine.download(provider: provider, path: "/huge", to: directory.appendingPathComponent("huge")))
        XCTAssertTrue(provider.offsets.isEmpty)
    }
    @Test func testWorkspaceCleanupIsIdempotentAndDoesNotFollowLinks() throws {
        let outside = try file("outside", "retained")
        let workspace = try RemoteWorkspace(parent: directory)
        let nested = workspace.directory.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: nested.path)
        workspace.cleanup(); workspace.cleanup()
        XCTAssertTrue(!FileManager.default.fileExists(atPath: workspace.directory.path))
        XCTAssertEqual(try String(contentsOf: outside), "retained")
    }
    @Test func testStrongDAVResumeUsesOwnedPrefixAndExactVersion() throws {
        let provider = FaultConditionalRemote()
        provider.files["/source"] = Data("hello remote world".utf8)
        let target = directory.appendingPathComponent("target")
        let task = try RemoteDownloadTask(provider: provider, path: "/source", destination: target)
        defer { task.cleanup() }
        XCTAssertThrowsError(try task.run())
        #expect(task.canResume && task.partialBytes == 6)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try task.run()
        #expect(provider.conditionalOffsets == [0, 6])
        #expect(try Data(contentsOf: target) == Data("hello remote world".utf8))
        #expect(!task.canResume)
    }
    @Test func testResumeRefusesChangedRemoteETag() throws {
        let provider = FaultConditionalRemote()
        provider.files["/source"] = Data("hello remote world".utf8)
        let target = directory.appendingPathComponent("target")
        let task = try RemoteDownloadTask(provider: provider, path: "/source", destination: target)
        defer { task.cleanup() }
        XCTAssertThrowsError(try task.run())
        provider.etag = "\"v2\""
        XCTAssertThrowsError(try task.run())
        #expect(provider.conditionalOffsets == [0] && !task.canResume)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
    @Test func testResumeRefusesTamperedPrivatePartial() throws {
        let provider = FaultConditionalRemote()
        provider.files["/source"] = Data("hello remote world".utf8)
        let target = directory.appendingPathComponent("target")
        let task = try RemoteDownloadTask(provider: provider, path: "/source", destination: target)
        defer { task.cleanup() }
        XCTAssertThrowsError(try task.run())
        try Data("poison".utf8).write(to: task.partialURL)
        XCTAssertThrowsError(try task.run())
        #expect(provider.conditionalOffsets == [0] && !task.canResume)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
    @Test func testResumeDoesNotOverwriteLocalTargetChangedAfterTaskCreation() throws {
        let provider = FaultConditionalRemote()
        provider.files["/source"] = Data("hello remote world".utf8)
        let target = try file("target", "original")
        let task = try RemoteDownloadTask(provider: provider, path: "/source", destination: target, replace: true)
        defer { task.cleanup() }
        XCTAssertThrowsError(try task.run())
        try Data("updated!".utf8).write(to: target)
        XCTAssertThrowsError(try task.run())
        #expect(provider.conditionalOffsets == [0])
        #expect(try String(contentsOf: target) == "updated!")
    }
    @Test func testFTPDownloadTaskRetryRestartsInsteadOfAppending() throws {
        let provider = RestartingRemote()
        provider.files["/source"] = Data("hello remote world".utf8)
        let target = directory.appendingPathComponent("target")
        let task = try RemoteDownloadTask(provider: provider, path: "/source", destination: target)
        defer { task.cleanup() }
        XCTAssertThrowsError(try task.run())
        #expect(!task.canResume)
        try task.run()
        #expect(provider.offsets == [0, 0])
        #expect(try Data(contentsOf: target) == Data("hello remote world".utf8))
    }
    @Test func testExplicitDeleteRefusesNonemptyDirectory() throws {
        let provider = MemoryRemote(); provider.directories.insert("/folder"); provider.files["/folder/file"] = Data()
        let entry = try XCTUnwrap(provider.stat(path: "/folder", cancellation: TransferCancellation()))
        XCTAssertThrowsError(try RemoteTransferEngine.delete(provider: provider, entry: entry))
        XCTAssertTrue(provider.removed.isEmpty)
    }
}

private class MemoryRemote: RemoteProvider {
    let connection: NetworkConnection
    init(connection: NetworkConnection = NetworkConnection(kind: .ftp, host: "example.test")) { self.connection = connection }
    var files: [String: Data] = [:]
    var statOverride: [String: RemoteEntry] = [:]
    var directories: Set<String> = ["/"]
    var offsets: [Int64] = []
    var removed: [String] = []
    var renamed: [String] = []
    var corruptUpload = false
    var listingOverride: [RemoteEntry]?
    var onRename: (() -> Void)?
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        if let entry = statOverride[path] { return entry }
        if let data = files[path] { return RemoteEntry(path: path, isDirectory: false, size: Int64(data.count), modified: Date(timeIntervalSince1970: 1)) }
        if directories.contains(path) { return RemoteEntry(path: path, isDirectory: true, size: 0) }
        return nil
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        if let listingOverride { return listingOverride }
        return try (Array(files.keys) + Array(directories)).filter { $0 != path && RemotePath.parent($0) == path }.map { try stat(path: $0, cancellation: cancellation)! }
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        offsets.append(resumeOffset)
        guard let data = files[path] else { throw NetworkError.notFound(path) }
        try data.write(to: to)
        progress(NetworkProgress(path: path, completedBytes: Int64(data.count), totalBytes: Int64(data.count)))
    }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        var data = try Data(contentsOf: from)
        if corruptUpload, !data.isEmpty { data[0] ^= 1 }
        files[to] = data
    }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        if !replace, files[to] != nil || directories.contains(to) { throw NetworkError.conflict(to) }
        if let data = files.removeValue(forKey: from) { files[to] = data }
        else if directories.remove(from) != nil {
            directories.insert(to)
            for key in Array(files.keys) where key.hasPrefix(from + "/") { files[to + key.dropFirst(from.count)] = files.removeValue(forKey: key) }
            for key in Array(directories) where key.hasPrefix(from + "/") { directories.insert(to + key.dropFirst(from.count)); directories.remove(key) }
        } else { throw NetworkError.notFound(from) }
        renamed.append(to); onRename?()
    }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws { removed.append(path); files.removeValue(forKey: path); directories.remove(path) }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { directories.insert(path) }
}

private func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { #expect(actual == expected) }
private func XCTAssertTrue(_ value: Bool) { #expect(value) }
private func XCTAssertNil<T>(_ value: T?) { #expect(value == nil) }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) {
    do { _ = try expression(); Issue.record("Expected operation to throw") } catch { }
}
private func XCTUnwrap<T>(_ value: T?) throws -> T { try #require(value) }

private final class FaultConditionalRemote: MemoryRemote, RemoteConditionalDownloadProvider {
    var etag = "\"v1\""
    var conditionalOffsets: [Int64] = []
    init() { super.init(connection: NetworkConnection(kind: .webdav, host: "example.test")) }
    override func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        guard let entry = try super.stat(path: path, cancellation: cancellation) else { return nil }
        return RemoteEntry(path: entry.path, isDirectory: entry.isDirectory, size: entry.size, modified: entry.modified, version: etag)
    }
    func conditionalDownload(path: String, to: URL, resumeOffset: Int64, expectedVersion: String,
                             cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        guard expectedVersion == etag else { throw NetworkError.changedSource }
        conditionalOffsets.append(resumeOffset)
        let data = try #require(files[path])
        let file = try FileHandle(forWritingTo: to)
        defer { try? file.close() }
        if resumeOffset == 0 { try file.truncate(atOffset: 0) }
        try file.seek(toOffset: UInt64(resumeOffset))
        if conditionalOffsets.count == 1 {
            try file.write(contentsOf: data.prefix(6))
            throw NetworkError.connectionFailed("Deterministic disconnect after authenticated prefix")
        }
        try file.write(contentsOf: data.dropFirst(Int(resumeOffset)))
    }
}

private final class RestartingRemote: MemoryRemote {
    override func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation,
                           progress: @escaping (NetworkProgress) -> Void) throws {
        offsets.append(resumeOffset)
        let data = try #require(files[path])
        if offsets.count == 1 {
            try data.prefix(6).write(to: to)
            throw NetworkError.connectionFailed("Deterministic FTP disconnect")
        }
        try data.write(to: to)
    }
}
