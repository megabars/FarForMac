import Foundation
import Testing
@testable import FarCore

@Suite struct TemporaryResultDeletionTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @Test func previewDoesNotDeleteAndExecutionDeletesTargets() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let matches: [SearchMatch] = try [a, b].map { .local(try SearchResult.capture($0)) }
        let plan = try TemporaryResultDeletion.prepare(matches)
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(plan.count == 2 && !plan.hasPermanentDeletions)
        let result = TemporaryResultDeletion.execute(plan, trash: { urls in for url in urls { try FileManager.default.removeItem(at: url) } })
        #expect(result.failure == nil && result.completedIDs == Set(matches.map(\.id)))
        #expect(!FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path))
    }
    @Test func stalePlanFailsBeforeDeletingAnyObject() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let plan = try TemporaryResultDeletion.prepare([.local(SearchResult.capture(a)), .local(SearchResult.capture(b))])
        try Data("changed".utf8).write(to: b, options: .atomic)
        var mutations = 0
        let result = TemporaryResultDeletion.execute(plan, trash: { _ in mutations += 1 })
        #expect(mutations == 0 && result.completedIDs.isEmpty && result.failure != nil)
    }
    @Test func failureRetainsUnprocessedReferencesAndCancellationIsNoOp() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["a", "b"].map { root.appendingPathComponent($0) }
        for url in urls { try Data("file".utf8).write(to: url) }
        let matches = try urls.map { SearchMatch.local(try SearchResult.capture($0)) }
        let plan = try TemporaryResultDeletion.prepare(matches)
        var calls = 0
        let result = TemporaryResultDeletion.execute(plan, trash: { files in
            calls += 1; if calls == 2 { throw PanelSessionError("fixture failure") }
            try FileManager.default.removeItem(at: files[0])
        })
        #expect(result.completedIDs == [matches[0].id] && result.failure != nil)
        #expect(FileManager.default.fileExists(atPath: urls[1].path))
        let next = try TemporaryResultDeletion.prepare([matches[1]])
        let token = TransferCancellation(); token.cancel()
        let cancelled = TemporaryResultDeletion.execute(next, cancellation: token, trash: { _ in Issue.record("Cancelled deletion ran") })
        #expect(cancelled.completedIDs.isEmpty && cancelled.failure != nil)
    }
    @Test func selectedDirectoryAndChildAreRemovedOnce() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("dir"), file = dir.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: file)
        let matches: [SearchMatch] = try [file, dir].map { .local(try SearchResult.capture($0)) }
        let plan = try TemporaryResultDeletion.prepare(matches)
        var calls = 0
        let result = TemporaryResultDeletion.execute(plan, trash: { files in calls += 1; try FileManager.default.removeItem(at: files[0]) })
        #expect(calls == 1 && result.completedIDs == Set(matches.map(\.id)) && result.failure == nil)
    }
    @Test func archiveParentAndChildAreCoalescedAndBackingFileOverlapIsRejected() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("folder"), child = dir.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data("text".utf8).write(to: child)
        let archive = root.appendingPathComponent("test.zip")
        let snapshot = try ArchiveWriter.create(sources: [dir], destination: archive, format: .zip)
        let items = snapshot.entries.map { entry in SearchMatch.archive(ProviderSearchResult(archiveEntry: entry,
            remoteEntry: nil, archiveURL: archive, connectionID: nil, snippet: nil, lineNumber: nil,
            byteOffset: nil, archiveSnapshot: snapshot, capturedConnection: nil)) }
        #expect(items.count == 2)
        let plan = try TemporaryResultDeletion.prepare(items)
        #expect(plan.permanentFileCount == 1 && plan.permanentDirectoryCount == 1 && plan.reviewPaths.count == 2)
        #expect(throws: (any Error).self) { try TemporaryResultDeletion.prepare([.local(SearchResult.capture(archive))] + items) }
        let outcome = TemporaryResultDeletion.execute(plan)
        #expect(outcome.failure == nil && outcome.completedIDs.count == 2)
        #expect(outcome.updatedArchives.first?.entries.isEmpty == true)
    }

}

