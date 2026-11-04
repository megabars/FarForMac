import Foundation
import Darwin
import CArchive
import Testing
@testable import FarCore

@Suite
final class ArchiveReaderTests {
    private let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FarArchiveReader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    struct Member {
        let name: String
        let text: String
        var type: mode_t = mode_t(S_IFREG)
        var link: String? = nil
        var hardlink = false
    }
    private func fixture(_ members: [Member], format: ArchiveFormat = .zip,
                         password: String? = nil, encryptedAES: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + "." + format.rawValue)
        let writer = archive_write_new()!
        defer { archive_write_free(writer) }
        try check(format == .zip ? archive_write_set_format_zip(writer) : archive_write_set_format_pax_restricted(writer), writer)
        if let password {
            try check(archive_write_set_options(writer, encryptedAES ? "zip:encryption=aes256" : "zip:encryption=zipcrypt"), writer)
            try check(archive_write_set_passphrase(writer, password), writer)
        }
        try check(archive_write_open_filename(writer, url.path), writer)
        for member in members {
            let entry = archive_entry_new()!
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, member.name)
            archive_entry_set_filetype(entry, UInt32(member.type))
            archive_entry_set_perm(entry, mode_t(0o644))
            archive_entry_set_mtime(entry, 1_700_000_000, 0)
            let bytes = Array(member.text.utf8)
            archive_entry_set_size(entry, member.type == S_IFREG && member.link == nil ? Int64(bytes.count) : 0)
            if let link = member.link {
                if member.hardlink { archive_entry_set_hardlink(entry, link) }
                else { archive_entry_set_symlink(entry, link) }
            }
            try check(archive_write_header(writer, entry), writer)
            if member.type == S_IFREG && member.link == nil && !bytes.isEmpty {
                let written = bytes.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                guard written == bytes.count else { throw ArchiveError.io("Fixture write failed") }
            }
            try check(archive_write_finish_entry(writer), writer)
        }
        try check(archive_write_close(writer), writer)
        return url
    }
    private func check(_ result: Int32, _ archive: OpaquePointer) throws {
        guard result == ARCHIVE_OK else {
            throw ArchiveError.io(archive_error_string(archive).map { String(cString: $0) } ?? "Fixture failure")
        }
    }

    @Test func zipAndTarListUnicodeAndExtractSelectionIntoPrivateWorkspace() throws {
        for format in [ArchiveFormat.zip, .tar] {
            let url = try fixture([Member(name: "папка/", text: "", type: mode_t(S_IFDIR)),
                                   Member(name: "папка/日本語.txt", text: "Привет 🌍"),
                                   Member(name: "other", text: "keep")], format: format)
            let snapshot = try ArchiveReader.open(url)
            #expect(snapshot.format == format)
            #expect(snapshot.entries.map(\.path) == ["папка", "папка/日本語.txt", "other"])
            #expect(!snapshot.isEncrypted)
            let workspace = try ArchiveReader.extract(snapshot, paths: ["папка"])
            #expect(try String(contentsOf: workspace.url(for: "папка/日本語.txt"), encoding: .utf8) == "Привет 🌍")
            #expect(!FileManager.default.fileExists(atPath: workspace.rootURL.appendingPathComponent("other").path))
            let mode = try FileManager.default.attributesOfItem(atPath: workspace.rootURL.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700)
            workspace.cleanup()
            #expect(!FileManager.default.fileExists(atPath: workspace.rootURL.path))
        }
    }

    @Test func emptyArchivesRemainReadableAndExtractToEmptyWorkspaces() throws {
        for format in [ArchiveFormat.zip, .tar] {
            let url = try fixture([], format: format)
            let snapshot = try ArchiveReader.open(url)
            #expect(snapshot.entries.isEmpty)
            #expect(snapshot.format == format)
            let workspace = try ArchiveReader.extract(snapshot)
            defer { workspace.cleanup() }
            #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.rootURL.path).isEmpty)
        }
    }

    @Test func rejectsTraversalAbsoluteWindowsPathsAndAmbiguousHierarchy() throws {
        for format in [ArchiveFormat.zip, .tar] {
            for path in ["../escape", "/absolute", "a/../../escape", "a//b", "C:/escape", "a\\b", "a/./b"] {
                let url = try fixture([Member(name: path, text: "hostile")], format: format)
                #expect(throws: (any Error).self, "\(format.rawValue): \(path)") { try ArchiveReader.open(url) }
            }
            for names in [["a", "a/b"], ["a/b", "a"], ["same", "same"], ["A/b", "a/c"], ["é", "e\u{301}"]] {
                let url = try fixture(names.map { Member(name: $0, text: "hostile") }, format: format)
                #expect(throws: (any Error).self) { try ArchiveReader.open(url) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    @Test func rejectsSymlinkHardlinkAndSpecialFileBeforeExtraction() throws {
        let members = [Member(name: "safe", text: "keep"),
                       Member(name: "outside", text: "", type: mode_t(S_IFLNK), link: "../../outside")]
        for format in [ArchiveFormat.zip, .tar] {
            let url = try fixture(members, format: format)
            #expect(throws: (any Error).self) { try ArchiveReader.open(url) }
        }
        let hard = try fixture([Member(name: "hard", text: "", link: "../outside", hardlink: true)], format: .tar)
        #expect(throws: (any Error).self) { try ArchiveReader.open(hard) }
        let fifo = try fixture([Member(name: "fifo", text: "", type: mode_t(S_IFIFO))], format: .tar)
        #expect(throws: (any Error).self) { try ArchiveReader.open(fifo) }
    }

    @Test func limitsDeclaredSizesCountsExpansionAndCooperativeCancellation() throws {
        let url = try fixture([Member(name: "a", text: String(repeating: "x", count: 50_000)), Member(name: "b", text: "y")])
        #expect(throws: (any Error).self) { try ArchiveReader.open(url, limits: ArchiveLimits(maximumEntries: 1)) }
        #expect(throws: (any Error).self) { try ArchiveReader.open(url, limits: ArchiveLimits(maximumEntryBytes: 10)) }
        #expect(throws: (any Error).self) { try ArchiveReader.open(url, limits: ArchiveLimits(maximumTotalBytes: 49_999)) }
        #expect(throws: (any Error).self) { try ArchiveReader.open(url, limits: ArchiveLimits(maximumExpansionRatio: 1)) }
        let cancelled = TransferCancellation(); cancelled.cancel()
        #expect(throws: ArchiveError.cancelled) { try ArchiveReader.open(url, cancellation: cancelled) }
        let snapshot = try ArchiveReader.open(url)
        let stop = TransferCancellation()
        #expect(throws: ArchiveError.cancelled) {
            try ArchiveReader.extract(snapshot, cancellation: stop) { progress in
                if progress.completedBytes > 0 { stop.cancel() }
            }
        }
    }

    @Test func encryptedZIPUsesInMemoryPasswordAndReportsMissingOrWrongPassword() throws {
        for aes in [false, true] {
            let url = try fixture([Member(name: "secret.txt", text: "confidential payload")], password: "fixture-only-password", encryptedAES: aes)
            let snapshot = try ArchiveReader.open(url)
            #expect(snapshot.isEncrypted)
            let original = try Data(contentsOf: url)
            do {
                _ = try ArchiveWriter.update(snapshot, deletions: ["secret.txt"])
                Issue.record("Encrypted archive modification must be rejected")
            } catch ArchiveWriteError.encryptedReadOnly {
                // Encryption must be preserved by refusing unsupported updates.
            }
            #expect(throws: ArchiveWriteError.self) { try ArchiveWriter.createDirectory(snapshot, path: "new") }
            #expect(throws: ArchiveWriteError.self) { try ArchiveWriter.move(snapshot, entries: ["secret.txt": "renamed.txt"]) }
            #expect(try Data(contentsOf: url) == original)
            #expect(throws: ArchiveError.passwordRequired) { try ArchiveReader.extract(snapshot) }
            #expect(throws: ArchiveError.incorrectPassword) { try ArchiveReader.extract(snapshot, password: "wrong-password") }
            let workspace = try ArchiveReader.extract(snapshot, password: "fixture-only-password")
            defer { workspace.cleanup() }
            #expect(try String(contentsOf: workspace.url(for: "secret.txt"), encoding: .utf8) == "confidential payload")
        }
    }

    @Test func changedArchiveCannotBeMaterializedAndSymlinkSourceIsRejected() throws {
        let url = try fixture([Member(name: "file", text: "original")])
        let snapshot = try ArchiveReader.open(url)
        try Data("replacement".utf8).write(to: url)
        #expect(throws: ArchiveError.changedArchive) { try snapshot.verifyCurrent() }
        #expect(throws: ArchiveError.changedArchive) { try ArchiveReader.extract(snapshot) }
        let link = root.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try ArchiveReader.open(link) }
    }

    @Test func corruptionAndTruncationAreVisible() throws {
        let url = try fixture([Member(name: "file", text: String(repeating: "payload", count: 100))])
        var data = try Data(contentsOf: url)
        data.removeLast(15)
        try data.write(to: url)
        #expect(throws: (any Error).self) { try ArchiveReader.open(url) }
        let tar = try fixture([Member(name: "file", text: String(repeating: "payload", count: 1000))], format: .tar)
        var tarData = try Data(contentsOf: tar)
        tarData = tarData.prefix(600)
        try tarData.write(to: tar)
        #expect(throws: (any Error).self) {
            let snapshot = try ArchiveReader.open(tar)
            _ = try ArchiveReader.extract(snapshot)
        }
    }

    @Test func nulInZIPLengthDelimitedNameIsRejected() throws {
        let url = try fixture([Member(name: "aXb", text: "payload")])
        var bytes = [UInt8](try Data(contentsOf: url))
        for i in 0..<(bytes.count - 2) where bytes[i] == 97 && bytes[i + 1] == 88 && bytes[i + 2] == 98 { bytes[i + 1] = 0 }
        try Data(bytes).write(to: url)
        #expect(throws: (any Error).self) { try ArchiveReader.open(url) }
    }

    @Test func rawZIPBackslashIsRejectedBeforeLibraryNormalizesIt() throws {
        let url = try fixture([Member(name: "a/b", text: "payload")])
        var bytes = [UInt8](try Data(contentsOf: url))
        for i in 0..<(bytes.count - 2) where bytes[i] == 97 && bytes[i + 1] == 47 && bytes[i + 2] == 98 {
            bytes[i + 1] = 92
        }
        try Data(bytes).write(to: url)
        #expect(throws: ArchiveError.invalidPath("a\\b")) { try ArchiveReader.open(url) }
    }

    @Test func crcFailureDuringExtractionIsCorruption() throws {
        let url = try fixture([Member(name: "file", text: "data")])
        var bytes = [UInt8](try Data(contentsOf: url))
        // Change the central directory CRC, retaining a structurally valid ZIP.
        let central = (0..<(bytes.count - 46)).first { Array(bytes[$0..<($0 + 4)]) == [0x50, 0x4b, 0x01, 0x02] }!
        bytes[central + 16] ^= 0xff
        try Data(bytes).write(to: url)
        let snapshot = try ArchiveReader.open(url)
        #expect(throws: (any Error).self) { try ArchiveReader.extract(snapshot) }
    }

    @Test func selectedImplicitDirectoryIncludesDescendantsAndInvalidSelectionFails() throws {
        let url = try fixture([Member(name: "implicit/deep/file", text: "value"), Member(name: "other", text: "x")])
        let snapshot = try ArchiveReader.open(url)
        let workspace = try ArchiveReader.extract(snapshot, paths: ["implicit"])
        defer { workspace.cleanup() }
        #expect(try String(contentsOf: workspace.url(for: "implicit/deep/file"), encoding: .utf8) == "value")
        #expect(throws: (any Error).self) { try workspace.url(for: "../escape") }
        #expect(throws: (any Error).self) { try ArchiveReader.extract(snapshot, paths: ["missing"]) }
    }
}
