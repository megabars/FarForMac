import Foundation
import Darwin
import CArchive
import Testing
@testable import FarCore

/// Fixtures are written directly through libarchive, independently of the app writer.
@Suite final class ArchiveSearchTests {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("FarArchiveSearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ path: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }
    func archive(_ path: String, _ members: [(String, Data)], format: ArchiveFormat = .zip,
                 password: String? = nil, symlink: Bool = false, ownerName: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = archive_write_new()!
        defer { archive_write_free(writer) }
        func check(_ code: Int32) throws {
            guard code == ARCHIVE_OK else { throw ArchiveError.io(archive_error_string(writer).map(String.init(cString:)) ?? "fixture") }
        }
        try check(format == .zip ? archive_write_set_format_zip(writer) : archive_write_set_format_pax_restricted(writer))
        switch format {
        case .tarGzip: try check(archive_write_add_filter_gzip(writer))
        case .tarBzip2: try check(archive_write_add_filter_bzip2(writer))
        case .tarXz: try check(archive_write_add_filter_xz(writer))
        default: break
        }
        if let password {
            try check(archive_write_set_options(writer, "zip:encryption=zipcrypt"))
            try check(archive_write_set_passphrase(writer, password))
        }
        try check(archive_write_open_filename(writer, url.path))
        for (name, bytes) in members {
            let entry = archive_entry_new()!
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, name)
            archive_entry_set_filetype(entry, UInt32(symlink ? S_IFLNK : (name.hasSuffix("/") ? S_IFDIR : S_IFREG)))
            archive_entry_set_perm(entry, 0o600)
            if let ownerName { archive_entry_set_uname(entry, ownerName) }
            archive_entry_set_mtime(entry, 1_700_000_000, 0)
            archive_entry_set_size(entry, symlink ? 0 : Int64(bytes.count))
            if symlink { archive_entry_set_symlink_utf8(entry, "/etc/passwd") }
            try check(archive_write_header(writer, entry))
            if !bytes.isEmpty && !symlink {
                let count = bytes.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) }
                guard count == bytes.count else { throw ArchiveError.io("fixture data") }
            }
            try check(archive_write_finish_entry(writer))
        }
        try check(archive_write_close(writer))
        return url
    }
    func options(_ roots: [URL]? = nil, content: String? = nil) -> SearchOptions {
        var value = SearchOptions(roots: roots ?? [root])
        value.searchArchives = true
        value.searchNestedArchives = true
        value.kinds = [.file]
        if let content { value.contentMode = .literal; value.contentQuery = content }
        return value
    }
    struct Found {
        let summary: SearchSummary
        let local: [SearchResult]
        let archived: [ProviderSearchResult]
        let issues: [SearchIssue]
    }
    func collect(_ options: SearchOptions, groups: [String: String] = [:],
                 limits: ArchiveSearchLimits = .default,
                 cancellation: SearchCancellation = SearchCancellation(),
                 event: ((SearchEvent) -> Void)? = nil) -> Found {
        var local: [SearchResult] = [], archived: [ProviderSearchResult] = [], issues: [SearchIssue] = []
        let summary = SearchEngine.run(SearchRequest(options: options, maskGroups: groups), archiveLimits: limits,
                                      cancellation: cancellation) {
            switch $0 {
            case .result(let value): local.append(value)
            case .archiveResult(let value): archived.append(value)
            case .issue(let value): issues.append(value)
            case .progress: break
            }
            event?($0)
        }
        return Found(summary: summary, local: local, archived: archived, issues: issues)
    }

    @Test(arguments: [ArchiveFormat.zip, .tar, .tarGzip, .tarBzip2, .tarXz])
    func localWalkDiscoversArchiveDespiteOuterMaskAndMetadataFilters(format: ArchiveFormat) throws {
        let url = try archive("outer.container", [("folder/report.txt", Data("needle".utf8)),
            ("folder/skip.txt", Data("needle".utf8)), ("folder/report.log", Data("needle".utf8))], format: format)
        var request = options([url])
        request.namePattern = "<text>|skip*"; request.minSize = 6; request.maxSize = 6
        request.modifiedAfter = Date(timeIntervalSince1970: 1_699_999_999)
        request.modifiedBefore = Date(timeIntervalSince1970: 1_700_000_001)
        let found = collect(request, groups: ["text": "*.txt"])
        #expect(found.summary.errors == 0)
        #expect(found.local.isEmpty)
        #expect(found.archived.map(\.path) == ["folder/report.txt"])
        let result = try #require(found.archived.first)
        #expect(result.archiveDisplayPath == url.path)
        try result.verifyArchiveCurrent(snapshot: #require(result.capturedArchiveSnapshot))
    }

    @Test func archiveScanningIsOffByDefaultAndOldOptionsDecode() throws {
        let url = try archive("outer.zip", [("inner.txt", Data("needle".utf8))])
        var request = SearchOptions(roots: [url]); request.namePattern = "*.txt"
        #expect(collect(request).archived.isEmpty)
        let data = try JSONEncoder().encode(request)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "searchArchives"); json.removeValue(forKey: "searchNestedArchives")
        request = try JSONDecoder().decode(SearchOptions.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(request.searchArchives != true)
        #expect(request.searchNestedArchives != true)
        #expect(collect(request).archived.isEmpty)
    }

    @Test func hiddenArchiveAndHiddenMembersFollowLocalPolicy() throws {
        _ = try archive("visible.zip", [("plain.txt", Data()), (".hidden.txt", Data()), (".private/deep.txt", Data())])
        _ = try archive(".secret.zip", [("secret.txt", Data())])
        var request = options(); request.namePattern = "*.txt"
        #expect(collect(request).archived.map(\.name) == ["plain.txt"])
        request.includeHidden = true
        #expect(Set(collect(request).archived.map(\.name)) == ["plain.txt", ".hidden.txt", "deep.txt", "secret.txt"])
    }

    @Test(arguments: [ArchiveFormat.zip, .tarGzip, .tarBzip2, .tarXz])
    func nestedArchiveSupportsDecodedTextAndRawHex(format: ArchiveFormat) throws {
        let inner = try archive("fixture", [("text.txt", Data("first\r\nПривет 🌍".utf8)),
            ("binary.bin", Data([0, 255, 254, 65]))], format: format)
        let outer = try archive("scope/outer.zip", [("nested", try Data(contentsOf: inner))])
        var request = options([outer], content: "привет"); request.namePattern = "*.txt"
        let text = collect(request)
        #expect(text.summary.errors == 0)
        let result = try #require(text.archived.first)
        #expect(text.archived.count == 1)
        #expect(result.path == "text.txt"); #expect(result.lineNumber == 2)
        #expect(result.snippet?.contains("Привет") == true)
        #expect(result.archiveDisplayPath == outer.path + " !/nested")
        request.namePattern = "*.bin"; request.contentMode = .hex; request.contentQuery = "FF fe 41"
        request.contentEncoding = .utf16BE
        let hex = collect(request)
        #expect(hex.summary.errors == 0); #expect(hex.archived.count == 1)
        #expect(hex.archived.first?.byteOffset == 1); #expect(hex.archived.first?.lineNumber == nil)
        #expect(hex.archived.first?.snippet == "0x1: FF FE 41")
    }

    @Test func nestedSwitchAndImplicitDirectoriesAreIndependentOfNameMask() throws {
        let inner = try archive("fixture", [("parent/child/item.txt", Data())])
        let outer = try archive("outer.zip", [("nested.dat", try Data(contentsOf: inner))])
        var request = options([outer]); request.namePattern = "*.txt"; request.searchNestedArchives = false
        #expect(collect(request).archived.isEmpty)
        request.searchNestedArchives = true; request.kinds = [.directory]; request.namePattern = "*"
        let directories = collect(request)
        #expect(Set(directories.archived.map(\.path)) == ["parent", "parent/child"])
        #expect(directories.summary.errors == 0)
        for result in directories.archived {
            try result.verifyArchiveCurrent(snapshot: #require(result.capturedArchiveSnapshot))
        }
    }

    @Test func duplicateMemberNamesHaveDistinctIdentityAndDisplayPath() throws {
        let a = try archive("a.zip", [("same.txt", Data())])
        let b = try archive("b.zip", [("same.txt", Data())])
        var request = options([a, b]); request.namePattern = "*.txt"
        let found = collect(request)
        #expect(found.archived.count == 2)
        #expect(Set(found.archived.map(\.id)).count == 2)
        #expect(Set(found.archived.compactMap(\.archiveDisplayPath)) == [a.path, b.path])
        request.roots = [root, a, b, root]
        let overlapping = collect(request)
        #expect(overlapping.archived.count == 2)
        #expect(Set(overlapping.archived.map(\.id)).count == 2)
    }

    @Test func changedOuterArchiveInvalidatesNestedResultAndRetainedCopy() throws {
        let inner = try archive("fixture", [("item.txt", Data("needle".utf8))])
        let outer = try archive("outer.zip", [("inner.zip", try Data(contentsOf: inner))])
        var request = options([outer], content: "needle"); request.namePattern = "*.txt"
        let result = try #require(collect(request).archived.first)
        let snapshot = try #require(result.capturedArchiveSnapshot)
        try result.verifyArchiveCurrent(snapshot: snapshot)
        let workspace = try ArchiveReader.extract(snapshot, paths: [result.path])
        defer { workspace.cleanup() }
        #expect(try Data(contentsOf: workspace.url(for: result.path)) == Data("needle".utf8))
        try Data([1, 2, 3]).write(to: outer, options: .atomic)
        #expect(throws: ArchiveError.changedArchive) { try result.verifyArchiveCurrent(snapshot: snapshot) }
        #expect(throws: ArchiveError.changedArchive) { try ArchiveReader.extract(snapshot, paths: [result.path]) }
    }

    @Test func nestedResultRetainsItsSourceUntilLastOwnerIsReleased() throws {
        let inner = try archive("fixture", [("item.txt", Data("needle".utf8))])
        let outer = try archive("outer.zip", [("inner.zip", try Data(contentsOf: inner))])
        var request = options([outer]); request.namePattern = "*.txt"
        var result: ProviderSearchResult? = try #require(collect(request).archived.first)
        let source = try #require(result?.capturedArchiveSnapshot?.sourceURL)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(source.path != inner.path)
        do {
            let retained = try #require(result?.capturedArchiveSnapshot)
            result = nil
            #expect(FileManager.default.fileExists(atPath: source.path))
            let copy = try ArchiveReader.extract(retained, paths: ["item.txt"])
            defer { copy.cleanup() }
            #expect(try Data(contentsOf: copy.url(for: "item.txt")) == Data("needle".utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func encryptedMembersAreMetadataMatchesButContentIsAnExplicitSkip() throws {
        let url = try archive("encrypted.zip", [("secret.txt", Data("needle".utf8))], password: "not persisted")
        var request = options([url]); request.namePattern = "*.txt"
        request.searchNestedArchives = false
        let metadata = collect(request)
        #expect(metadata.archived.count == 1); #expect(metadata.summary.errors == 0)
        request.contentMode = .literal; request.contentQuery = "needle"
        let content = collect(request)
        #expect(content.archived.isEmpty); #expect(content.summary.errors > 0)
        #expect(!content.issues.isEmpty); #expect(content.summary.summary.contains("частично"))
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!json.contains("not persisted"))
    }

    @Test func corruptUnsupportedAndMaliciousArchivesProduceVisibleIssues() throws {
        let corrupt = try file("broken.zip", Data([0x50, 0x4b, 0x03, 0x04, 0, 0]))
        let unsupported = try file("unsupported.7z", Data([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c, 0, 4, 0, 0]))
        let traversal = try archive("traversal.tar", [("../escaped.txt", Data("needle".utf8))], format: .tar)
        let link = try archive("link.tar", [("link.txt", Data())], format: .tar, symlink: true)
        for url in [corrupt, unsupported, traversal, link] {
            var request = options([url]); request.namePattern = "*.txt"
            let found = collect(request)
            #expect(found.archived.isEmpty)
            #expect(found.summary.errors > 0)
            #expect(found.issues.contains { $0.path.contains(url.lastPathComponent) })
        }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    }

    @Test func archiveContentCapAndTotalBudgetDoNotRestrictLocalFiles() throws {
        let url = try archive("outer.zip", [("a.txt", Data("needle".utf8)), ("b.txt", Data("needle".utf8))])
        var request = options([url], content: "needle"); request.namePattern = "*.txt"; request.maximumContentBytes = 5
        let perEntry = collect(request)
        #expect(perEntry.archived.isEmpty); #expect(perEntry.summary.errors == 2)
        request.maximumContentBytes = 6
        let total = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: 6))
        #expect(total.archived.count <= 1); #expect(total.summary.errors > 0)
        let local = try file("local.txt", Data((String(repeating: "x", count: 128) + "needle").utf8))
        request.roots = [local, url]
        request.maximumContentBytes = 1024
        let shared = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: 6))
        #expect(shared.local.count == 1); #expect(shared.archived.isEmpty)
        #expect(shared.summary.errors > 0)
    }

    @Test func changingAncestorLinkCannotSubstituteDiscoveredArchive() throws {
        let original = try archive("original/input.zip", [("original.txt", Data("old".utf8))])
        let replacement = try archive("replacement/input.zip", [("replacement.txt", Data("new".utf8))])
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original.deletingLastPathComponent())
        var request = options([alias]); request.followSymbolicLinks = true; request.namePattern = "*.txt"
        var swapped = false
        let found = collect(request) { event in
            guard !swapped, case .progress(let progress) = event,
                  progress.currentPath == alias.appendingPathComponent("input.zip").path else { return }
            swapped = true
            do {
                try FileManager.default.removeItem(at: alias)
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: replacement.deletingLastPathComponent())
            } catch { Issue.record("Could not replace ancestor link: \(error)") }
        }
        #expect(swapped)
        #expect(found.archived.isEmpty)
        #expect(found.summary.errors > 0)
    }

    @Test func thousandMembersAreScannedWithoutRepeatedHeaderBudgetConsumption() throws {
        let members = (0..<1000).map { ("folder/item\($0).txt", Data("needle".utf8)) }
        let url = try archive("thousand.zip", members)
        var request = options([url], content: "needle"); request.namePattern = "*.txt"
        let found = collect(request)
        #expect(found.archived.count == 1000)
        #expect(found.summary.matches == 1000)
        #expect(found.summary.errors == 0, "\(found.issues.map { $0.path + ": " + $0.message }.joined(separator: "\n"))")
        #expect(!found.summary.limitReached)
        #expect(Set(found.archived.map(\.id)).count == 1000)
    }

    @Test func nestedExtractionAndContentUseOneAggregateReadBudget() throws {
        let inner = try archive("fixture", [("item.txt", Data("needle".utf8))])
        let bytes = try Data(contentsOf: inner)
        let outer = try archive("outer.zip", [("nested", bytes)])
        var request = options([outer], content: "needle"); request.namePattern = "*.txt"
        let exhausted = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: Int64(bytes.count)))
        #expect(exhausted.archived.isEmpty)
        #expect(exhausted.summary.errors > 0)
        // The same ceiling also pays for bounded listing/draining and scanner
        // reads, including repeated verification of the nested container.
        let enough = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: 1024 * 1024))
        #expect(enough.archived.count == 1)
        #expect(enough.summary.errors == 0)
    }

    @Test func forgedZIPUncompressedSizeCannotHideActualExpansion() throws {
        let url = try archive("forged.zip", [("item.txt", Data(repeating: 0x61, count: 128 * 1024))])
        var bytes = try Data(contentsOf: url)
        let local = try #require(bytes.range(of: Data([0x50, 0x4b, 0x03, 0x04]))).lowerBound
        let central = try #require(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        // Both advertised sizes are forged. The deflate payload and CRC still
        // describe 128 KiB; trusting only either header would bypass a 1 KiB cap.
        for offset in [local + 22, central + 24] {
            bytes[offset] = 1
            for index in 1..<4 { bytes[offset + index] = 0 }
        }
        try bytes.write(to: url)
        var request = options([url], content: "aaa"); request.namePattern = "*.txt"
        request.maximumContentBytes = 1024
        let found = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: 1024))
        #expect(found.archived.isEmpty)
        #expect(found.summary.errors > 0)
    }

    @Test func resultLimitIsSharedAcrossLocalAndArchiveResults() throws {
        let local = try file("local.txt", Data())
        let url = try archive("outer.zip", [("a.txt", Data()), ("b.txt", Data())])
        var request = options([local, url]); request.namePattern = "*.txt"; request.maximumResults = 2
        let limited = collect(request)
        #expect(limited.summary.limitReached)
        #expect(limited.local.count + limited.archived.count == 2)
        #expect(limited.summary.matches == 2)
    }

    @Test(arguments: [ArchiveFormat.tarGzip, .tarBzip2, .tarXz])
    func compressedListingCannotDrainUnmatchedPayloadBeyondReadBudget(format: ArchiveFormat) throws {
        let url = try archive("outer.container", [("ignored.bin", Data(repeating: 0x61, count: 128 * 1024)),
            ("item.txt", Data("needle".utf8))], format: format)
        var request = options([url]); request.namePattern = "*.txt"
        let limited = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: 1024))
        #expect(limited.archived.isEmpty)
        #expect(limited.summary.errors > 0)
        let complete = collect(request)
        #expect(complete.archived.map(\.name) == ["item.txt"])
        #expect(complete.summary.errors == 0)
    }

    @Test(arguments: [ArchiveFormat.tarGzip, .tarBzip2, .tarXz])
    func hiddenPAXMetadataConsumesTheAggregateDecompressionBudget(format: ArchiveFormat) throws {
        // The owner cannot fit in the ordinary TAR header, forcing an internal
        // PAX extension. libarchive consumes it inside next_header, without
        // exposing it as an ArchiveEntry or returning its bytes as file data.
        let url = try archive("pax.container", [("item.txt", Data("needle".utf8))],
                              format: format, ownerName: String(repeating: "owner", count: 6400))
        var request = options([url]); request.namePattern = "*.txt"
        let limited = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: 1024))
        #expect(limited.archived.isEmpty)
        #expect(limited.summary.errors > 0)
        #expect(!limited.issues.isEmpty)
        let complete = collect(request)
        #expect(complete.archived.map(\.name) == ["item.txt"])
        #expect(complete.summary.errors == 0)
    }

    @Test(arguments: [ArchiveFormat.zip, .tar, .tarGzip, .tarBzip2, .tarXz])
    func appleDoubleNamesRemainOrdinaryBoundedMembers(format: ArchiveFormat) throws {
        // The system TAR reader otherwise swallows ._ files inside next_header
        // and eagerly copies their entire body as macOS metadata. ZIP has an
        // analogous __MACOSX path convention. Preserve both as ordinary data.
        let metadataPath = format == .zip ? "__MACOSX/._item.txt" : "._item.txt"
        let url = try archive("appledouble.container", [(metadataPath, Data(repeating: 0x61, count: 128 * 1024)),
            ("item.txt", Data("needle".utf8))], format: format)
        let snapshot = try ArchiveReader.open(url)
        #expect(Set(snapshot.entries.map(\.path)) == [metadataPath, "item.txt"])
        var request = options([url]); request.namePattern = "*.txt"; request.includeHidden = true
        let limited = collect(request, limits: ArchiveSearchLimits(maximumTotalContentBytes: 1024))
        #expect(limited.archived.isEmpty)
        #expect(limited.summary.errors > 0)
        let complete = collect(request)
        #expect(Set(complete.archived.map(\.path)) == [metadataPath, "item.txt"])
        #expect(complete.summary.errors == 0)
        request.includeHidden = false
        let visible = collect(request)
        #expect(visible.archived.map(\.path) == ["item.txt"])
        #expect(visible.summary.errors == 0)
    }

    @Test func nestedCorruptionIsVisibleAndHiddenContainersAreNotOpened() throws {
        let url = try archive("outer.zip", [("bad.zip", Data([0x50, 0x4b, 0x03, 0x04, 0])),
            (".private/hidden.zip", Data([0x50, 0x4b, 0x03, 0x04, 0])), ("good.txt", Data())])
        var request = options([url]); request.namePattern = "*.txt"
        let visible = collect(request)
        #expect(visible.archived.map(\.name) == ["good.txt"])
        #expect(visible.issues.contains { $0.path.contains("bad.zip") })
        #expect(!visible.issues.contains { $0.path.contains("hidden.zip") })
        request.includeHidden = true
        #expect(collect(request).issues.contains { $0.path.contains("hidden.zip") })
    }

    @Test func archiveEntryAndNestingBudgetsRejectWorkWithVisibleIssues() throws {
        let flat = try archive("flat.zip", [("a.txt", Data()), ("b.txt", Data())])
        var request = options([flat]); request.namePattern = "*.txt"
        let entries = collect(request, limits: ArchiveSearchLimits(maximumEntries: 1))
        #expect(entries.archived.count <= 1); #expect(entries.summary.errors > 0)
        let inner = try archive("fixture", [("item.txt", Data())])
        let outer = try archive("outer.zip", [("nested", try Data(contentsOf: inner))])
        request.roots = [outer]
        let depth = collect(request, limits: ArchiveSearchLimits(maximumNestedDepth: 0))
        #expect(depth.archived.isEmpty); #expect(depth.summary.errors > 0)
        request.roots = [flat, outer]
        let archives = collect(request, limits: ArchiveSearchLimits(maximumArchives: 1))
        #expect(archives.summary.errors > 0)
    }

    @Test func cancellationDuringArchiveExtractionStopsWithoutMatchOrError() throws {
        let url = try archive("outer.zip", [("large.txt", Data(repeating: 0x61, count: 512 * 1024))])
        var request = options([url], content: "aaa"); request.namePattern = "*.txt"
        let cancellation = SearchCancellation()
        var memberProgress = 0
        let found = collect(request, cancellation: cancellation) { event in
            if case .progress(let progress) = event, progress.currentPath.contains("large.txt") {
                memberProgress += 1
                if memberProgress >= 2 { cancellation.cancel() }
            }
        }
        #expect(memberProgress >= 2)
        #expect(found.summary.cancelled); #expect(found.summary.errors == 0)
        #expect(found.archived.isEmpty)
    }
}
