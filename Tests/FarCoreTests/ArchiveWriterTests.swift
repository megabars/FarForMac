import Foundation
import Darwin
import Testing
@testable import FarCore

@Suite final class ArchiveWriterTests {
    let root: URL
    let fm = FileManager.default
    init() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ArchiveWriterTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? fm.removeItem(at: root) }
    func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func bytes(_ snapshot: ArchiveSnapshot, _ path: String) throws -> String {
        let workspace = try ArchiveReader.extract(snapshot)
        defer { workspace.cleanup() }
        return try String(contentsOf: workspace.url(for: path), encoding: .utf8)
    }
    func noStage() throws -> Bool { try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".far-archive-") } }

    @Test(arguments: [ArchiveFormat.zip, .tar]) func createAndReopen(format: ArchiveFormat) throws {
        let source = try file("folder/nested.txt", "archive contents ü\n")
        let archive = root.appendingPathComponent("created." + format.rawValue)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: source.path)
        let snapshot = try ArchiveWriter.create(sources: [source.deletingLastPathComponent()], destination: archive, format: format)
        #expect(snapshot.format == format)
        #expect(snapshot.entries.contains { $0.path == "folder/nested.txt" })
        #expect(try bytes(snapshot, "folder/nested.txt") == "archive contents ü\n")
        #expect(snapshot.entries.first { $0.path == "folder/nested.txt" }?.modificationDate == date)
        #expect(try String(contentsOf: source, encoding: .utf8) == "archive contents ü\n")
        #expect(try noStage())
    }

    @Test func unicodeZIPNamesCarryUTF8FlagInBothHeaderSets() throws {
        let source = try file("папка/текст-日本語.txt", "before")
        let archive = root.appendingPathComponent("unicode.zip")
        let created = try ArchiveWriter.create(sources: [source.deletingLastPathComponent()], destination: archive, format: .zip)
        try expectUTF8ZIPHeaders(archive, names: ["папка/", "папка/текст-日本語.txt"])
        let edited = try file("edited.txt", "after")
        _ = try ArchiveWriter.update(created, replacements: ["папка/текст-日本語.txt": edited])
        try expectUTF8ZIPHeaders(archive, names: ["папка/", "папка/текст-日本語.txt"])
    }

    /// Inspect ZIP bytes directly rather than using libarchive, whose decoding
    /// can mask a missing EFS bit by accepting UTF-8 under the current locale.
    private func expectUTF8ZIPHeaders(_ url: URL, names: Set<String>) throws {
        let data = [UInt8](try Data(contentsOf: url))
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        let end = data.count - 22
        #expect(Array(data[end..<(end + 4)]) == [0x50, 0x4b, 0x05, 0x06])
        var offset = u32(end + 16), observed = Set<String>()
        for _ in 0..<u16(end + 10) {
            #expect(Array(data[offset..<(offset + 4)]) == [0x50, 0x4b, 0x01, 0x02])
            let nameLength = u16(offset + 28)
            let nameBytes = Array(data[(offset + 46)..<(offset + 46 + nameLength)])
            let name = try #require(String(bytes: nameBytes, encoding: .utf8))
            observed.insert(name)
            #expect(u16(offset + 8) & 0x0800 != 0, "Central header must mark UTF-8: \(name)")
            let local = u32(offset + 42)
            #expect(Array(data[local..<(local + 4)]) == [0x50, 0x4b, 0x03, 0x04])
            #expect(u16(local + 6) & 0x0800 != 0, "Local header must mark UTF-8: \(name)")
            #expect(u16(local + 26) == nameLength)
            #expect(Array(data[(local + 30)..<(local + 30 + nameLength)]) == nameBytes)
            offset += 46 + nameLength + u16(offset + 30) + u16(offset + 32)
        }
        #expect(observed == names)
    }

    @Test(arguments: [ArchiveFormat.zip, .tar]) func deletingLastEntryProducesEmptyArchive(format: ArchiveFormat) throws {
        let source = try file("last.txt", "data")
        let archive = root.appendingPathComponent("empty." + format.rawValue)
        let snapshot = try ArchiveWriter.create(sources: [source], destination: archive, format: format)
        let updated = try ArchiveWriter.update(snapshot, deletions: ["last.txt"])
        #expect(updated.entries.isEmpty)
        #expect(updated.format == format)
    }

    @Test func conflictSkipReplaceAndDirectoryDelete() throws {
        let original = try file("original/a.txt", "original")
        let nested = try file("original/sub/b.txt", "retained")
        let archive = root.appendingPathComponent("archive.zip")
        var snapshot = try ArchiveWriter.create(sources: [original.deletingLastPathComponent()], destination: archive, format: .zip)
        let replacement = try file("incoming/a.txt", "replacement")
        let before = try Data(contentsOf: archive)
        #expect(throws: ArchiveWriteError.self) { try ArchiveWriter.update(snapshot, additions: [replacement], prefix: "original") }
        #expect(try Data(contentsOf: archive) == before)
        snapshot = try ArchiveWriter.update(snapshot, additions: [replacement], prefix: "original", policy: .skip)
        #expect(try bytes(snapshot, "original/a.txt") == "original")
        snapshot = try ArchiveWriter.update(snapshot, additions: [replacement], prefix: "original", policy: .replace)
        #expect(try bytes(snapshot, "original/a.txt") == "replacement")
        #expect(try bytes(snapshot, "original/sub/b.txt") == "retained")
        snapshot = try ArchiveWriter.update(snapshot, deletions: ["original/sub"])
        #expect(!snapshot.entries.contains { $0.path.hasPrefix("original/sub") })
        #expect(fm.fileExists(atPath: nested.path))
        #expect(try noStage())
    }

    @Test func exactNestedEditorReplacementRetainsOtherEntries() throws {
        let source = try file("folder/deep/a.txt", "before")
        let other = try file("folder/other.txt", "other")
        let archive = root.appendingPathComponent("archive.tar")
        let snapshot = try ArchiveWriter.create(sources: [root.appendingPathComponent("folder")], destination: archive, format: .tar)
        let edit = try file("working-copy.txt", "after")
        let updated = try ArchiveWriter.update(snapshot, replacements: ["folder/deep/a.txt": edit])
        #expect(updated.format == .tar)
        #expect(try bytes(updated, "folder/deep/a.txt") == "after")
        #expect(try bytes(updated, "folder/other.txt") == "other")
        #expect(try String(contentsOf: source, encoding: .utf8) == "before")
        #expect(try String(contentsOf: other, encoding: .utf8) == "other")
    }

    @Test func changedArchiveIsNeverOverwritten() throws {
        let source = try file("a.txt", "a")
        let archive = root.appendingPathComponent("archive.zip")
        let snapshot = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip)
        let external = Data("external replacement".utf8)
        try external.write(to: archive, options: .atomic)
        #expect(throws: ArchiveError.changedArchive) { try ArchiveWriter.update(snapshot, deletions: ["a.txt"]) }
        #expect(try Data(contentsOf: archive) == external)
    }

    @Test func externalReplacementDuringWriteSurvivesCommitCheck() throws {
        let source = try file("a.txt", "original")
        let archive = root.appendingPathComponent("archive.zip")
        let snapshot = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip)
        let replacement = try file("edited.txt", String(repeating: "abc", count: 10_000))
        let external = Data("external writer wins".utf8)
        var changed = false
        #expect(throws: ArchiveError.changedArchive) {
            try ArchiveWriter.update(snapshot, replacements: ["a.txt": replacement], onProgress: { value in
                if !changed && value.totalBytes == 30_000 && value.completedBytes > 0 {
                    changed = true
                    try! external.write(to: archive, options: .atomic)
                }
            })
        }
        #expect(changed)
        #expect(try Data(contentsOf: archive) == external)
        #expect(try noStage())
    }

    @Test func cancellationKeepsOriginalAndRemovesStage() throws {
        let source = try file("a.txt", "original")
        let archive = root.appendingPathComponent("archive.zip")
        let snapshot = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip)
        let before = try Data(contentsOf: archive)
        let replacement = try file("edited.txt", String(repeating: "x", count: 512_000))
        let token = TransferCancellation()
        #expect(throws: ArchiveError.cancelled) {
            try ArchiveWriter.update(snapshot, replacements: ["a.txt": replacement], cancellation: token, onProgress: { value in
                if value.totalBytes >= 512_000 && value.completedBytes > 0 { token.cancel() }
            })
        }
        #expect(try Data(contentsOf: archive) == before)
        #expect(try String(contentsOf: source, encoding: .utf8) == "original")
        #expect(try noStage())
    }

    @Test func maliciousNamesLinksAndSpecialSourcesAreRejected() throws {
        let source = try file("a.txt", "data")
        let archive = root.appendingPathComponent("archive.zip")
        let snapshot = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip)
        let before = try Data(contentsOf: archive)
        for path in ["../escape", "/absolute", "a/../../escape", "a\\b", "C:drive"] {
            #expect(throws: ArchiveError.self) { try ArchiveWriter.update(snapshot, replacements: [path: source]) }
        }
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: ArchiveError.self) { try ArchiveWriter.update(snapshot, additions: [link]) }
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ArchiveError.self) { try ArchiveWriter.update(snapshot, additions: [fifo]) }
        #expect(try Data(contentsOf: archive) == before)
        #expect(try noStage())
    }

    @Test func destinationInsideSourceAndSourceArchiveAreRejected() throws {
        let source = try file("folder/a.txt", "data")
        let destination = source.deletingLastPathComponent().appendingPathComponent("self.zip")
        #expect(throws: ArchiveError.self) {
            try ArchiveWriter.create(sources: [source.deletingLastPathComponent()], destination: destination, format: .zip)
        }
        #expect(!fm.fileExists(atPath: destination.path))
        let archive = root.appendingPathComponent("archive.zip")
        let snapshot = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip)
        let before = try Data(contentsOf: archive)
        #expect(throws: ArchiveError.self) { try ArchiveWriter.update(snapshot, additions: [archive]) }
        #expect(throws: ArchiveError.self) { try ArchiveWriter.update(snapshot, additions: [root]) }
        #expect(try Data(contentsOf: archive) == before)
    }

    @Test func createIsExclusiveAndExplicitReplacePreservesDestinationMetadata() throws {
        let source = try file("a.txt", "new")
        let archive = root.appendingPathComponent("archive.zip")
        let original = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip)
        let before = try Data(contentsOf: archive)
        #expect(throws: ArchiveWriteError.self) { try ArchiveWriter.create(sources: [source], destination: archive, format: .zip) }
        #expect(try Data(contentsOf: archive) == before)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: archive.path)
        try Data("changed".utf8).write(to: source)
        let replaced = try ArchiveWriter.create(sources: [source], destination: archive, format: .zip, policy: .replace)
        #expect(try bytes(replaced, "a.txt") == "changed")
        #expect((try fm.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(original.format == .zip)
    }
}
