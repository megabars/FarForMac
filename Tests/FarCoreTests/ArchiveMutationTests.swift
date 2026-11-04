import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite final class ArchiveMutationTests {
    let root: URL
    let fm = FileManager.default
    init() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ArchiveMutationTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? fm.removeItem(at: root) }

    func fixture(_ format: ArchiveFormat) throws -> ArchiveSnapshot {
        let tree = root.appendingPathComponent("tree")
        try fm.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
        // Broad byte distribution exercises content preservation beyond UTF-8 text.
        try Data((0..<131_072).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: tree.appendingPathComponent("binary"))
        let keep = root.appendingPathComponent("keep")
        try Data("keep contents".utf8).write(to: keep)
        return try ArchiveWriter.create(sources: [tree, keep], destination: root.appendingPathComponent("test." + format.rawValue), format: format)
    }
    func contents(_ snapshot: ArchiveSnapshot) throws -> [String: Data] {
        let workspace = try ArchiveReader.extract(snapshot)
        defer { workspace.cleanup() }
        return try Dictionary(uniqueKeysWithValues: snapshot.entries.filter { !$0.isDirectory }.map {
            ($0.path, try Data(contentsOf: workspace.url(for: $0.path)))
        })
    }
    func expectUnchanged(_ snapshot: ArchiveSnapshot, action: () throws -> Void) throws {
        let before = try Data(contentsOf: snapshot.sourceURL)
        #expect(throws: (any Error).self, performing: action)
        #expect(try Data(contentsOf: snapshot.sourceURL) == before)
        #expect(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".far-archive-") })
        try snapshot.verifyCurrent()
    }

    @Test(arguments: [ArchiveFormat.zip, .tar]) func emptyDirectoriesAndSubtreeMovesPreserveEveryByte(format: ArchiveFormat) throws {
        let original = try fixture(format)
        let before = try contents(original)
        let created = try ArchiveWriter.createDirectory(original, path: "new/пустая/empty")
        #expect(created.entries.contains { $0.path == "new/пустая/empty" && $0.isDirectory })
        #expect(try contents(created) == before)
        let moved = try ArchiveWriter.move(created, entries: ["tree": "new/renamed", "keep": "new/kept"])
        #expect(moved.entries.contains { $0.path == "new/renamed/empty" && $0.isDirectory })
        #expect(moved.entries.contains { $0.path == "new/пустая/empty" && $0.isDirectory })
        #expect(!moved.entries.contains { $0.path == "tree" || $0.path.hasPrefix("tree/") || $0.path == "keep" })
        #expect(moved.entries.first { $0.path == "new/renamed/binary" }?.modificationDate ==
                original.entries.first { $0.path == "tree/binary" }?.modificationDate)
        #expect(try contents(moved) == ["new/renamed/binary": before["tree/binary"]!, "new/kept": before["keep"]!])
        let movedContents = try contents(moved)
        let renamed = try ArchiveWriter.move(moved, entries: ["new/renamed/empty": "elsewhere/EMPTY"])
        #expect(renamed.entries.contains { $0.path == "elsewhere/EMPTY" && $0.isDirectory })
        #expect(try contents(renamed) == movedContents)
        #expect(renamed.format == format)
    }

    @Test(arguments: [ArchiveFormat.zip, .tar]) func emptyArchiveAcceptsAndMovesAnExplicitEmptyDirectory(format: ArchiveFormat) throws {
        let empty = try ArchiveWriter.create(sources: [], destination: root.appendingPathComponent("empty." + format.rawValue), format: format)
        let created = try ArchiveWriter.createDirectory(empty, path: "parent/empty")
        #expect(created.entries.map(\.path) == ["parent/empty"])
        #expect(created.entries.allSatisfy { $0.isDirectory })
        let moved = try ArchiveWriter.move(created, entries: ["parent": "new/parent"])
        #expect(moved.entries.map(\.path) == ["new/parent/empty"])
        #expect(try contents(moved).isEmpty)
    }

    @Test func collisionsAndUnsafeDestinationsNeverPublish() throws {
        let snapshot = try fixture(.zip)
        for path in ["tree", "TREE", "tree/binary/child", "keep/child", "../escape", "/absolute", "a//b", "a/./b", "C:drive", "a\\b", "a\0b", String(repeating: "x", count: 256)] {
            try expectUnchanged(snapshot) { _ = try ArchiveWriter.createDirectory(snapshot, path: path) }
        }
        let invalidMoves = [
            ["tree": "tree/child"], ["tree": "TREE/child"], ["tree": "keep"],
            ["keep": "TREE"], ["keep": "tree/empty"], ["keep": "tree/binary/child"],
            ["tree": "dest", "tree/binary": "other"], ["tree": "dest", "keep": "dest/nested"],
            ["tree": "dest", "keep": "DEST"], ["missing": "dest"], ["keep": "../escape"],
            ["keep": "keep"], ["tree": "tree/../escape"], ["tree/binary": "tree"]
        ]
        for mapping in invalidMoves {
            try expectUnchanged(snapshot) { _ = try ArchiveWriter.move(snapshot, entries: mapping) }
        }
    }

    @Test func implicitDirectoryMovesAndCaseOnlyRename() throws {
        var snapshot = try fixture(.tar)
        snapshot = try ArchiveWriter.move(snapshot, entries: ["keep": "implicit/deep/keep"])
        #expect(!snapshot.entries.contains { $0.path == "implicit" })
        snapshot = try ArchiveWriter.move(snapshot, entries: ["implicit": "destination"])
        #expect(try contents(snapshot)["destination/deep/keep"] == Data("keep contents".utf8))
        snapshot = try ArchiveWriter.move(snapshot, entries: ["destination": "DESTINATION"])
        #expect(snapshot.entries.contains { $0.path == "DESTINATION/deep/keep" })
        #expect(!snapshot.entries.contains { $0.path.hasPrefix("destination/") })
    }

    @Test func unicodeNormalizationAndCollidingParentSpellings() throws {
        var snapshot = try fixture(.zip)
        snapshot = try ArchiveWriter.createDirectory(snapshot, path: "cafe\u{301}/empty")
        #expect(snapshot.entries.contains { $0.path == "café/empty" })
        try expectUnchanged(snapshot) { _ = try ArchiveWriter.createDirectory(snapshot, path: "CAFÉ/other") }
        try expectUnchanged(snapshot) { _ = try ArchiveWriter.createDirectory(snapshot, path: "cafe\u{301}") }
        try expectUnchanged(snapshot) { _ = try ArchiveWriter.move(snapshot, entries: ["keep": "CAFÉ/file"]) }
    }

    @Test func cancellationAndStaleSnapshotsKeepSource() throws {
        let snapshot = try fixture(.zip)
        let cancelled = TransferCancellation(); cancelled.cancel()
        try expectUnchanged(snapshot) { _ = try ArchiveWriter.createDirectory(snapshot, path: "new", cancellation: cancelled) }
        let token = TransferCancellation()
        var cancelledDuringRewrite = false
        try expectUnchanged(snapshot) {
            _ = try ArchiveWriter.move(snapshot, entries: ["tree": "new/tree"], cancellation: token, onProgress: { progress in
                if progress.currentPath == "new/tree/binary", progress.completedBytes > 65_536 {
                    cancelledDuringRewrite = true; token.cancel()
                }
            })
        }
        #expect(cancelledDuringRewrite)
        let external = Data("external replacement".utf8)
        try external.write(to: snapshot.sourceURL, options: .atomic)
        #expect(throws: ArchiveError.changedArchive) { try ArchiveWriter.move(snapshot, entries: ["keep": "renamed"]) }
        #expect(throws: ArchiveError.changedArchive) { try ArchiveWriter.createDirectory(snapshot, path: "new") }
        #expect(try Data(contentsOf: snapshot.sourceURL) == external)
    }

    @Test func concurrentReplacementDuringMoveWins() throws {
        let snapshot = try fixture(.tar)
        let external = Data("another writer".utf8)
        var replaced = false
        #expect(throws: ArchiveError.changedArchive) {
            try ArchiveWriter.move(snapshot, entries: ["tree": "moved"], onProgress: { progress in
                if !replaced, progress.currentPath == "moved/binary", progress.completedBytes > 65_536 {
                    replaced = true; try! external.write(to: snapshot.sourceURL, options: .atomic)
                }
            })
        }
        #expect(replaced)
        #expect(try Data(contentsOf: snapshot.sourceURL) == external)
    }
}
