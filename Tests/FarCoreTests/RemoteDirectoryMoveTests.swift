import Foundation
import Testing
@testable import FarCore

@Suite final class RemoteDirectoryMoveTests {
    @Test func downloadMoveVerifiesBytesAndRemovesOnlyExactNodesInPostorder() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download()
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan)
        #expect(report.moving && report.failedSourceRemovals.isEmpty && report.retainedSources.isEmpty)
        #expect(Set(report.removedSources) == ["/tree/a", "/tree/sub/b", "/tree/sub", "/tree/empty", "/tree"])
        #expect(try f.read("tree/a") == "one" && f.read("tree/sub/b") == "four")
        #expect(!f.remote.directories.contains("/tree"))
        #expect(f.remote.removals.last == "/tree")
        #expect(f.remote.removals.firstIndex(of: "/tree/sub/b")! < f.remote.removals.firstIndex(of: "/tree/sub")!)
    }

    @Test func uploadMoveRemovesVerifiedLocalTreeAfterRemotePublication() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; try f.localTree()
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: f.upload())
        #expect(report.moving && report.retainedSources.isEmpty && report.failedSourceRemovals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree").path))
        #expect(f.remote.files["/tree/a"] == Data("one".utf8) && f.remote.files["/tree/sub/b"] == Data("four".utf8))
        #expect(f.remote.directories.contains("/tree/empty"))
    }

    @Test func mergeMoveRetainsSkippedSourceAndItsNonemptyAncestors() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        try f.directory("tree"); try f.write("tree/a", "keep local")
        let plan = try f.download(.mergeSkippingExisting)
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan)
        #expect(report.skipped.map(\.source) == ["/tree/a"])
        #expect(report.retainedSources.contains("/tree/a") && report.retainedSources.contains("/tree"))
        #expect(f.remote.files["/tree/a"] == Data("one".utf8) && f.remote.files["/tree/sub/b"] == nil)
        #expect(f.remote.directories.contains("/tree"))
        #expect(try f.read("tree/a") == "keep local" && f.read("tree/sub/b") == "four")
    }

    @Test func uploadMergeMoveRetainsSkippedLocalFileAndRemovesOnlyCopiedChildren() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; try f.localTree()
        f.remote.directories.insert("/tree"); f.remote.file("/tree/a", "keep server")
        let plan = try f.upload(.mergeSkippingExisting)
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan)
        #expect(try f.read("tree/a") == "one")
        #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree/sub/b").path))
        #expect(report.retainedSources.contains(plan.roots[0].source + "/a"))
        #expect(report.retainedSources.contains(plan.roots[0].source))
        #expect(f.remote.files["/tree/a"] == Data("keep server".utf8) && f.remote.files["/tree/sub/b"] == Data("four".utf8))
    }

    @Test func mergeMoveRemovesReviewedEmptySourceDirectoriesInBothDirections() throws {
        for download in [true, false] {
            let f = try DirectoryMoveFixture(); defer { f.cleanup() }
            try f.directory("tree/empty"); f.remote.directories.formUnion(["/tree", "/tree/empty"])
            let plan = try download ? f.download(.mergeSkippingExisting) : f.upload(.mergeSkippingExisting)
            #expect(plan.copies.isEmpty && plan.skipped.isEmpty)
            let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan)
            #expect(report.retainedSources.isEmpty && report.failedSourceRemovals.isEmpty)
            if download {
                #expect(!f.remote.directories.contains("/tree") && FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree/empty").path))
            } else {
                #expect(!FileManager.default.fileExists(atPath: f.local.appendingPathComponent("tree").path) && f.remote.directories.contains("/tree/empty"))
            }
        }
    }

    @Test func mergeDownloadResolvesReplaceRenameAndSkipWithoutLosingOtherChildren() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        f.remote.file("/tree/c", "remote c")
        try f.directory("tree/sub"); try f.write("tree/a", "old a"); try f.write("tree/sub/b", "old b")
        try f.write("tree/c", "old c"); try f.write("tree/local-only", "untouched")
        let preview = try f.download(.mergeSkippingExisting)
        #expect(Set(preview.conflicts.map { $0.mapping.source }) == ["/tree/a", "/tree/sub/b", "/tree/c"])
        let plan = try RemoteDirectoryTransfer.resolve(provider: f.remote, plan: preview,
            decisions: ["/tree/a": .replace, "/tree/sub/b": .rename("renamed b"), "/tree/c": .skip])
        _ = try RemoteDirectoryTransfer.copy(provider: f.remote, plan: plan)
        #expect(try f.read("tree/a") == "one" && f.read("tree/sub/b") == "old b")
        #expect(try f.read("tree/sub/renamed b") == "four" && f.read("tree/c") == "old c")
        #expect(try f.read("tree/local-only") == "untouched")
        #expect(f.remote.removals.isEmpty)
    }

    @Test func mergeUploadResolvesReplaceAndRenameAndRejectsTypeOverwrite() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; try f.localTree()
        f.remote.directories.formUnion(["/tree", "/tree/sub"])
        f.remote.file("/tree/a", "old a"); f.remote.file("/tree/sub/b", "old b")
        f.remote.file("/tree/empty", "a file must not become a directory")
        let preview = try f.upload(.mergeSkippingExisting)
        let typeConflict = try #require(preview.conflicts.first { $0.mapping.source.hasSuffix("/empty") })
        let aConflict = try #require(preview.conflicts.first { $0.mapping.source.hasSuffix("/a") })
        let bConflict = try #require(preview.conflicts.first { $0.mapping.source.hasSuffix("/sub/b") })
        #expect(!typeConflict.canReplace)
        #expect(throws: (any Error).self) {
            try RemoteDirectoryTransfer.resolve(provider: f.remote, plan: preview, decisions: [typeConflict.mapping.source: .replace])
        }
        let plan = try RemoteDirectoryTransfer.resolve(provider: f.remote, plan: preview,
            decisions: [aConflict.mapping.source: .replace,
                        bConflict.mapping.source: .rename("new b"),
                        typeConflict.mapping.source: .rename("new empty")])
        _ = try RemoteDirectoryTransfer.copy(provider: f.remote, plan: plan)
        #expect(f.remote.files["/tree/a"] == Data("one".utf8))
        #expect(f.remote.files["/tree/sub/b"] == Data("old b".utf8) && f.remote.files["/tree/sub/new b"] == Data("four".utf8))
        #expect(f.remote.files["/tree/empty"] == Data("a file must not become a directory".utf8))
        #expect(f.remote.directories.contains("/tree/new empty"))
    }

    @Test func cancellationBeforeCopyAndAfterPublicationPreservesEverySource() throws {
        for beforeCopy in [true, false] {
            let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
            let plan = try f.download(), token = TransferCancellation()
            if beforeCopy { token.cancel() }
            let error = try failure {
                try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan, cancellation: token) { update in
                    if !beforeCopy && update.path.hasPrefix("Скопировано поддеревьев") { token.cancel() }
                }
            }
            #expect(error.report.removedSources.isEmpty && f.remote.removals.isEmpty)
            #expect(f.remote.files["/tree/a"] == Data("one".utf8) && f.remote.files["/tree/sub/b"] == Data("four".utf8))
            #expect(error.report.completed.count == (beforeCopy ? 0 : 1))
        }
    }

    @Test func cancellationBetweenUnlinksReportsExactPartialMove() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download(), token = TransferCancellation()
        f.remote.afterRemove = { _ in token.cancel() }
        let error = try failure { try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan, cancellation: token) }
        #expect(error.report.completed.count == 1 && error.report.removedSources == f.remote.removals)
        #expect(error.report.removedSources.count == 1 && !error.report.retainedSources.isEmpty)
        #expect(f.remote.files.count > 0 && f.remote.directories.contains("/tree"))
    }

    @Test func changedSourceAndNewSourceChildAfterCopyAreRetained() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download()
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan) { update in
            if update.path.hasPrefix("Скопировано поддеревьев") {
                // Coarse or missing server timestamps can keep the metadata
                // snapshot identical even after a same-size content change.
                f.remote.files["/tree/a"] = Data("NEW".utf8); f.remote.file("/tree/new", "late arrival")
            }
        }
        #expect(f.remote.files["/tree/a"] == Data("NEW".utf8) && f.remote.files["/tree/new"] == Data("late arrival".utf8))
        #expect(report.retainedSources.contains("/tree/a") && report.retainedSources.contains("/tree"))
        #expect(report.failedSourceRemovals.contains { $0.source == "/tree/a" })
        #expect(try f.read("tree/a") == "one")
        #expect(!f.remote.removals.contains("/tree/a") && !f.remote.removals.contains("/tree"))
    }

    @Test func changedDestinationAfterCopyPreventsDeletionOfCorrespondingSource() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download()
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan) { update in
            if update.path.hasPrefix("Скопировано поддеревьев") { try? f.write("tree/a", "BAD") }
        }
        #expect(f.remote.files["/tree/a"] == Data("one".utf8))
        #expect(report.retainedSources.contains("/tree/a") && report.failedSourceRemovals.contains { $0.source == "/tree/a" })
        #expect(try f.read("tree/a") == "BAD")
    }

    @Test func cancellationAtFirstUnlinkBoundaryLeavesAllSourcesAndVerifiedCopy() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download(), token = TransferCancellation()
        let error = try failure {
            try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan, cancellation: token) { update in
                if update.path.hasPrefix("Удаление источника: ") { token.cancel() }
            }
        }
        #expect(error.report.completed.count == 1 && error.report.removedSources.isEmpty)
        #expect(f.remote.removals.isEmpty && f.remote.files["/tree/a"] == Data("one".utf8))
        #expect(try f.read("tree/a") == "one")
    }

    @Test func destinationChangedDuringFinalSourceReadbackIsPreservedAndSourceRetained() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download()
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan) { update in
            if update.path.hasPrefix("Скопировано поддеревьев") {
                f.remote.afterDownload = { path in if path == "/tree/a" { try? f.write("tree/a", "BAD") } }
            }
        }
        #expect(f.remote.files["/tree/a"] == Data("one".utf8))
        #expect(report.retainedSources.contains("/tree/a") && report.failedSourceRemovals.contains { $0.source == "/tree/a" })
        #expect(try f.read("tree/a") == "BAD")
    }

    @Test func renameDecisionRejectsTraversalAndExistingDestination() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        try f.directory("tree"); try f.write("tree/a", "keep"); try f.write("tree/taken", "existing")
        let preview = try f.download(.mergeSkippingExisting)
        for name in ["../escape", "sub/file", "taken", "", ".", ".."] {
            #expect(throws: (any Error).self) {
                try RemoteDirectoryTransfer.resolve(provider: f.remote, plan: preview, decisions: ["/tree/a": .rename(name)])
            }
        }
        #expect(try f.read("tree/a") == "keep" && f.read("tree/taken") == "existing")
        #expect(f.remote.removals.isEmpty)
    }

    @Test func resolvedReplacementChangedBeforeCopyIsNotOverwritten() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        try f.directory("tree"); try f.write("tree/a", "old")
        let preview = try f.download(.mergeSkippingExisting)
        let plan = try RemoteDirectoryTransfer.resolve(provider: f.remote, plan: preview, decisions: ["/tree/a": .replace])
        try f.write("tree/a", "NEW")
        let error = try failure { try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan) }
        #expect(error.report.completed.isEmpty && error.report.removedSources.isEmpty)
        #expect(try f.read("tree/a") == "NEW" && f.remote.files["/tree/a"] == Data("one".utf8))
    }

    @Test func localSourceParentReplacementAfterCopyIsNeverUnlinked() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; try f.localTree()
        let plan = try f.upload()
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan) { update in
            if update.path.hasPrefix("Скопировано поддеревьев") {
                try? FileManager.default.moveItem(at: f.local.appendingPathComponent("tree"), to: f.local.appendingPathComponent("reviewed-original"))
                try? f.localTree()
            }
        }
        #expect(try f.read("tree/a") == "one" && f.read("reviewed-original/a") == "one")
        #expect(report.removedSources.isEmpty && !report.failedSourceRemovals.isEmpty)
    }

    @Test func uncertainPublicationNeverStartsLocalSourceDeletion() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; try f.localTree()
        let plan = try f.upload(); f.remote.loseRenameResponse = true
        let error = try failure { try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan) }
        #expect(error.outcomeUnknown && error.report.removedSources.isEmpty)
        #expect(try f.read("tree/a") == "one" && f.read("tree/sub/b") == "four")
        #expect(f.remote.files["/tree/a"] == Data("one".utf8))
    }

    @Test func failedExactRemovalKeepsSourceAndReportsCompletedCopies() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download(); f.remote.removeFailure = "/tree/sub/b"
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan)
        #expect(report.completed.count == 1 && report.retainedSources.contains("/tree/sub/b"))
        #expect(report.failedSourceRemovals.contains { $0.source == "/tree/sub/b" })
        #expect(f.remote.files["/tree/sub/b"] == Data("four".utf8) && f.remote.directories.contains("/tree/sub"))
        #expect(try f.read("tree/sub/b") == "four")
    }

    @Test func lostUnlinkResponseNeverCountsAnUnacknowledgedDeletionAsCompleted() throws {
        let f = try DirectoryMoveFixture(); defer { f.cleanup() }; f.remote.tree()
        let plan = try f.download(); f.remote.loseRemoveResponse = "/tree/sub/b"
        let report = try RemoteDirectoryTransfer.move(provider: f.remote, plan: plan)
        #expect(report.completed.count == 1 && !report.removedSources.contains("/tree/sub/b"))
        #expect(report.retainedSources.contains("/tree/sub/b"))
        #expect(report.failedSourceRemovals.contains { $0.source == "/tree/sub/b" && $0.outcomeUnknown && $0.reason.localizedCaseInsensitiveContains("ответ") })
        #expect(f.remote.files["/tree/sub/b"] == nil && f.remote.directories.contains("/tree/sub"))
        #expect(try f.read("tree/sub/b") == "four")
    }

    private func failure(_ work: () throws -> RemoteDirectoryTransferReport) throws -> RemoteDirectoryTransferFailure {
        do { _ = try work(); throw NetworkError.io("Expected a move failure") }
        catch let error as RemoteDirectoryTransferFailure { return error }
    }
}

private final class DirectoryMoveFixture {
    let remote = DirectoryMoveRemote()
    let local: URL
    init() throws {
        local = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("far-move-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: local) }
    func directory(_ path: String) throws { try FileManager.default.createDirectory(at: local.appendingPathComponent(path), withIntermediateDirectories: true) }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: local.appendingPathComponent(path)) }
    func read(_ path: String) throws -> String { try String(contentsOf: local.appendingPathComponent(path), encoding: .utf8) }
    func localTree() throws { try directory("tree/sub"); try directory("tree/empty"); try write("tree/a", "one"); try write("tree/sub/b", "four") }
    func download(_ policy: RemoteDirectoryConflictPolicy = .requireNew) throws -> RemoteDirectoryTransferPlan {
        try RemoteDirectoryTransfer.prepareDownload(provider: remote, entries: [remote.entry("/tree")], into: local, policy: policy)
    }
    func upload(_ policy: RemoteDirectoryConflictPolicy = .requireNew) throws -> RemoteDirectoryTransferPlan {
        try RemoteDirectoryTransfer.prepareUpload(provider: remote, sources: [local.appendingPathComponent("tree")], into: "/", policy: policy)
    }
}

private final class DirectoryMoveRemote: RemoteNoReplaceRenameProvider, RemoteBoundedDownloadProvider, RemoteNonRecursiveDirectoryRemoval {
    let connection = NetworkConnection(kind: .sftp, host: "move.test")
    var files: [String: Data] = [:], directories: Set<String> = ["/"]
    var versions: [String: Int] = [:], removals: [String] = []
    var afterRemove: ((String) -> Void)?, afterDownload: ((String) -> Void)?, removeFailure: String?, loseRemoveResponse: String?, loseRenameResponse = false
    func file(_ path: String, _ value: String) { files[path] = Data(value.utf8); versions[path, default: 0] += 1 }
    func tree() { directories.formUnion(["/tree", "/tree/sub", "/tree/empty"]); file("/tree/a", "one"); file("/tree/sub/b", "four") }
    func entry(_ path: String) -> RemoteEntry { try! stat(path: path, cancellation: TransferCancellation())! }
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? {
        guard files[path] != nil || directories.contains(path) else { return nil }
        return RemoteEntry(path: path, isDirectory: directories.contains(path), size: Int64(files[path]?.count ?? 0), version: files[path] == nil ? nil : "\"\(versions[path, default: 0])\"")
    }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        try (Array(files.keys) + Array(directories)).filter { $0 != path && RemotePath.parent($0) == path }.sorted().map { try stat(path: $0, cancellation: cancellation)! }
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        guard let bytes = files[path] else { throw NetworkError.notFound(path) }
        try bytes.write(to: to); progress(NetworkProgress(path: path, completedBytes: Int64(bytes.count), totalBytes: Int64(bytes.count))); afterDownload?(path)
    }
    func boundedDownload(path: String, to: URL, maximumBytes: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws {
        guard Int64(files[path]?.count ?? 0) <= maximumBytes else { throw NetworkError.limitExceeded("bounded download") }
        try download(path: path, to: to, resumeOffset: 0, cancellation: cancellation, progress: progress)
    }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { files[to] = try Data(contentsOf: from) }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        guard replace || (!directories.contains(to) && files[to] == nil) else { throw NetworkError.conflict(to) }
        if let value = files.removeValue(forKey: from) { files[to] = value }
        else if directories.remove(from) != nil {
            directories.insert(to)
            for path in Array(files.keys) where path.hasPrefix(from + "/") { files[to + path.dropFirst(from.count)] = files.removeValue(forKey: path) }
            for path in Array(directories) where path.hasPrefix(from + "/") { directories.insert(to + path.dropFirst(from.count)); directories.remove(path) }
        } else { throw NetworkError.notFound(from) }
        if loseRenameResponse { throw NetworkError.connectionFailed("lost rename response") }
    }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws {
        guard files[path] == nil && !directories.contains(path) else { throw NetworkError.conflict(path) }; directories.insert(path)
    }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws {
        if path == removeFailure { throw NetworkError.connectionFailed("timeout during exact source unlink") }
        if isDirectory {
            guard !files.keys.contains(where: { $0.hasPrefix(path + "/") }), !directories.contains(where: { $0.hasPrefix(path + "/") }) else { throw NetworkError.conflict(path) }
            guard directories.remove(path) != nil else { throw NetworkError.notFound(path) }
        } else { guard files.removeValue(forKey: path) != nil else { throw NetworkError.notFound(path) } }
        if path == loseRemoveResponse { throw NetworkError.connectionFailed("lost source unlink response") }
        removals.append(path); afterRemove?(path)
    }
}
