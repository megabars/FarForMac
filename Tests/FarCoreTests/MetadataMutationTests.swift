import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite struct MetadataMutationTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FarMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            // Some tests intentionally remove directory search permissions.
            _ = chmod(root.path, 0o700)
            if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let url as URL in enumerator { _ = chmod(url.path, 0o700) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }
    @Test func datesChangeOnlyRequestedFieldAndPreservePermissions() throws {
        try fixture { root in
            let url = root.appendingPathComponent("dates.txt")
            try Data("unchanged".utf8).write(to: url)
            _ = chmod(url.path, 0o640)
            let accessed = Date(timeIntervalSince1970: 1_600_000_000.25)
            let modified = Date(timeIntervalSince1970: 1_600_100_000.5)
            let initial = try MetadataMutation.prepare(url: url, changes: MetadataChanges(accessed: accessed, modified: modified))
            #expect(MetadataMutation.apply(initial).error == nil)
            let snapshot = try FileTools.metadata(url)
            #expect(abs(snapshot.accessed.timeIntervalSince1970 - accessed.timeIntervalSince1970) < 0.00001)
            #expect(abs(snapshot.modified.timeIntervalSince1970 - modified.timeIntervalSince1970) < 0.00001)
            #expect(snapshot.permissions == 0o640)
            let nextDate = Date(timeIntervalSince1970: 1_700_000_000.125)
            let second = try MetadataMutation.prepare(url: url, changes: MetadataChanges(modified: nextDate))
            #expect(MetadataMutation.apply(second).completed == 1)
            let after = try FileTools.metadata(url)
            #expect(abs(after.accessed.timeIntervalSince1970 - accessed.timeIntervalSince1970) < 0.00001)
            #expect(abs(after.modified.timeIntervalSince1970 - nextDate.timeIntervalSince1970) < 0.00001)
            #expect(try String(contentsOf: url, encoding: .utf8) == "unchanged")
        }
    }
    @Test func recursivePlanIsReadOnlySkipsLinksAndSpecialFilesAndAppliesChildrenFirst() throws {
        try fixture { root in
            let tree = root.appendingPathComponent("tree"), nested = tree.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let file = nested.appendingPathComponent("file")
            try Data("keep".utf8).write(to: file)
            let outside = root.appendingPathComponent("outside")
            try Data("outside".utf8).write(to: outside); _ = chmod(outside.path, 0o600)
            try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("outside-link"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("loop"), withDestinationURL: tree)
            #expect(mkfifo(tree.appendingPathComponent("fifo").path, 0o600) == 0)
            let old = try FileTools.metadata(file).permissions
            let plan = try MetadataMutation.prepare(url: tree, changes: MetadataChanges(permissions: 0o700), recursive: true)
            #expect(plan.entries.count == 3)
            #expect(plan.entries.first?.url == file)
            #expect(plan.entries.last?.url.path == tree.path)
            #expect(plan.skippedSymbolicLinks == 2)
            #expect(plan.skippedSpecialFiles == 1)
            #expect(try FileTools.metadata(file).permissions == old)
            let report = MetadataMutation.apply(plan)
            #expect(report.error == nil)
            #expect(report.completed == 3)
            for url in [tree, nested, file] { #expect(try FileTools.metadata(url).permissions == 0o700) }
            #expect(try FileTools.metadata(outside).permissions == 0o600)
        }
    }
    @Test func recursiveRightsAndDatesApplyOncePerHardLinkedInode() throws {
        try fixture { root in
            let tree = root.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
            let file = tree.appendingPathComponent("a"), hard = tree.appendingPathComponent("b")
            try Data("hardlink".utf8).write(to: file)
            try FileManager.default.linkItem(at: file, to: hard)
            let newDate = Date(timeIntervalSince1970: 1_600_000_000)
            let plan = try MetadataMutation.prepare(url: tree, changes: MetadataChanges(permissions: 0o750, modified: newDate), recursive: true)
            #expect(plan.entries.count == 2)
            #expect(plan.skippedDuplicateHardLinks == 1)
            #expect(MetadataMutation.apply(plan).error == nil)
            #expect(try FileTools.metadata(file).modified == newDate)
            #expect(try FileTools.metadata(hard).permissions == 0o750)
            #expect(try FileTools.metadata(tree).modified == newDate)
        }
    }
    @Test func preflightRejectsReplacementsBeforeAnyReviewedObjectChanges() throws {
        try fixture { root in
            let tree = root.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
            let a = tree.appendingPathComponent("a"), b = tree.appendingPathComponent("b")
            try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
            let old = try FileTools.metadata(a).permissions
            let plan = try MetadataMutation.prepare(url: tree, changes: MetadataChanges(permissions: 0o777), recursive: true)
            try FileManager.default.moveItem(at: b, to: root.appendingPathComponent("original-b"))
            try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
            let report = MetadataMutation.apply(plan)
            #expect(report.completed == 0); #expect(report.error != nil)
            #expect(try FileTools.metadata(a).permissions == old)
        }
    }
    @Test func cancellationReportsPartialChangesAndCanCancelPreparation() throws {
        try fixture { root in
            let tree = root.appendingPathComponent("tree")
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: false)
            for index in 0..<4 { try Data("x".utf8).write(to: tree.appendingPathComponent("\(index)")) }
            let plan = try MetadataMutation.prepare(url: tree, changes: MetadataChanges(permissions: 0o700), recursive: true)
            let token = FileToolCancellation()
            let report = MetadataMutation.apply(plan, cancellation: token) { completed, _, _ in if completed == 1 { token.cancel() } }
            #expect(report.completed == 1)
            #expect(report.isCancelled)
            #expect(report.error == nil)
            #expect(MetadataMutation.apply(plan, cancellation: token).completed == 0)
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: tree, changes: MetadataChanges(permissions: 0o700), recursive: true, cancellation: token) }
        }
    }
    @Test func rejectsInvalidSettingsRootsLinksAndChangedMode() throws {
        try fixture { root in
            let url = root.appendingPathComponent("file")
            try Data("x".utf8).write(to: url)
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: url, changes: MetadataChanges()) }
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: url, changes: MetadataChanges(permissions: 0o10000)) }
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: url, changes: MetadataChanges(modified: Date(timeIntervalSince1970: .infinity))) }
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: URL(fileURLWithPath: "/"), changes: MetadataChanges(permissions: 0o777)) }
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: link, changes: MetadataChanges(permissions: 0o777)) }
            _ = chmod(url.path, 0o640)
            let plan = try MetadataMutation.prepare(url: url, changes: MetadataChanges(permissions: 0o777))
            _ = chmod(url.path, 0o600)
            let report = MetadataMutation.apply(plan)
            #expect(report.completed == 0); #expect(report.error != nil)
            #expect(try FileTools.metadata(url).permissions == 0o600)
        }
    }
    @Test func recursiveDateOnlyPreviewPreservesMetadataAndWritesBothDatesToEveryEntry() throws {
        try fixture { root in
            let tree = root.appendingPathComponent("tree"), nested = tree.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let file = nested.appendingPathComponent("file"), outside = root.appendingPathComponent("outside")
            try Data("preserve bytes".utf8).write(to: file)
            try Data("outside bytes".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("link"), withDestinationURL: outside)
            #expect(mkfifo(tree.appendingPathComponent("fifo").path, 0o600) == 0)
            let outsideBefore = try FileTools.metadata(outside)
            let before = try [tree, nested, file].map { try FileTools.metadata($0) }
            let accessed = Date(timeIntervalSince1970: 1_500_000_000.25)
            let modified = Date(timeIntervalSince1970: 1_600_000_000.5)
            let plan = try MetadataMutation.prepare(url: tree, changes: MetadataChanges(accessed: accessed, modified: modified), recursive: true)
            #expect(plan.entries.count == 3); #expect(plan.skippedSymbolicLinks == 1); #expect(plan.skippedSpecialFiles == 1)
            #expect(plan.entries.last?.isDirectory == true)
            for item in before { #expect(try FileTools.metadata(item.url).modified == item.modified) }
            #expect(plan.entries.allSatisfy { $0.previousOwnerID == geteuid() })
            let report = MetadataMutation.apply(plan)
            #expect(report.error == nil); #expect(report.completed == 3)
            for item in before {
                let after = try FileTools.metadata(item.url)
                #expect(after.accessed == accessed); #expect(after.modified == modified)
                #expect(after.permissions == item.permissions)
            }
            #expect(try FileTools.metadata(outside).accessed == outsideBefore.accessed)
            #expect(try FileTools.metadata(outside).modified == outsideBefore.modified)
            #expect(try String(contentsOf: file, encoding: .utf8) == "preserve bytes")
        }
    }
    @Test func recursiveAccessOnlyPreservesModificationAndNonrecursiveLeavesChildrenAlone() throws {
        try fixture { root in
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let file = nested.appendingPathComponent("file")
            try Data("x".utf8).write(to: file)
            let before = try [root, nested, file].map { try FileTools.metadata($0) }
            let newAccess = Date(timeIntervalSince1970: 1_550_000_000.125)
            let plan = try MetadataMutation.prepare(url: root, changes: MetadataChanges(accessed: newAccess), recursive: true)
            #expect(MetadataMutation.apply(plan).error == nil)
            for item in before {
                let after = try FileTools.metadata(item.url)
                #expect(after.accessed == newAccess); #expect(after.modified == item.modified)
            }
            let newModified = Date(timeIntervalSince1970: 1_650_000_000)
            let single = try MetadataMutation.prepare(url: root, changes: MetadataChanges(modified: newModified))
            #expect(single.entries.count == 1); #expect(MetadataMutation.apply(single).error == nil)
            #expect(try FileTools.metadata(file).modified == before.last?.modified)
            #expect(try FileTools.metadata(root).accessed == newAccess)
        }
    }
    @Test func recursiveDateCancellationKeepsCompletedEntriesAndLeavesTheRestUnchanged() throws {
        try fixture { root in
            for index in 0..<3 { try Data("x".utf8).write(to: root.appendingPathComponent("\(index)")) }
            let date = Date(timeIntervalSince1970: 1_500_000_000)
            let plan = try MetadataMutation.prepare(url: root, changes: MetadataChanges(modified: date), recursive: true)
            let token = FileToolCancellation()
            let report = MetadataMutation.apply(plan, cancellation: token) { completed, _, _ in if completed == 1 { token.cancel() } }
            #expect(report.isCancelled); #expect(report.completed == 1); #expect(report.total == 4); #expect(report.error == nil)
            #expect(try FileTools.metadata(plan.entries[0].url).modified == date)
            for entry in plan.entries.dropFirst() { #expect(try FileTools.metadata(entry.url).modified == entry.previousModified) }
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: root, changes: MetadataChanges(accessed: date), recursive: true, cancellation: token) }
        }
    }
    @Test func changedSourceWithRestoredMtimeAndHardlinkTopologyInvalidateDatePlan() throws {
        try fixture { root in
            let file = root.appendingPathComponent("file")
            try Data("before".utf8).write(to: file)
            // Use an exactly representable timestamp: Foundation setAttributes
            // rounds arbitrary nanosecond values when restoring a Date.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.25)], ofItemAtPath: file.path)
            let initial = try FileTools.metadata(file)
            let plan = try MetadataMutation.prepare(url: file, changes: MetadataChanges(modified: Date(timeIntervalSince1970: 1_500_000_000)))
            try Data("edited".utf8).write(to: file, options: [])
            try FileManager.default.setAttributes([.modificationDate: initial.modified], ofItemAtPath: file.path)
            let changed = MetadataMutation.apply(plan)
            #expect(changed.completed == 0); #expect(changed.error != nil)
            #expect(try FileTools.metadata(file).modified == initial.modified)
            let second = try MetadataMutation.prepare(url: file, changes: MetadataChanges(accessed: Date(timeIntervalSince1970: 1_500_000_000)))
            try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("new-hardlink"))
            let topology = MetadataMutation.apply(second)
            #expect(topology.completed == 0); #expect(topology.error != nil)
        }
    }
    @Test func datePlanRejectsAReplacedNestedFolderBeforeChangingAnyEntry() throws {
        try fixture { root in
            let tree = root.appendingPathComponent("tree"), nested = tree.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let file = nested.appendingPathComponent("file")
            try Data("x".utf8).write(to: file)
            let initial = try FileTools.metadata(file).modified
            let plan = try MetadataMutation.prepare(url: tree, changes: MetadataChanges(modified: Date(timeIntervalSince1970: 1_500_000_000)), recursive: true)
            let moved = root.appendingPathComponent("moved")
            try FileManager.default.moveItem(at: nested, to: moved)
            try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: moved)
            let report = MetadataMutation.apply(plan)
            #expect(report.completed == 0); #expect(report.error != nil)
            #expect(try FileTools.metadata(moved.appendingPathComponent("file")).modified == initial)
        }
    }
    @Test func safeGroupSelectionAppliesRecursivelyAndPreservesOwnerDatesAndContent() throws {
        try fixture { root in
            let file = root.appendingPathComponent("file")
            try Data("unchanged".utf8).write(to: file); _ = chmod(file.path, 0o640)
            let groups = try MetadataOwnership.availableGroups()
            #expect(groups.contains { $0.id == getegid() }); #expect(!groups.contains { $0.id == .max })
            let owner = try MetadataOwnership.snapshot(url: file)
            #expect(owner.ownerID == geteuid()); #expect(owner.isOwnedByCurrentUser)
            #expect(!owner.ownerName.isEmpty); #expect(!owner.groupName.isEmpty)
            let group = try #require(groups.first { $0.id != owner.groupID } ?? groups.first)
            let before = try FileTools.metadata(file)
            let plan = try MetadataMutation.prepare(url: root, changes: MetadataChanges(groupID: group.id), recursive: true)
            #expect(try MetadataOwnership.snapshot(url: file).groupID == owner.groupID)
            let report = MetadataMutation.apply(plan)
            #expect(report.error == nil); #expect(report.completed == 2)
            for entry in plan.entries {
                let after = try MetadataOwnership.snapshot(url: entry.url)
                #expect(after.ownerID == entry.previousOwnerID); #expect(after.groupID == group.id)
            }
            let after = try FileTools.metadata(file)
            #expect(after.permissions == 0o640); #expect(after.accessed == before.accessed); #expect(after.modified == before.modified)
            #expect(try String(contentsOf: file, encoding: .utf8) == "unchanged")
            #expect(throws: (any Error).self) { try MetadataMutation.prepare(url: file, changes: MetadataChanges(groupID: .max)) }
        }
    }

}
