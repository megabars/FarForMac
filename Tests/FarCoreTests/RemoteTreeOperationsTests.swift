import Foundation
import Testing
@testable import FarCore

@Suite final class RemoteTreeOperationsTests {
    @Test func previewIsReadOnlyAndDeleteIsLeafFirst() throws {
        let p = TreeRemote(); p.tree()
        let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")])
        #expect(plan.directoryCount == 2 && plan.fileCount == 2 && plan.totalBytes == 7)
        #expect(p.removed.isEmpty)
        let report = try RemoteTreeOperations.delete(provider: p, plan: plan)
        #expect(report.completed.count == 4)
        #expect(p.removed == ["/tree/sub/b", "/tree/sub", "/tree/a", "/tree"])
        #expect(p.entries.count == 1)
    }
    @Test func changedLeafOrNewChildBeforeConfirmationPreventsAllDeletion() throws {
        for addChild in [false, true] {
            let p = TreeRemote(); p.tree()
            let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")])
            if addChild { p.file("/tree/new") } else { p.file("/tree/a", size: 99) }
            let error = try mutationFailure { try RemoteTreeOperations.delete(provider: p, plan: plan) }
            #expect(error.report.completed.isEmpty && !error.outcomeUnknown && p.removed.isEmpty)
            #expect(p.entries["/tree/a"] != nil)
        }
    }
    @Test func newChildDuringDeleteSurvivesAndStopsBeforeParent() throws {
        let p = TreeRemote(); p.directory("/tree"); p.file("/tree/a")
        let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")])
        p.afterRemove = { _ in p.file("/tree/new") }
        let error = try mutationFailure { try RemoteTreeOperations.delete(provider: p, plan: plan) }
        #expect(error.report.completed.map(\.source) == ["/tree/a"])
        #expect(!error.outcomeUnknown && p.entries["/tree/new"] != nil && p.entries["/tree"] != nil)
    }
    @Test func nonrecursiveServerRefusesChildAppearingAfterFinalList() throws {
        let p = TreeRemote(); p.directory("/tree")
        let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")])
        p.beforeRemove = { path in if path == "/tree" { p.file("/tree/racer") } }
        let error = try mutationFailure { try RemoteTreeOperations.delete(provider: p, plan: plan) }
        #expect(error.outcomeUnknown && error.report.completed.isEmpty && p.entries["/tree/racer"] != nil)
    }
    @Test func cancellationReportsExactPartialDeletion() throws {
        let p = TreeRemote(); p.tree(); let token = TransferCancellation()
        let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")])
        let error = try mutationFailure {
            try RemoteTreeOperations.delete(provider: p, plan: plan, cancellation: token) { _ in token.cancel() }
        }
        #expect(error.report.completed.count == 1 && !error.outcomeUnknown)
        #expect(p.entries["/tree/sub"] != nil && p.entries["/tree/a"] != nil)
    }
    @Test func linkIsRemovedAsLeafAndNeverTraversed() throws {
        let p = TreeRemote(); p.directory("/tree")
        p.entries["/tree/link"] = RemoteEntry(path: "/tree/link", isDirectory: true, isSymbolicLink: true, size: 0)
        p.directory("/outside"); p.file("/outside/keep")
        let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")])
        _ = try RemoteTreeOperations.delete(provider: p, plan: plan)
        #expect(!p.listed.contains("/tree/link") && p.entries["/outside/keep"] != nil)
        #expect(p.directoryRemovalFlags["/tree/link"] == false)
    }
    @Test func replacedAncestorLinkStopsBeforeMutation() throws {
        let p = TreeRemote(); p.directory("/parent"); p.file("/parent/file")
        let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/parent/file")])
        p.entries["/parent"] = RemoteEntry(path: "/parent", isDirectory: true, isSymbolicLink: true, size: 0)
        _ = try mutationFailure { try RemoteTreeOperations.delete(provider: p, plan: plan) }
        #expect(p.removed.isEmpty)
    }
    @Test func maliciousListingsRootAndOverlappingSelectionsAreRejected() throws {
        let p = TreeRemote(); p.tree()
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/")]) }
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree"), p.entry("/tree/a")]) }
        for values in [[p.entry("/tree/a"), p.entry("/tree/a")], [RemoteEntry(path: "/outside", isDirectory: false, size: 0)]] {
            p.overrideListing = values
            #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")]) }
        }
        #expect(p.removed.isEmpty)
    }
    @Test func recursiveDeleteRequiresNonrecursiveServerCapability() throws {
        let p = UnqualifiedTreeRemote(); p.entries["/tree"] = RemoteEntry(path: "/tree", isDirectory: true, size: 0)
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")]) }
        p.entries["/file"] = RemoteEntry(path: "/file", isDirectory: false, size: 1)
        let plan = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/file")])
        _ = try RemoteTreeOperations.delete(provider: p, plan: plan)
        #expect(p.entries["/file"] == nil)
    }
    @Test func moveDirectoryUsesOneRenameWithoutCopyOrDeletion() throws {
        let p = TreeRemote(); p.tree(); p.directory("/destination")
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/tree")], to: "/destination", intoDirectory: true)
        #expect(p.renamed.isEmpty)
        let report = try RemoteTreeOperations.move(provider: p, plan: plan)
        #expect(report.completed == [RemoteMutationRecord(source: "/tree", destination: "/destination/tree")])
        #expect(p.entries["/destination/tree/sub/b"] != nil && p.entries["/tree"] == nil)
        #expect(p.removed.isEmpty && p.renamed == ["/destination/tree"] && p.copied == 0)
    }
    @Test func renameFileAndDirectoryToExplicitNewName() throws {
        let p = TreeRemote(); p.tree()
        for (source, target) in [("/tree/a", "/renamed"), ("/tree", "/newtree")] {
            let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry(source)], to: target, intoDirectory: false)
            _ = try RemoteTreeOperations.move(provider: p, plan: plan)
            #expect(p.entries[target] != nil && p.entries[source] == nil)
        }
    }
    @Test func moveRejectsDestinationConflictAndDescendant() throws {
        let p = TreeRemote(); p.tree()
        for target in ["/tree", "/tree/new", "/tree/sub/new", "/tree/a"] {
            #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/tree")], to: target, intoDirectory: false) }
        }
        #expect(p.renamed.isEmpty)
    }
    @Test func destinationAppearingAfterPreviewIsNeverReplaced() throws {
        let p = TreeRemote(); p.tree()
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/tree")], to: "/new", intoDirectory: false)
        p.file("/new", size: 73)
        _ = try mutationFailure { try RemoteTreeOperations.move(provider: p, plan: plan) }
        #expect(p.entries["/tree/a"] != nil && p.entry("/new").size == 73 && p.renamed.isEmpty)
    }
    @Test func changedMoveSourceAndForeignProviderAreRejected() throws {
        let p = TreeRemote(); p.tree()
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/tree")], to: "/new", intoDirectory: false)
        p.file("/tree/new")
        _ = try mutationFailure { try RemoteTreeOperations.move(provider: p, plan: plan) }
        let other = TreeRemote(connection: p.connection); other.tree()
        _ = try mutationFailure { try RemoteTreeOperations.move(provider: other, plan: plan) }
        #expect(p.renamed.isEmpty && other.renamed.isEmpty)
    }
    @Test func cancelledBatchMoveReportsCompletedSources() throws {
        let p = TreeRemote(); p.file("/a"); p.file("/b"); p.directory("/destination")
        let token = TransferCancellation()
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/a"), p.entry("/b")], to: "/destination", intoDirectory: true)
        let error = try mutationFailure { try RemoteTreeOperations.move(provider: p, plan: plan, cancellation: token) { _ in token.cancel() } }
        #expect(error.report.completed.map(\.source) == ["/a"] && !error.outcomeUnknown)
        #expect(p.entries["/destination/a"] != nil && p.entries["/b"] != nil)
    }
    @Test func serverRejectsDestinationCreatedInsideRenameRequest() throws {
        let p = TreeRemote(); p.file("/a")
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/a")], to: "/b", intoDirectory: false)
        p.beforeRename = { p.file("/b", size: 123) }
        let error = try mutationFailure { try RemoteTreeOperations.move(provider: p, plan: plan) }
        #expect(error.outcomeUnknown && p.entry("/b").size == 123 && p.entries["/a"] != nil)
        #expect(p.renamed.isEmpty)
    }
    @Test func protocolWithoutAtomicNoReplaceNeverStartsMove() throws {
        let p = UnqualifiedTreeRemote(); p.file("/a")
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/a")], to: "/b", intoDirectory: false) }
        #expect(p.listed.isEmpty && p.renamed.isEmpty && p.entries["/a"] != nil)
    }
    @Test func previewCancellationAndDepthLimitNeverMutate() throws {
        let p = TreeRemote(); p.tree(); let token = TransferCancellation(); token.cancel()
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/tree")], cancellation: token) }
        var path = "/deep"; p.directory(path)
        for _ in 0...RemoteTransferLimits.maximumDepth { path += "/d"; p.directory(path) }
        #expect(throws: (any Error).self) { try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/deep")]) }
        #expect(p.removed.isEmpty)
    }
    @Test func nestedWideListingsShareOneDiscoveredBudget() throws {
        let p = TreeRemote(); p.directory("/root"); p.directory("/root/a")
        let first = [p.entry("/root/a")] + (0..<50_000).map { RemoteEntry(path: "/root/f\($0)", isDirectory: false, size: 0) }
        let second = (0..<50_000).map { RemoteEntry(path: "/root/a/f\($0)", isDirectory: false, size: 0) }
        p.listingProvider = { path in path == "/root" ? first : second }
        do {
            _ = try RemoteTreeOperations.prepareDelete(provider: p, entries: [p.entry("/root")])
            Issue.record("Nested pending listings must share the global 100000-entry ceiling")
        } catch let error as RemoteTransferError {
            guard case .unsupported = error else { Issue.record("Expected discovered-budget rejection, got \(error)"); return }
        }
        #expect(p.removed.isEmpty && !p.listed.contains("/root/a/f0"))
    }
    @Test func requestFailureCanHaveUncertainOutcomeWithoutInventingSuccess() throws {
        let p = TreeRemote(); p.file("/a"); p.failRenameAfterMutation = true
        let plan = try RemoteTreeOperations.prepareMove(provider: p, entries: [p.entry("/a")], to: "/b", intoDirectory: false)
        let error = try mutationFailure { try RemoteTreeOperations.move(provider: p, plan: plan) }
        #expect(error.outcomeUnknown && error.report.completed.isEmpty && p.entries["/b"] != nil)
    }
}

private class UnqualifiedTreeRemote: RemoteProvider {
    let connection: NetworkConnection
    init(connection: NetworkConnection = NetworkConnection(kind: .ftp, host: "example.test")) { self.connection = connection }
    var entries = ["/": RemoteEntry(path: "/", isDirectory: true, size: 0)]
    var removed: [String] = [], renamed: [String] = [], listed: [String] = []
    var directoryRemovalFlags: [String: Bool] = [:]
    var overrideListing: [RemoteEntry]?
    var listingProvider: ((String) -> [RemoteEntry])?
    var beforeRemove: ((String) -> Void)?, afterRemove: ((String) -> Void)?
    var beforeRename: (() -> Void)?
    var copied = 0, failRenameAfterMutation = false
    func entry(_ path: String) -> RemoteEntry { entries[path]! }
    func file(_ path: String, size: Int64 = 3) { entries[path] = RemoteEntry(path: path, isDirectory: false, size: size) }
    func directory(_ path: String) { entries[path] = RemoteEntry(path: path, isDirectory: true, size: 0) }
    func tree() { directory("/tree"); file("/tree/a"); directory("/tree/sub"); file("/tree/sub/b", size: 4) }
    func stat(path: String, cancellation: TransferCancellation) throws -> RemoteEntry? { entries[path] }
    func list(path: String, cancellation: TransferCancellation) throws -> [RemoteEntry] {
        listed.append(path)
        if let listingProvider { return listingProvider(path) }
        return overrideListing ?? entries.values.filter { $0.path != path && RemotePath.parent($0.path) == path }
    }
    func download(path: String, to: URL, resumeOffset: Int64, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { copied += 1; throw NetworkError.unsupported("Unexpected download") }
    func upload(from: URL, to: String, cancellation: TransferCancellation, progress: @escaping (NetworkProgress) -> Void) throws { copied += 1; throw NetworkError.unsupported("Unexpected upload") }
    func rename(from: String, to: String, replace: Bool, cancellation: TransferCancellation) throws {
        #expect(!replace); beforeRename?()
        guard entries[to] == nil else { throw NetworkError.conflict(to) }
        let affected = entries.values.filter { $0.path == from || $0.path.hasPrefix(from + "/") }
        for entry in affected {
            let path = to + entry.path.dropFirst(from.count)
            entries.removeValue(forKey: entry.path)
            entries[path] = RemoteEntry(path: path, isDirectory: entry.isDirectory, isSymbolicLink: entry.isSymbolicLink, size: entry.size, modified: entry.modified, version: entry.version)
        }
        renamed.append(to)
        if failRenameAfterMutation { throw NetworkError.connectionFailed("Lost acknowledgement") }
    }
    func remove(path: String, isDirectory: Bool, cancellation: TransferCancellation) throws {
        beforeRemove?(path)
        if isDirectory && entries.keys.contains(where: { $0.hasPrefix(path + "/") }) { throw NetworkError.conflict(path) }
        entries.removeValue(forKey: path); removed.append(path); directoryRemovalFlags[path] = isDirectory; afterRemove?(path)
    }
    func makeDirectory(path: String, cancellation: TransferCancellation) throws { directory(path) }
}
private final class TreeRemote: UnqualifiedTreeRemote, RemoteNonRecursiveDirectoryRemoval, RemoteNoReplaceRenameProvider {}
private func mutationFailure<T>(_ work: () throws -> T) throws -> RemoteTreeOperationError {
    do { _ = try work(); Issue.record("Expected mutation failure"); throw NetworkError.io("Expected failure") }
    catch let error as RemoteTreeOperationError { return error }
}
