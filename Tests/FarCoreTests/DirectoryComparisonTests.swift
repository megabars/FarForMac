import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite
final class DirectoryComparisonTests {
    private let root: URL
    private let left: URL
    private let right: URL
    private let manager = FileManager.default
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    init() throws {
        // Exercise macOS's /var alias as used by actual file panels.
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FarComparison-\(UUID().uuidString)")
        left = root.appendingPathComponent("left"); right = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    }
    deinit { try? manager.removeItem(at: root) }
    @discardableResult private func file(_ name: String, in directory: URL, _ contents: String = "same", time: Date? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try manager.setAttributes([.modificationDate: time ?? timestamp], ofItemAtPath: url.path)
        return url
    }
    private func compare(_ options: DirectoryComparisonOptions = .init()) -> DirectoryComparisonReport {
        DirectoryComparisonEngine.run(left: left, right: right, options: options)
    }

    @Test func farMetadataRulesMarkOnlyNewerAndUnmatchedFiles() throws {
        try file("same", in: left); try file("same", in: right)
        try file("left-only", in: left); try file("right-only", in: right)
        try file("newer-left", in: left, time: timestamp.addingTimeInterval(5))
        try file("newer-left", in: right)
        try file("newer-right", in: left); try file("newer-right", in: right, time: timestamp.addingTimeInterval(5))
        try file("size", in: left, "a"); try file("size", in: right, "long")
        let report = compare()
        #expect(report.isComplete)
        #expect(report.rows.first { $0.name == "same" }?.status == .same)
        #expect(Set(report.markedLeftURLs.map(\.lastPathComponent)) == ["left-only", "newer-left", "size"])
        #expect(Set(report.markedRightURLs.map(\.lastPathComponent)) == ["right-only", "newer-right", "size"])
        #expect(report.contentBytesRead == 0)
        try report.verifyCurrent()
    }

    @Test func optionalByteComparisonFindsEqualSizeEqualTimeDifferencesAndDoesNotWrite() throws {
        let a = try file("bytes", in: left, "abcd"), b = try file("bytes", in: right, "abce")
        #expect(compare().rows.first?.status == .same)
        var options = DirectoryComparisonOptions(); options.compareContents = true
        let report = compare(options)
        #expect(report.isComplete)
        #expect(report.rows.first?.status == .different)
        #expect(report.contentBytesRead == 8)
        #expect(report.markedLeftURLs == [a]); #expect(report.markedRightURLs == [b])
        #expect(try Data(contentsOf: a) == Data("abcd".utf8))
        #expect(try Data(contentsOf: b) == Data("abce".utf8))
        #expect(report.syncPreview(.leftToRight).first?.action == .replace)
    }

    @Test func directionalPreviewRetainsDestinationOnlyFilesAndWarnsAboutOlderSource() throws {
        let onlyLeft = try file("a", in: left), onlyRight = try file("b", in: right)
        try file("old", in: left); try file("old", in: right, time: timestamp.addingTimeInterval(10))
        let report = compare()
        let forward = report.syncPreview(.leftToRight)
        #expect(forward.first { $0.name == "a" }?.action == .copy)
        #expect(forward.first { $0.name == "a" }?.destination == right.appendingPathComponent("a"))
        #expect(forward.first { $0.name == "b" }?.action == .retain)
        #expect(forward.first { $0.name == "old" }?.detail.contains("старее") == true)
        let backward = report.syncPreview(.rightToLeft)
        #expect(backward.first { $0.name == "a" }?.action == .retain)
        #expect(backward.first { $0.name == "b" }?.source == onlyRight)
        #expect(manager.fileExists(atPath: onlyLeft.path))
        #expect(!manager.fileExists(atPath: right.appendingPathComponent("a").path))
        #expect(!manager.fileExists(atPath: left.appendingPathComponent("b").path))
    }

    @Test func directoriesLinksFifosAndTypeConflictsAreExplicitAndNeverRead() throws {
        for side in [left, right] {
            let directory = side.appendingPathComponent("directory")
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            try file("nested", in: directory, side == left ? "left" : "right")
            try manager.createSymbolicLink(atPath: side.appendingPathComponent("dangling").path, withDestinationPath: "/missing-comparison-target")
            try manager.createSymbolicLink(at: side.appendingPathComponent("cycle"), withDestinationURL: side)
            #expect(mkfifo(side.appendingPathComponent("fifo").path, 0o600) == 0)
        }
        try file("conflict", in: left)
        try manager.createDirectory(at: right.appendingPathComponent("conflict"), withIntermediateDirectories: false)
        var options = DirectoryComparisonOptions(); options.compareContents = true
        let report = compare(options)
        #expect(report.isComplete)
        #expect(report.rows.count == 5)
        #expect(report.rows.first { $0.name == "directory" }?.status == .directorySkipped)
        #expect(report.rows.first { $0.name == "dangling" }?.status == .symbolicLinkSkipped)
        #expect(report.rows.first { $0.name == "cycle" }?.status == .symbolicLinkSkipped)
        #expect(report.rows.first { $0.name == "fifo" }?.status == .unsupported)
        #expect(report.rows.first { $0.name == "conflict" }?.status == .typeConflict)
        #expect(report.contentBytesRead == 0)
        #expect(report.markedLeftURLs.isEmpty && report.markedRightURLs.isEmpty)
        #expect(report.syncPreview(.leftToRight).allSatisfy { $0.action == .blocked })
    }

    @Test func explicitlySelectedRootAliasesWorkAndRetargetingMakesSnapshotStale() throws {
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: left)
        let direct = DirectoryComparisonEngine.run(left: alias, right: right)
        #expect(direct.isComplete)
        let nested = left.appendingPathComponent("nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: false)
        let throughAncestor = DirectoryComparisonEngine.run(left: alias.appendingPathComponent("nested"), right: right)
        #expect(throughAncestor.isComplete)
        try manager.removeItem(at: alias)
        try manager.createSymbolicLink(at: alias, withDestinationURL: right)
        #expect(throws: (any Error).self) { try direct.verifyCurrent() }
    }

    @Test func caseAndHiddenOptionsChangeMatchingWithoutChangingPaths() throws {
        try file("Case.txt", in: left); try file("case.txt", in: right)
        try file(".hidden", in: left)
        let folded = compare()
        #expect(folded.rows.first { $0.name == "Case.txt" }?.status == .same)
        #expect(folded.rows.count == 2)
        var options = DirectoryComparisonOptions(); options.caseSensitiveNames = true; options.includeHidden = false
        let exact = compare(options)
        #expect(exact.isComplete && exact.rows.count == 2)
        #expect(exact.rows.first { $0.name == "Case.txt" }?.status == .leftOnly)
        #expect(exact.rows.first { $0.name == "case.txt" }?.status == .rightOnly)
    }

    @Test func enumerationAndContentLimitsDisableMarksAndActionablePlans() throws {
        try file("a", in: left); try file("b", in: left)
        var options = DirectoryComparisonOptions(); options.maximumEntriesPerDirectory = 1
        let entries = compare(options)
        #expect(entries.limitReached && !entries.isComplete && !entries.issues.isEmpty)
        try file("a", in: right); try file("b", in: right)
        options = .init(); options.compareContents = true; options.maximumContentBytesPerFile = 3
        let perFile = compare(options)
        #expect(!perFile.isComplete && perFile.rows.allSatisfy { $0.status == .error })
        #expect(perFile.contentBytesRead == 0)
        options.maximumContentBytesPerFile = 8; options.maximumTotalContentBytes = 8
        let total = compare(options)
        #expect(!total.isComplete && total.limitReached && total.contentBytesRead == 8)
        #expect(total.markedLeftURLs.isEmpty && total.markedRightURLs.isEmpty)
        #expect(total.syncPreview(.leftToRight).allSatisfy { $0.action == .blocked })
    }

    @Test func cancellationRetainsPartialRowsButCannotPublishMarksOrPlans() throws {
        try file("a", in: left); try file("b", in: left)
        let cancellation = DirectoryComparisonCancellation()
        let result = DirectoryComparisonEngine.run(left: left, right: right, cancellation: cancellation) { _ in cancellation.cancel() }
        #expect(result.cancelled && !result.isComplete)
        #expect(result.rows.count == 1)
        #expect(result.markedLeftURLs.isEmpty)
        #expect(result.syncPreview(.leftToRight).allSatisfy { $0.action == .blocked })
        #expect(throws: (any Error).self) { try result.verifyCurrent() }
        let preCancelled = compareWithCancellation()
        #expect(preCancelled.cancelled && preCancelled.rows.isEmpty)
    }
    private func compareWithCancellation() -> DirectoryComparisonReport {
        let cancellation = DirectoryComparisonCancellation(); cancellation.cancel()
        return DirectoryComparisonEngine.run(left: left, right: right, cancellation: cancellation)
    }

    @Test func metadataAndDirectoryChangesMakeSnapshotStaleEvenWithRestoredMtime() throws {
        let fileURL = try file("a", in: left)
        let report = compare()
        try report.verifyCurrent()
        try Data("edit".utf8).write(to: fileURL)
        try manager.setAttributes([.modificationDate: timestamp], ofItemAtPath: fileURL.path)
        #expect(throws: (any Error).self) { try report.verifyCurrent() }
        let newReport = compare()
        try file("new", in: right)
        #expect(throws: (any Error).self) { try newReport.verifyCurrent() }
    }

    @Test func changeDuringComparisonIsReportedInsteadOfClaimingEquality() throws {
        let first = try file("a", in: left); try file("b", in: left)
        try file("a", in: right); try file("b", in: right)
        let result = DirectoryComparisonEngine.run(left: left, right: right) { count in
            if count == 1 { try? Data("changed".utf8).write(to: first) }
        }
        #expect(!result.isComplete && result.issues.contains { $0.contains("устарел") })
        #expect(result.markedLeftURLs.isEmpty && result.markedRightURLs.isEmpty)
    }

    @Test func exactContentBoundaryAndEmptyFilesWork() throws {
        try file("empty", in: left, ""); try file("empty", in: right, "")
        try file("chunk", in: left, String(repeating: "x", count: 65_537))
        try file("chunk", in: right, String(repeating: "x", count: 65_536) + "y")
        var options = DirectoryComparisonOptions(); options.compareContents = true
        options.maximumContentBytesPerFile = 65_537; options.maximumTotalContentBytes = 131_074
        let report = compare(options)
        #expect(report.isComplete)
        #expect(report.rows.first { $0.name == "chunk" }?.status == .different)
        #expect(report.rows.first { $0.name == "empty" }?.status == .same)
        #expect(report.contentBytesRead == 131_074)
    }
}
