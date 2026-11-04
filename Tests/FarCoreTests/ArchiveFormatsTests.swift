import Foundation
import Darwin
import CArchive
import Testing
@testable import FarCore

@Suite final class ArchiveFormatsTests {
    let root: URL
    let fm = FileManager.default
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ArchiveFormats-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    deinit { try? fm.removeItem(at: root) }
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func payload(_ snapshot: ArchiveSnapshot, _ path: String) throws -> Data {
        let workspace = try ArchiveReader.extract(snapshot)
        defer { workspace.cleanup() }
        return try Data(contentsOf: workspace.url(for: path))
    }
    func noStage() throws -> Bool {
        try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".far-archive-") }
    }
    /// Independent library fixture: explicit compression, forced ZIP64 and hostile headers.
    func fixture(_ name: String = "data.bin", data: Data = Data([0, 128, 255]),
                 filter: Int32 = ARCHIVE_FILTER_NONE, zip64: Bool = false,
                 zip: Bool = false, secondFilter: Bool = false, password: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString)
        let writer = archive_write_new()!
        defer { archive_write_free(writer) }
        func check(_ code: Int32) throws {
            guard code == ARCHIVE_OK else { throw ArchiveError.io(archive_error_string(writer).map(String.init(cString:)) ?? "fixture") }
        }
        try check(zip || zip64 || password != nil ? archive_write_set_format_zip(writer) : archive_write_set_format_pax_restricted(writer))
        if zip64 { try check(archive_write_set_format_option(writer, "zip", "zip64", "1")) }
        if let password {
            try check(archive_write_set_options(writer, "zip:encryption=aes256"))
            try check(archive_write_set_passphrase(writer, password))
        }
        switch filter {
        case ARCHIVE_FILTER_GZIP: try check(archive_write_add_filter_gzip(writer))
        case ARCHIVE_FILTER_BZIP2: try check(archive_write_add_filter_bzip2(writer))
        case ARCHIVE_FILTER_XZ: try check(archive_write_add_filter_xz(writer))
        default: break
        }
        if secondFilter { try check(archive_write_add_filter_gzip(writer)) }
        try check(archive_write_open_filename(writer, url.path))
        let entry = archive_entry_new()!
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, UInt32(S_IFREG))
        archive_entry_set_perm(entry, 0o755)
        archive_entry_set_size(entry, Int64(data.count))
        try check(archive_write_header(writer, entry))
        if !data.isEmpty { #expect(data.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, $0.count) } == data.count) }
        try check(archive_write_close(writer))
        return url
    }
    func assertMagic(_ url: URL, _ format: ArchiveFormat) throws {
        let data = try Data(contentsOf: url)
        switch format {
        case .tarGzip: #expect(data.starts(with: [0x1f, 0x8b]))
        case .tarBzip2: #expect(data.starts(with: [0x42, 0x5a, 0x68]))
        case .tarXz: #expect(data.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0]))
        default: break
        }
    }

    @Test(arguments: [ArchiveFormat.tarGzip, .tarBzip2, .tarXz])
    func independentReadCreateAndEveryMutationPreservesCompressionAndBytes(format: ArchiveFormat) throws {
        let filter: Int32 = format == .tarGzip ? ARCHIVE_FILTER_GZIP : format == .tarBzip2 ? ARCHIVE_FILTER_BZIP2 : ARCHIVE_FILTER_XZ
        let binary = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 * 37) })
        let independent = try ArchiveReader.open(fixture("данные.bin", data: binary, filter: filter))
        #expect(independent.format == format)
        #expect(try payload(independent, "данные.bin") == binary)
        let source = try file("folder/data.bin", binary)
        let archive = root.appendingPathComponent(format.defaultExtension)
        var snapshot = try ArchiveWriter.create(sources: [source.deletingLastPathComponent()], destination: archive, format: format)
        try assertMagic(archive, format)
        snapshot = try ArchiveWriter.createDirectory(snapshot, path: "empty")
        snapshot = try ArchiveWriter.move(snapshot, entries: ["folder": "new/folder", "empty": "new/empty"])
        let addition = try file("added", Data([1, 0, 255]))
        snapshot = try ArchiveWriter.update(snapshot, additions: [addition], prefix: "new")
        let edited = try file("edit", Data([255, 0, 1, 2]))
        snapshot = try ArchiveWriter.update(snapshot, replacements: ["new/added": edited])
        #expect(try payload(snapshot, "new/folder/data.bin") == binary)
        #expect(try payload(snapshot, "new/added") == Data([255, 0, 1, 2]))
        #expect(snapshot.entries.contains { $0.path == "new/empty" && $0.isDirectory })
        snapshot = try ArchiveWriter.update(snapshot, deletions: ["new/added"])
        #expect(snapshot.format == format)
        #expect(!snapshot.entries.contains { $0.path == "new/added" })
        try assertMagic(archive, format)
        #expect(try Data(contentsOf: source) == binary)
        snapshot = try ArchiveWriter.update(snapshot, deletions: ["new"])
        #expect(snapshot.entries.isEmpty)
        #expect(snapshot.format == format)
        try assertMagic(archive, format)
        #expect(try noStage())
    }

    @Test(arguments: [ArchiveFormat.tarGzip, .tarBzip2, .tarXz])
    func compressedLimitsCancellationAndChangedSourcesLeaveArchiveUntouched(format: ArchiveFormat) throws {
        let source = try file("a", Data(repeating: 7, count: 64_000))
        let target = root.appendingPathComponent(format.defaultExtension)
        let snapshot = try ArchiveWriter.create(sources: [source], destination: target, format: format)
        let before = try Data(contentsOf: target)
        for limits in [ArchiveLimits(maximumEntryBytes: 10), ArchiveLimits(maximumTotalBytes: 100), ArchiveLimits(maximumExpansionRatio: 1)] {
            #expect(throws: ArchiveError.self) { try ArchiveReader.open(target, limits: limits) }
        }
        let replacement = try file("replacement", Data(repeating: 3, count: 128_000))
        let cancellation = TransferCancellation()
        #expect(throws: ArchiveError.cancelled) {
            try ArchiveWriter.update(snapshot, replacements: ["a": replacement], cancellation: cancellation, onProgress: { value in
                if value.totalBytes == 128_000 && value.completedBytes > 0 { cancellation.cancel() }
            })
        }
        #expect(try Data(contentsOf: target) == before)
        var changed = false
        #expect(throws: ArchiveWriteError.self) {
            try ArchiveWriter.update(snapshot, replacements: ["a": replacement], onProgress: { value in
                if !changed && value.totalBytes == 128_000 && value.completedBytes > 0 {
                    changed = true; try! Data([1]).write(to: replacement)
                }
            })
        }
        #expect(changed)
        #expect(try Data(contentsOf: target) == before)
        #expect(try noStage())
        try Data([9]).write(to: target, options: .atomic)
        #expect(throws: ArchiveError.changedArchive) { try ArchiveWriter.createDirectory(snapshot, path: "fail") }
        #expect(try Data(contentsOf: target) == Data([9]))
    }

    @Test func compressedBoundsRejectHostilePathsStackedFiltersAndCompressedZIP() throws {
        for filter in [ARCHIVE_FILTER_GZIP, ARCHIVE_FILTER_BZIP2, ARCHIVE_FILTER_XZ] {
            #expect(throws: ArchiveError.self) { try ArchiveReader.open(fixture("../escape", filter: filter)) }
            #expect(throws: ArchiveError.unsupportedFormat) { try ArchiveReader.open(fixture(filter: filter, zip: true)) }
        }
        #expect(throws: ArchiveError.unsupportedFormat) { try ArchiveReader.open(fixture(filter: ARCHIVE_FILTER_GZIP, secondFilter: true)) }
        let source = try fixture(filter: ARCHIVE_FILTER_XZ)
        var truncated = try Data(contentsOf: source); truncated = truncated.prefix(12)
        try truncated.write(to: source)
        #expect(throws: ArchiveError.self) {
            let snapshot = try ArchiveReader.open(source)
            let work = try ArchiveReader.extract(snapshot); work.cleanup()
        }
    }

    @Test func xzDictionaryAndSingleBlockBoundsAreCheckedBeforeDecoding() throws {
        let source = try fixture(filter: ARCHIVE_FILTER_XZ)
        var bytes = [UInt8](try Data(contentsOf: source))
        while bytes.last == 0 { bytes.removeLast() }
        let headerSize = (Int(bytes[12]) + 1) * 4
        func crc(_ values: ArraySlice<UInt8>) -> UInt32 {
            var result = UInt32.max
            for byte in values {
                result ^= UInt32(byte)
                for _ in 0..<8 { result = result >> 1 ^ (result & 1 == 0 ? 0 : 0xedb8_8320) }
            }
            return ~result
        }
        func fixBlockCRC(_ values: inout [UInt8]) {
            let checksum = crc(values[12..<(12 + headerSize - 4)])
            for index in 0..<4 { values[12 + headerSize - 4 + index] = UInt8(truncatingIfNeeded: checksum >> (8 * index)) }
        }
        // Independent default XZ fixture uses one LZMA2 filter without size fields.
        #expect(bytes[13] == 0 && bytes[14] == 0x21 && bytes[15] == 1)
        var hugeDictionary = bytes
        hugeDictionary[16] = 40 // A valid 4 GiB dictionary property, refused before decoder allocation.
        fixBlockCRC(&hugeDictionary)
        let hostile = try file("dictionary.xz", Data(hugeDictionary))
        #expect(throws: ArchiveError.limitExceeded("словарь XZ больше 64 МиБ")) { try ArchiveReader.open(hostile) }
        var chain = bytes; chain[13] = 1; fixBlockCRC(&chain)
        #expect(throws: ArchiveError.unsupportedFormat) { try ArchiveReader.open(file("chain.xz", Data(chain))) }
        let concatenated = try file("concatenated.xz", Data(bytes + bytes))
        #expect(throws: ArchiveError.unsupportedFormat) { try ArchiveReader.open(concatenated) }
        var earlyEnd = bytes; earlyEnd[12 + headerSize] = 0
        #expect(throws: ArchiveError.self) { try ArchiveReader.open(file("early-end.xz", Data(earlyEnd))) }
        let valid = try ArchiveReader.open(source)
        #expect(valid.format == .tarXz)
        #expect(try payload(valid, "data.bin") == Data([0, 128, 255]))
    }

    @Test func forcedSmallZIP64ReadUpdateAndMalformedBounds() throws {
        let data = Data([0, 255, 1, 128, 0])
        let archive = try fixture(data: data, zip64: true)
        let bytes = try Data(contentsOf: archive)
        #expect(bytes.range(of: Data([0x50, 0x4b, 0x06, 0x06])) != nil)
        let snapshot = try ArchiveReader.open(archive)
        #expect(snapshot.format == .zip)
        #expect(try payload(snapshot, "data.bin") == data)
        let updated = try ArchiveWriter.move(snapshot, entries: ["data.bin": "moved.bin"])
        #expect(try payload(updated, "moved.bin") == data)
        // Updating a small ZIP64 may emit ordinary ZIP; sizes remain bounded by app limits.
        for kind in 0..<4 {
            var hostile = bytes
            let record = try #require(hostile.range(of: Data([0x50, 0x4b, 0x06, 0x06]))).lowerBound
            let locator = try #require(hostile.range(of: Data([0x50, 0x4b, 0x06, 0x07]))).lowerBound
            switch kind {
            case 0: for index in 0..<8 { hostile[locator + 8 + index] = 255 } // address overflow
            case 1: hostile[record + 16] = 1 // multiple volumes
            case 2: for index in 0..<8 { hostile[record + 40 + index] = 255 } // directory size overflow
            default: hostile[record + 4] = 1 // too short record
            }
            let invalid = try file("bad\(kind).zip", hostile)
            #expect(throws: ArchiveError.self) { try ArchiveReader.open(invalid) }
        }
    }

    @Test func nestedFramesRetainSnapshotsPopAndRejectAllWritesAndAncestorChanges() throws {
        let binary = Data([0, 255, 0, 17])
        let inner = try fixture("data.bin", data: binary, filter: ARCHIVE_FILTER_XZ)
        let outer = try ArchiveWriter.create(sources: [inner], destination: root.appendingPathComponent("outer.zip"), format: .zip)
        let frame = ArchiveNavigationFrame(snapshot: outer)
        var child: ArchiveNavigationFrame? = try frame.openNested(path: inner.lastPathComponent)
        let childSource = try #require(child?.snapshot.sourceURL)
        var heldSnapshot: ArchiveSnapshot? = child?.snapshot
        #expect(child?.parent === frame)
        #expect(child?.depth == 1)
        #expect(child?.isReadOnly == true)
        #expect(child?.displayPath == outer.sourceURL.path + " !/" + inner.lastPathComponent)
        let rewrapped = ArchiveNavigationFrame(snapshot: try #require(heldSnapshot))
        #expect(rewrapped.depth == 1)
        #expect(rewrapped.retainedBytes == child?.retainedBytes)
        #expect(rewrapped.parent === frame)
        let before = try Data(contentsOf: outer.sourceURL)
        #expect(throws: ArchiveWriteError.self) { try ArchiveWriter.createDirectory(try #require(heldSnapshot), path: "no") }
        #expect(throws: ArchiveWriteError.self) { try ArchiveWriter.move(try #require(heldSnapshot), entries: ["data.bin": "renamed"]) }
        #expect(throws: ArchiveWriteError.self) { try ArchiveWriter.update(try #require(heldSnapshot), deletions: ["data.bin"]) }
        #expect(try Data(contentsOf: outer.sourceURL) == before)
        child = nil
        #expect(try payload(try #require(heldSnapshot), "data.bin") == binary)
        #expect(fm.fileExists(atPath: childSource.path))
        try Data([1]).write(to: outer.sourceURL, options: .atomic)
        #expect(throws: ArchiveError.changedArchive) { try heldSnapshot?.verifyCurrent() }
        heldSnapshot = nil
        // rewrapped intentionally retains the same child source until this scope ends.
        #expect(fm.fileExists(atPath: rewrapped.snapshot.sourceURL.path))
    }

    @Test func nestedDepthCancellationHostileChildAndSnapshotCleanup() throws {
        var url = try fixture()
        for level in 0..<5 {
            url = try ArchiveWriter.create(sources: [url], destination: root.appendingPathComponent("level\(level).zip"), format: .zip).sourceURL
        }
        var frame = ArchiveNavigationFrame(snapshot: try ArchiveReader.open(url))
        for _ in 0..<4 { frame = try frame.openNested(path: try #require(frame.snapshot.entries.first).path) }
        #expect(frame.depth == ArchiveNavigationFrame.maximumDepth)
        let wrapped = ArchiveNavigationFrame(snapshot: frame.snapshot)
        #expect(throws: ArchiveError.self) { try wrapped.openNested(path: try #require(wrapped.snapshot.entries.first).path) }
        let token = TransferCancellation(); token.cancel()
        let rootFrame = ArchiveNavigationFrame(snapshot: try ArchiveReader.open(url))
        #expect(throws: ArchiveError.cancelled) { try rootFrame.openNested(path: try #require(rootFrame.snapshot.entries.first).path, cancellation: token) }
        let hostile = try fixture("../escape")
        let safeOuter = try ArchiveWriter.create(sources: [hostile], destination: root.appendingPathComponent("unsafe-child.zip"), format: .zip)
        #expect(throws: ArchiveError.self) { try ArchiveNavigationFrame(snapshot: safeOuter).openNested(path: hostile.lastPathComponent) }
        var snapshot: ArchiveSnapshot?
        var source: URL?
        do {
            let child = try rootFrame.openNested(path: try #require(rootFrame.snapshot.entries.first).path)
            snapshot = child.snapshot; source = child.snapshot.sourceURL
        }
        #expect(snapshot != nil)
        #expect(fm.fileExists(atPath: try #require(source).path))
        snapshot = nil
        #expect(!fm.fileExists(atPath: try #require(source).path))
    }

    @Test func nestedRetainedBudgetCannotResetByRewrapping() throws {
        let leaf = try fixture(zip: true)
        let middle = try fixture("leaf.zip", data: Data(contentsOf: leaf), zip: true)
        let middleBytes = try Data(contentsOf: middle)
        let outer = try fixture("middle.zip", data: middleBytes, zip: true)
        let limits = ArchiveLimits(maximumTotalBytes: Int64(middleBytes.count))
        let frame = ArchiveNavigationFrame(snapshot: try ArchiveReader.open(outer, limits: limits))
        let child = try frame.openNested(path: "middle.zip")
        #expect(child.retainedBytes == Int64(middleBytes.count))
        let wrapped = ArchiveNavigationFrame(snapshot: child.snapshot)
        #expect(throws: ArchiveError.self) { try wrapped.openNested(path: "leaf.zip") }
    }

    @Test func encryptedOuterAndInnerUseSeparatePasswords() throws {
        let inner = try fixture("inner.bin", password: "inner-secret")
        let innerData = try Data(contentsOf: inner)
        let outerURL = try fixture("inner.zip", data: innerData, zip: true, password: "outer-secret")
        let frame = ArchiveNavigationFrame(snapshot: try ArchiveReader.open(outerURL))
        #expect(frame.isReadOnly)
        #expect(throws: ArchiveNestedPasswordError.self) { try frame.openNested(path: "inner.zip") }
        let child = try frame.openNested(path: "inner.zip", password: "outer-secret")
        let extracted = try ArchiveReader.extract(child.snapshot, password: "inner-secret")
        defer { extracted.cleanup() }
        #expect(try Data(contentsOf: extracted.url(for: "inner.bin")) == Data([0, 128, 255]))
    }
}
